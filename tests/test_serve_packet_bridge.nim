## test_serve_packet_bridge — end-to-end bridge integration test.
##
## *Claim.* The serve repo's WebSocket bridge correctly translates
## between the browser-facing wire (one packet per binary frame) and
## the child-app-facing wire (raw framed packets on stdin/stdout).
##
## *How.*
##
##   1. Compile the `echo_packet_app` test fixture (a child that
##      echoes each `P` payload back as a `D` packet prefixed with
##      `"echo:"`).
##   2. Start the bridge server on an ephemeral port, with the child
##      app launcher set to spawn the fixture.
##   3. Connect a hand-rolled WebSocket client (built on `asyncnet`)
##      to the server. Send one `P` packet wrapped in one binary
##      frame.
##   4. Receive one binary frame back; its payload must be the
##      child's `D` packet (`"echo:"` + the original input payload).
##
## Real-stack: no mocks. The server is the production module; the
## subprocess is a real OS process; the WebSocket framing is the
## production codec going both directions.

import std/[asyncdispatch, asyncnet, base64, nativesockets, net, os,
            osproc, random, strutils, unittest]

import isonim_tui_serve

# Build the test fixture lazily; the test runs the compile step
# in-process so a one-shot `nim c -r` of this file actually works.
proc fixturePath(): string =
  let here = currentSourcePath().parentDir
  let outBin = here / "echo_packet_app"
  if not fileExists(outBin):
    let src = here / "echo_packet_app.nim"
    let cmd = "nim c -d:release --threads:on --hints:off --warnings:off " &
              "--path:" & here / ".." / "src" & " " &
              "-o:" & outBin & " " & src
    let exit = execShellCmd(cmd)
    doAssert exit == 0, "failed to build echo_packet_app: " & cmd
  outBin

proc pickPort(): int =
  ## Best-effort ephemeral port: bind a temporary socket to port 0,
  ## read the kernel-assigned port back. Far from race-free, but the
  ## window between `close` and the bridge's `bind` is short.
  let s = newSocket()
  s.bindAddr(Port(0))
  let p = s.getLocalAddr()[1]
  s.close()
  int(p)

proc randMaskKey(): array[4, byte] =
  for i in 0 ..< 4: result[i] = byte(rand(0 .. 255))

proc recvSome(fd: AsyncFD; size: int): Future[string] {.async.} =
  ## Read up to `size` bytes from `fd`. Bypasses asyncnet's buffered
  ## recv, which would loop trying to fill the whole buffer (useless
  ## when we don't know the next frame size).
  var buf = newString(size)
  let n = await asyncdispatch.recvInto(fd, addr buf[0], size)
  if n <= 0: return ""
  buf.setLen(n)
  result = buf

proc handshake(s: AsyncSocket; host: string; port: int) {.async.} =
  let key = encode("0123456789abcdef0123")
  let req = "GET / HTTP/1.1\r\n" &
            "Host: " & host & ":" & $port & "\r\n" &
            "Upgrade: websocket\r\n" &
            "Connection: Upgrade\r\n" &
            "Sec-WebSocket-Key: " & key & "\r\n" &
            "Sec-WebSocket-Version: 13\r\n\r\n"
  await s.send(req)
  let fd = AsyncFD(getFd(s))
  var resp = ""
  while not resp.contains("\r\n\r\n"):
    let chunk = await recvSome(fd, 4096)
    if chunk.len == 0: break
    resp.add(chunk)
  doAssert resp.startsWith("HTTP/1.1 101"),
    "handshake failed: " & resp

proc clientFlow(port: int): Future[(bool, string)] {.async.} =
  let sock = newAsyncSocket()
  await sock.connect("127.0.0.1", Port(port))
  await handshake(sock, "127.0.0.1", port)

  # Send a P packet with a known payload.
  let payload = "key|enter|0|"
  let pkt = encodePacket(PacketTypeInput, payload)
  let mask = randMaskKey()
  let frame = encodeWsClientFrame(wsOpBinary, pkt, mask)
  await sock.send(frame)

  # Read until we have one full WebSocket frame back.
  let fd = AsyncFD(getFd(sock))
  var dec = initWsFrameDecoder()
  var msg = WsMessage(complete: false)
  var attempts = 0
  while not msg.complete and attempts < 200:
    let chunk = await recvSome(fd, 4096)
    if chunk.len == 0: break
    dec.feed(chunk)
    msg = dec.popMessage()
    inc attempts
  sock.close()
  return (msg.complete, msg.payload)

proc serverTask(server: Server) {.async.} =
  try:
    await server.serve()
  except CatchableError:
    discard

suite "isonim-tui-serve: packet bridge integration":

  test "test_serve_packet_bridge":
    when defined(windows):
      skip()
    else:
      randomize()
      let appExe = fixturePath()
      let port = pickPort()
      let appExeCap = appExe
      proc launcher(): Process {.closure, gcsafe.} =
        {.cast(gcsafe).}:
          startProcess(appExeCap, args = @[],
                       options = {poStdErrToStdOut})
      let cfg = ServeConfig(
        port: Port(port),
        staticDir: ".",
        launchApp: launcher)
      let server = newServer(cfg)
      asyncCheck serverTask(server)

      # Drive the dispatcher long enough for the listener to bind.
      for i in 0 .. 5: poll(50)

      let (ok, replyFrame) = waitFor clientFlow(port)
      check ok

      # The reply frame's payload is one full framed packet from the child.
      var parser = initPacketParser()
      parser.feedString(replyFrame)
      check parser.pendingPackets() == 1
      let (popOk, kind, replyPayload) = parser.pop()
      check popOk
      check kind == 'D'
      check replyPayload == "echo:key|enter|0|"

      # Brief drain so the bridge can finish closing the child.
      for i in 0 .. 5: poll(20)
