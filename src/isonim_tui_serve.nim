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

  ChildReapTimeoutMs* = 3000
    ## How long `bridgeOnce` waits for a terminated child before killing it.
    ## Long enough for a hosted app that closes a database or a debugger
    ## engine on SIGTERM; short enough that a wedged one cannot hold the
    ## accept loop.

# ---------------------------------------------------------------------------
# Server type
# ---------------------------------------------------------------------------

type
  AppLauncher* = proc (): Process {.gcsafe.}
    ## Launches the hosted app. Returns a Process whose stdin/stdout
    ## carry the packet stream. The server takes ownership and ships
    ## bytes between it and the websocket peer.

  StaticFile* = object
    ## One file of an IN-MEMORY static bundle, served without touching the
    ## filesystem.
    ##
    ## Exists because a host that embeds its frontend in its own executable
    ## (`staticRead`) has nothing to point `staticDir` at: staging the bundle
    ## into a temporary directory at startup would make "served from the
    ## binary" true only of where the bytes came from, and would leave a
    ## directory behind on every abnormal exit. `path` is matched against the
    ## request path exactly as it arrives, with `/` normalised to
    ## `/index.html` by the caller in `serveStatic`.
    path*: string
    mime*: string
    body*: string

  ServeConfig* = object
    port*: Port
      ## `Port(0)` asks the kernel for an ephemeral port. The bound port is
      ## then readable from `boundPort` AFTER `listen`, which is the only way
      ## a caller can report it — `cfg.port` still says 0.
    address*: string
      ## The interface to bind. `""` is every interface (the historic
      ## behaviour); `"127.0.0.1"` is loopback only. Carried in the config
      ## rather than passed to `serve` so that `listen` / `boundPort` /
      ## `acceptLoop` and the one-call `serve` cannot disagree about it.
    staticDir*: string
    staticFiles*: seq[StaticFile]
      ## Consulted BEFORE `staticDir`. Empty by default, so a caller that only
      ## sets `staticDir` behaves exactly as before.
    launchApp*: AppLauncher

  Server* = ref object
    cfg: ServeConfig
    httpServer: AsyncHttpServer
    listening: bool

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

proc drainChildStderr(child: Process) {.async.} =
  ## Copy the child's stderr to ours, forever.
  ##
  ## NOT LOGGING FOR ITS OWN SAKE — this prevents a HANG. `startProcess`
  ## without `poParentStreams` gives the child a *pipe* for stderr, and a pipe
  ## nobody reads fills at 64 KB on Linux; the next write blocks the child
  ## indefinitely, in the middle of whatever it was doing, and from the
  ## browser's side that is a session that silently stops painting. A hosted
  ## app that logs — a debugger engine, say — reaches that in seconds.
  ##
  ## Prefixed, so an operator can tell the bridge's own diagnostics from the
  ## hosted app's.
  let fd = cint(child.errorHandle)
  setNonBlocking(fd)
  var rawBuf: array[4096, byte]
  while true:
    let n = posix.read(fd, addr rawBuf[0], rawBuf.len)
    if n > 0:
      var s = newString(int(n))
      for i in 0 ..< int(n): s[i] = char(rawBuf[i])
      for line in s.splitLines():
        if line.len > 0:
          try: stderr.writeLine("[app] " & line) except IOError: discard
    elif n == 0:
      return
    else:
      let e = osLastError()
      if cint(e) == EAGAIN or cint(e) == EWOULDBLOCK:
        await sleepAsync(20)
        continue
      if cint(e) == EINTR: continue
      return

proc bridgeOnce(client: AsyncSocket; child: Process) {.async.} =
  ## Run the two halves concurrently until either side hangs up.
  let outFut = forwardChildStdoutToWs(child, client)
  let inFut = forwardWsToChildStdin(client, child)
  # Fire and forget: the drain ends on its own when the child's stderr reaches
  # EOF, and it must not be one of the futures the bridge waits on — a hosted
  # app that never writes to stderr would otherwise keep the connection open
  # after both real halves had finished.
  asyncCheck drainChildStderr(child)
  await outFut or inFut
  try: client.close() except CatchableError: discard
  try: child.terminate() except CatchableError: discard
  # AND REAPED. `terminate` only sends the signal; without a `waitForExit` the
  # exited child stays a zombie for the life of the bridge and its own
  # grandchildren are never collected either — one leaked process table entry
  # per browser connection, which is exactly the shape of leak a long-running
  # dev server must not have. Bounded, because a child that ignores SIGTERM
  # must not wedge the accept loop; on the timeout it is killed outright and
  # then reaped.
  try:
    if child.waitForExit(ChildReapTimeoutMs) < 0:
      child.kill()
      discard child.waitForExit(ChildReapTimeoutMs)
  except CatchableError:
    discard
  try: child.close() except CatchableError: discard

