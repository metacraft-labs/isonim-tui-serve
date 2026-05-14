## isonim-tui-serve — websocket bridge for the M26 packet driver.
##
## Hosts a TUI app process (running with isonim-tui's `WebDriver`) and
## bridges the stdio packet stream (`D`/`M`/`P` packets, see the
## driver's module docstring) to a browser tab running xterm.js.
##
## Wire summary:
##
##   * Browser establishes a WebSocket connection to `ws://host:port/`.
##   * Each WebSocket *binary* message is one framed packet (`D`/`M`/`P`).
##   * `D` packets travel server → browser; the JS side decodes them
##     and feeds the payload bytes into `term.write(...)` on xterm.js.
##   * `P` and `M` packets travel browser → server; the server forwards
##     them to the hosted child app's stdin.
##
## Hand-rolled RFC 6455 framing (sec 5). The HTTP/Upgrade handshake
## reuses `std/asynchttpserver`. We do not implement compression
## extensions, fragmented messages > 1 frame, or TLS — this is a
## development-time bridge, not a production-edge gateway.
##
## *Charter §1.* Every value flowing through the public API is
## value-typed. The server itself is a `ref object` because it owns a
## listening socket and a child process handle.

import std/[asynchttpserver, asyncdispatch, asyncnet, base64,
            httpcore, os, oserrors, osproc, posix, strutils]
import std/sha1 as sha1Mod

import ./isonim_tui_serve/packet
import ./isonim_tui_serve/wsframe
import ./isonim_tui_serve/story_dispatch

export packet, wsframe, story_dispatch

const
  WebSocketGuid* = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    ## Magic GUID required by RFC 6455 §1.3 to compute the handshake
    ## accept-key.

# ---------------------------------------------------------------------------
# Server type
# ---------------------------------------------------------------------------

type
  AppLauncher* = proc (): Process {.gcsafe.}
    ## Launches the hosted app. Returns a Process whose stdin/stdout
    ## carry the packet stream. The server takes ownership and ships
    ## bytes between it and the websocket peer.

  ServeConfig* = object
    port*: Port
    staticDir*: string
    launchApp*: AppLauncher

  Server* = ref object
    cfg: ServeConfig
    httpServer: AsyncHttpServer

# ---------------------------------------------------------------------------
# Handshake
# ---------------------------------------------------------------------------

proc computeAcceptKey*(clientKey: string): string =
  ## RFC 6455 §1.3: SHA-1(clientKey ++ guid), base64-encoded.
  let combined = clientKey & WebSocketGuid
  {.push warning[Deprecated]: off.}
  let digest = sha1Mod.secureHash(combined)
  let bytes = sha1Mod.Sha1Digest(digest)
  {.pop.}
  # `Sha1Digest` is a 20-byte array; need raw bytes for base64.
  var raw = newString(20)
  for i in 0 ..< 20: raw[i] = char(bytes[i])
  encode(raw)

proc readHeader(headers: HttpHeaders; key: string): string =
  if headers.hasKey(key):
    let vs = headers[key]
    result = $vs
  else:
    result = ""

# ---------------------------------------------------------------------------
# Packet bridge
# ---------------------------------------------------------------------------

proc setNonBlocking(fd: cint) =
  ## Mark `fd` non-blocking via fcntl(F_SETFL, O_NONBLOCK).
  let flags = fcntl(fd, F_GETFL, 0)
  if flags == -1: return
  discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)

proc forwardChildStdoutToWs(child: Process; client: AsyncSocket) {.async.} =
  ## Read framed packets from the child's stdout (non-blocking) and
  ## forward them as WebSocket binary messages.
  var parser = initPacketParser()
  let fd = cint(child.outputHandle)
  setNonBlocking(fd)
  var rawBuf: array[4096, byte]
  while true:
    let n = posix.read(fd, addr rawBuf[0], rawBuf.len)
    if n > 0:
      var s = newString(int(n))
      for i in 0 ..< int(n): s[i] = char(rawBuf[i])
      parser.feedString(s)
      while parser.pendingPackets() > 0:
        let (ok, kind, payload) = parser.pop()
        if not ok: break
        let framed = encodePacket(kind, payload)
        let frame = encodeWsBinaryFrame(framed)
        try:
          await client.send(frame)
        except OSError, IOError:
          return
    elif n == 0:
      # EOF — child closed stdout.
      return
    else:
      let e = osLastError()
      if cint(e) == EAGAIN or cint(e) == EWOULDBLOCK:
        # Yield to the dispatcher for ~10 ms; fresh bytes might be
        # waiting after that.
        await sleepAsync(10)
        continue
      if cint(e) == EINTR: continue
      return

