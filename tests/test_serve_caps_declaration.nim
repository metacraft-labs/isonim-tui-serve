## test_serve_caps_declaration — the client's capability declaration, the
## `caps|` M packet (CodeTracer-TUI-Terminal-Adaptation.md §3.5).
##
## *Claims.*
##
##   1. The codec: `encodeCapsMeta` writes the fields in their fixed order
##      (the exact bytes are pinned), `decodeCapsMeta` reads them back, and a
##      payload that is not a declaration — no prefix, bad JSON, a missing or
##      mistyped field, a renderer or Unicode version outside the documented
##      values — is refused with `TuiPacketProtocolError`, naming the field.
##   2. Through the bridge: a declaration a client sends as its first packet
##      reaches the hosted app before the packet after it, and decodes there
##      — on every connection, not only the first: one connection's readers
##      once took the next connection's first packet off a reused
##      descriptor.
##
## Real-stack: the bridge is the production server, the hosted app a real
## subprocess (`echo_packet_app`, which decodes the declaration with this
## library and answers `caps:<renderer>,<unicodeVersion>,<customGlyphs>`),
## the WebSocket framing the production codec. No mocks.

import std/[asyncdispatch, asyncnet, base64, nativesockets, net, os,
            osproc, random, strutils, times, unittest]

import isonim_tui_serve

const Declared = ClientCaps(xtermJs: "5.3.0", renderer: "webgl",
                            customGlyphs: true, unicodeVersion: "11",
                            truecolor: true, sgrMouse: true)

proc fixturePath(): string =
  let here = currentSourcePath().parentDir
  let outBin = here / "echo_packet_app"
  let src = here / "echo_packet_app.nim"
  if not fileExists(outBin) or
     getLastModificationTime(src) > getLastModificationTime(outBin) or
     getLastModificationTime(here / ".." / "src" / "isonim_tui_serve" /
                             "packet.nim") > getLastModificationTime(outBin):
    let cmd = "nim c -d:release --threads:on --hints:off --warnings:off " &
              "--path:" & here / ".." / "src" & " -o:" & outBin & " " & src
    doAssert execShellCmd(cmd) == 0, "failed to build echo_packet_app: " & cmd
  outBin

proc pickPort(): int =
  let s = newSocket()
  s.bindAddr(Port(0))
  let p = s.getLocalAddr()[1]
  s.close()
  int(p)

proc recvSome(fd: AsyncFD; size: int): Future[string] {.async.} =
  var buf = newString(size)
  let n = await asyncdispatch.recvInto(fd, addr buf[0], size)
  if n <= 0: return ""
  buf.setLen(n)
  result = buf

proc mask(): array[4, byte] =
  for i in 0 ..< 4: result[i] = byte(rand(0 .. 255))

proc clientFlow(port: int; first: string): Future[seq[string]] {.async.} =
  ## Send `first` as an M packet, then one P packet; return the payloads of
  ## the first two D packets the app sends back.
  let sock = newAsyncSocket()
  await sock.connect("127.0.0.1", Port(port))
  await sock.send("GET / HTTP/1.1\r\nHost: 127.0.0.1:" & $port &
                  "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" &
                  "Sec-WebSocket-Key: " & encode("0123456789abcdef0123") &
                  "\r\nSec-WebSocket-Version: 13\r\n\r\n")
  let fd = AsyncFD(getFd(sock))
  var resp = ""
  while not resp.contains("\r\n\r\n"):
    let chunk = await recvSome(fd, 4096)
    if chunk.len == 0: break
    resp.add chunk
  doAssert resp.startsWith("HTTP/1.1 101"), resp
  await sock.send(encodeWsClientFrame(wsOpBinary,
    encodePacket(PacketTypeMeta, first), mask()))
  await sock.send(encodeWsClientFrame(wsOpBinary,
    encodePacket(PacketTypeInput, "paste|x"), mask()))
  var dec = initWsFrameDecoder()
  var parser = initPacketParser()
  var attempts = 0
  while result.len < 2 and attempts < 400:
    # Bounded: a packet the bridge lost must fail the case, not hang it.
    let pending = recvSome(fd, 4096)
    if not await pending.withTimeout(5000): break
    let chunk = pending.read
    if chunk.len == 0: break
    dec.feed(chunk)
    while true:
      let msg = dec.popMessage()
      if not msg.complete: break
      parser.feedString(msg.payload)
      while parser.pendingPackets() > 0:
        let (_, kind, payload) = parser.pop()
        if kind == 'D': result.add payload
    inc attempts
  sock.close()

proc serverTask(server: Server) {.async.} =
  try:
    await server.serve()
  except CatchableError:
    discard

suite "isonim-tui-serve: the caps| capability declaration":

  test "the bytes of a declaration, in the fixed field order":
    check encodeCapsMeta(Declared) ==
      "caps|{\"xtermJs\":\"5.3.0\",\"renderer\":\"webgl\"," &
      "\"customGlyphs\":true,\"unicodeVersion\":\"11\"," &
      "\"truecolor\":true,\"sgrMouse\":true}"
    check encodeCapsMeta(Declared).isCapsMeta
    check not "resize|80|24".isCapsMeta

  test "a declaration decodes to what was declared":
    check decodeCapsMeta(encodeCapsMeta(Declared)) == Declared
    let dom = ClientCaps(xtermJs: "5.3.0", renderer: "dom",
                         customGlyphs: false, unicodeVersion: "6")
    check decodeCapsMeta(encodeCapsMeta(dom)) == dom

  test "what is not a declaration is refused, naming why":
    template refused(payload, why: string) =
      var msg = ""
      try:
        discard decodeCapsMeta(payload)
      except TuiPacketProtocolError as e:
        msg = e.msg
      checkpoint(payload & " -> " & msg)
      check why in msg
    refused("resize|80|24", "prefix")
    refused("caps|{", "not valid JSON")
    refused("caps|[]", "not a JSON object")
    refused(encodeCapsMeta(Declared).replace(",\"sgrMouse\":true", ""),
            "sgrMouse")
    refused(encodeCapsMeta(Declared).replace("\"customGlyphs\":true",
                                             "\"customGlyphs\":\"yes\""),
            "customGlyphs")
    refused(encodeCapsMeta(Declared).replace("webgl", "svg"), "renderer")
    refused(encodeCapsMeta(Declared).replace("\"11\"", "\"15\""),
            "unicodeVersion")

  test "through the bridge, the declaration reaches the app first, on every connection":
    when defined(windows):
      skip()
    else:
      randomize()
      let appExe = fixturePath()
      let port = pickPort()
      proc launcher(): Process {.closure, gcsafe.} =
        {.cast(gcsafe).}:
          startProcess(appExe, args = @[], options = {})
      let server = newServer(ServeConfig(port: Port(port), staticDir: ".",
                                         launchApp: launcher))
      asyncCheck serverTask(server)
      for i in 0 .. 5: poll(50)
      for connection in 1 .. 3:
        let replies = waitFor clientFlow(port, encodeCapsMeta(Declared))
        checkpoint("connection " & $connection & ": " & $replies)
        check replies == @["caps:webgl,11,true", "echo:paste|x"]
      let refused = waitFor clientFlow(port, "caps|{\"renderer\":\"webgl\"}")
      checkpoint($refused)
      check refused.len == 2 and refused[0].startsWith("caps-refused:")
      for i in 0 .. 5: poll(20)
      server.close()