# ---------------------------------------------------------------------------
# HTTP request handler
# ---------------------------------------------------------------------------

proc mimeForPath(path: string): string =
  if path.endsWith(".html"): "text/html; charset=utf-8"
  elif path.endsWith(".js"): "application/javascript"
  elif path.endsWith(".css"): "text/css"
  else: "application/octet-stream"

proc serveStatic(req: Request; cfg: ServeConfig) {.async.} =
  ## Serve a single file: from `cfg.staticFiles` if the path is in the
  ## in-memory bundle, otherwise from `cfg.staticDir`. For the bridge demo we
  ## map "/" → "index.html" and any other path → that file under
  ## `staticDir`. No directory traversal — paths must be relative.
  var path = req.url.path
  if path == "/" or path == "":
    path = "/index.html"
  if "/.." in path or path.startsWith(".."):
    await req.respond(Http400, "bad path")
    return
  # THE IN-MEMORY BUNDLE FIRST, and no filesystem access at all when it hits:
  # an embedded frontend must not be shadowed by a same-named file that
  # happens to sit in the working directory.
  for f in cfg.staticFiles:
    if f.path == path:
      let mime = if f.mime.len > 0: f.mime else: mimeForPath(path)
      var headers = newHttpHeaders([("Content-Type", mime)])
      await req.respond(Http200, f.body, headers)
      return
  let staticDir = cfg.staticDir
  if staticDir.len == 0:
    await req.respond(Http404, "not found: " & path)
    return
  let full = staticDir / path[1 ..^ 1]
  if not fileExists(full):
    await req.respond(Http404, "not found: " & path)
    return
  let body = readFile(full)
  let mime = mimeForPath(path)
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
    await serveStatic(req, cfg)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc newServer*(cfg: ServeConfig): Server =
  Server(cfg: cfg, httpServer: newAsyncHttpServer(), listening: false)

proc listen*(s: Server) =
  ## Bind and listen, WITHOUT accepting anything yet.
  ##
  ## Split out of `serve` for one reason, and it is a testability reason with a
  ## product consequence: `ServeConfig.port` may be `Port(0)`, and the only
  ## moment at which the kernel's answer exists is between the `bind` and the
  ## first `accept`. A caller that has to print "listening on …" — or a test
  ## that has to connect without guessing — needs to run code in that gap.
  ## `serve` is `listen` + `acceptLoop`, so nothing that used it changes.
  ##
  ## Idempotent: a second call is a no-op rather than a second socket, because
  ## the port a caller already reported must not silently become a different
  ## one.
  if s.listening:
    return
  s.httpServer.listen(s.cfg.port, s.cfg.address)
  s.listening = true

proc boundPort*(s: Server): Port =
  ## The port actually bound, which is the ONLY meaningful answer when
  ## `cfg.port` is 0. Callable only after `listen`; before it, the underlying
  ## socket does not exist and `getPort` would fault, so this reports the
  ## configured port instead of crashing.
  if not s.listening: s.cfg.port else: s.httpServer.getPort()

proc acceptLoop*(s: Server) {.async.} =
  ## Accept forever. `listen` must have been called.
  proc cb(req: Request) {.async.} =
    await handler(req, s.cfg)
  while true:
    await s.httpServer.acceptRequest(cb)

proc serve*(s: Server) {.async.} =
  ## Block-forever serve loop. Run it with `waitFor`.
  s.listen()
  await s.acceptLoop()

proc close*(s: Server) =
  ## Stop listening. Open bridged connections are owned by their own futures
  ## and are not touched here.
  if s.listening:
    s.httpServer.close()
    s.listening = false

proc port*(s: Server): Port = s.cfg.port

# ---------------------------------------------------------------------------
# Tiny CLI
# ---------------------------------------------------------------------------

when isMainModule:
  proc main() =
    var port = 8765
    var address = ""
    var staticDir = "static"
    var appCmd = ""
    var i = 1
    while i <= paramCount():
      let arg = paramStr(i)
      case arg
      of "--port":
        inc i
        port = parseInt(paramStr(i))
      of "--address":
        inc i
        address = paramStr(i)
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
      address: address,
      staticDir: staticDir,
      launchApp: proc (): Process =
        startProcess(exe, args = args, options = {poUsePath, poStdErrToStdOut}))
    let s = newServer(cfg)
    # LISTEN, THEN REPORT, THEN ACCEPT. `--port 0` asks the kernel to choose
    # and the answer only exists after the bind, so the line below prints the
    # port that was actually taken rather than the one that was asked for.
    s.listen()
    echo "isonim-tui-serve listening on http://",
         (if address.len == 0: "0.0.0.0" else: address),
         ":", int(s.boundPort())
    flushFile(stdout)
    waitFor s.acceptLoop()
  main()