proc forwardWsToChildStdin(client: AsyncSocket; child: Process) {.async.} =
  ## Read WebSocket frames from the client and forward each binary
  ## message's payload (which is itself one framed packet) to the
  ## child process's stdin.
  var dec = initWsFrameDecoder()
  let clientFd = AsyncFD(getFd(client))
  while not client.isClosed:
    # Read directly from the underlying AsyncFD: `client.recv()` /
    # `client.recvInto()` on a buffered AsyncSocket keeps looping
    # readIntoBuf until either the requested size is filled or the
    # peer hangs up — useless for incremental frame parsing where the
    # next-frame size is unknown. Going one level lower returns
    # whatever the kernel hands us right now.
    var rawBuf = newString(4096)
    let n = await asyncdispatch.recvInto(clientFd, addr rawBuf[0],
                                         rawBuf.len)
    if n <= 0: break
    dec.feed(rawBuf[0 ..< n])
    while true:
      let msg = dec.popMessage()
      if not msg.complete: break
      if msg.opcode == wsOpClose:
        return
      if msg.opcode == wsOpBinary or msg.opcode == wsOpText:
        let inFd = cint(child.inputHandle)
        var off = 0
        while off < msg.payload.len:
          let p = cast[pointer](cast[uint](unsafeAddr msg.payload[0]) +
                                uint(off))
          let w = posix.write(inFd, p, msg.payload.len - off)
          if w <= 0:
            let e = osLastError()
            if cint(e) == EINTR: continue
            return
          off += int(w)

proc bridgeOnce(client: AsyncSocket; child: Process) {.async.} =
  ## Run the two halves concurrently until either side hangs up.
  let outFut = forwardChildStdoutToWs(child, client)
  let inFut = forwardWsToChildStdin(client, child)
  await outFut or inFut
  try: client.close() except CatchableError: discard
  try: child.terminate() except CatchableError: discard

# ---------------------------------------------------------------------------
# HTTP request handler
# ---------------------------------------------------------------------------

proc serveStatic(req: Request; staticDir: string) {.async.} =
  ## Serve a single file from `staticDir`. For the bridge demo we
  ## map "/" → "index.html" and any other path → that file under
  ## `staticDir`. No directory traversal — paths must be relative.
  var path = req.url.path
  if path == "/" or path == "":
    path = "/index.html"
  if "/.." in path or path.startsWith(".."):
    await req.respond(Http400, "bad path")
    return
  let full = staticDir / path[1 ..^ 1]
  if not fileExists(full):
    await req.respond(Http404, "not found: " & path)
    return
  let body = readFile(full)
  let mime =
    if path.endsWith(".html"): "text/html; charset=utf-8"
    elif path.endsWith(".js"): "application/javascript"
    elif path.endsWith(".css"): "text/css"
    else: "application/octet-stream"
  var headers = newHttpHeaders([("Content-Type", mime)])
  await req.respond(Http200, body, headers)

proc handleWebSocketUpgrade(req: Request; cfg: ServeConfig) {.async.} =
  ## Complete the RFC 6455 handshake, then bridge to a freshly-spawned
  ## child app process.
  let key = readHeader(req.headers, "Sec-WebSocket-Key")
  if key.len == 0:
    await req.respond(Http400, "missing Sec-WebSocket-Key")
    return
  let accept = computeAcceptKey(key.strip())
  let resp = "HTTP/1.1 101 Switching Protocols\r\n" &
             "Upgrade: websocket\r\n" &
             "Connection: Upgrade\r\n" &
             "Sec-WebSocket-Accept: " & accept & "\r\n\r\n"
  await req.client.send(resp)
  # The connection has now left the HTTP layer; we own the socket.
  if cfg.launchApp == nil:
    try: req.client.close() except CatchableError: discard
    return
  let child = cfg.launchApp()
  await bridgeOnce(req.client, child)

proc handler(req: Request; cfg: ServeConfig) {.async.} =
  let upgrade = readHeader(req.headers, "Upgrade")
  if upgrade.toLowerAscii == "websocket":
    await handleWebSocketUpgrade(req, cfg)
  else:
    await serveStatic(req, cfg.staticDir)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc newServer*(cfg: ServeConfig): Server =
  Server(cfg: cfg, httpServer: newAsyncHttpServer())

proc serve*(s: Server) {.async.} =
  ## Block-forever serve loop. Run it with `waitFor`.
  proc cb(req: Request) {.async.} =
    await handler(req, s.cfg)
  await s.httpServer.serve(s.cfg.port, cb)

proc port*(s: Server): Port = s.cfg.port

# ---------------------------------------------------------------------------
# Tiny CLI
# ---------------------------------------------------------------------------

when isMainModule:
  proc main() =
    var port = 8765
    var staticDir = "static"
    var appCmd = ""
    var i = 1
    while i <= paramCount():
      let arg = paramStr(i)
      case arg
      of "--port":
        inc i
        port = parseInt(paramStr(i))
      of "--static":
        inc i
        staticDir = paramStr(i)
      of "--app":
        inc i
        appCmd = paramStr(i)
      else:
        quit("unknown arg: " & arg, 1)
      inc i
    if appCmd.len == 0:
      quit("--app <command> is required", 1)
    let parts = appCmd.split(' ')
    let exe = parts[0]
    let args = if parts.len > 1: parts[1 ..^ 1] else: @[]
    let cfg = ServeConfig(
      port: Port(port),
      staticDir: staticDir,
      launchApp: proc (): Process =
        startProcess(exe, args = args, options = {poUsePath, poStdErrToStdOut}))
    let s = newServer(cfg)
    echo "isonim-tui-serve listening on http://0.0.0.0:", port
    waitFor s.serve()
  main()
