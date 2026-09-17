## test_serve_bridge_child_io — the bridge's child-process contract.
##
## *Why this file exists.* `tests/test_serve_packet_bridge.nim` proves the
## codecs meet in the middle: one packet in, one packet out. That is a
## *codec* claim, and it is blind to everything the bridge does to the child
## around it — who reads which of the child's pipes, whether the child is
## reaped, whether a chatty child wedges. A bug that stole 399 of 400 packets
## passed it, because one packet sent immediately after connect is delivered
## before the competing reader's first poll interval elapses.
##
## So the claims here are about the *stream*, not the round trip:
##
##   1. **Nothing else reads the child's stdout.** `poStdErrToStdOut` makes
##      `startProcess` set `errHandle = outHandle` (osproc, POSIX branch) —
##      one pipe, two names. A stderr drain that polls `errorHandle` without
##      checking is then a second reader on the packet stream, and `read(2)`
##      hands each chunk to exactly one of them. Measured on the unfixed
##      code: 400 packets sent, 1 delivered.
##   2. **The child's stderr is still drained when it really is a separate
##      pipe** — the hang the drain exists to prevent. An undrained pipe
##      stops the child mid-`write` at 64 KiB, and the session silently stops
##      painting.
##   3. **The child is reaped**, not merely signalled — no zombie per
##      browser connection.
##   4. `listen` / `boundPort` make `Port(0)` usable, and `staticFiles`
##      shadows `staticDir`.
##
## *Not timing-dependent.* Every verdict is a count or a state, never a
## deadline: claim 1 asserts *exactly* the packets sent came back, in order;
## claims 2 and 3 assert an event that either happens or never does. The
## timeouts below only bound how long a failing run takes — no assertion
## passes *because* a timeout was generous, and none fails because the host
## was slow. (A test whose green verdict needed a sleep to land first is the
## defect this file was written to catch.)
##
## Real-stack, no mocks: the production server object in-process, a real OS
## child process, and a hand-rolled WebSocket client on a real socket.

import std/[asyncdispatch, asyncnet, base64, os, osproc, posix, random,
            strutils, times, unittest]

import isonim_tui_serve

const
  StreamPacketCount = 400
    ## Enough that a competing reader on the same pipe cannot fail to win a
    ## turn: the bridge's stdout loop yields to the dispatcher on every
    ## `EAGAIN` and on every WebSocket send, and the stderr drain's own poll
    ## is 20 ms. One packet (what the older test sends) is decided before
    ## either loop has polled twice; 400 is decided many times over.

  FloodBytes = 256 * 1024
    ## Four times the 64 KiB Linux pipe capacity, so "the child blocked" is
    ## not a question of how the kernel rounds the buffer.

  IdleTimeoutMs = 10_000
    ## How long the client waits for the *next* byte before concluding the
    ## stream has stalled. Sized for a loaded shared runner; the healthy path
    ## never reaches it, and the broken path fails no matter how long it is.

  ReapTimeoutMs = 15_000

# ---------------------------------------------------------------------------
# Fixture
# ---------------------------------------------------------------------------

proc fixturePath(): string =
  let here = currentSourcePath().parentDir
  let outBin = here / "echo_packet_app"
  let src = here / "echo_packet_app.nim"
  if not fileExists(outBin) or
     getLastModificationTime(src) > getLastModificationTime(outBin):
    let cmd = "nim c -d:release --threads:on --hints:off --warnings:off " &
              "--path:" & here / ".." / "src" & " " &
              "-o:" & outBin & " " & src
    let exit = execShellCmd(cmd)
    doAssert exit == 0, "failed to build echo_packet_app: " & cmd
  outBin

proc makeLauncher(exe: string; mergeStderr: bool): AppLauncher =
  let exeCap = exe
  let opts = if mergeStderr: {poStdErrToStdOut} else: {}
  result = proc (): Process {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      startProcess(exeCap, args = @[], options = opts)

# ---------------------------------------------------------------------------
# Minimal WebSocket client (same shape as test_serve_packet_bridge.nim)
# ---------------------------------------------------------------------------

proc randMaskKey(): array[4, byte] =
  for i in 0 ..< 4: result[i] = byte(rand(0 .. 255))

proc recvSome(fd: AsyncFD; size: int): Future[string] {.async.} =
  var buf = newString(size)
  let n = await asyncdispatch.recvInto(fd, addr buf[0], size)
  if n <= 0: return ""
  buf.setLen(n)
  result = buf

proc recvSomeOrIdle(fd: AsyncFD; size: int): Future[string] {.async.} =
  ## `recvSome` with an idle bound, so a stalled stream FAILS the test
  ## instead of hanging it forever.
  let pending = recvSome(fd, size)
  if await withTimeout(pending, IdleTimeoutMs):
    return pending.read()
  # Orphan the abandoned read rather than leaving an unconsumed failure.
  pending.callback = proc () = discard
  return ""

proc handshake(s: AsyncSocket; port: int) {.async.} =
  let key = encode("0123456789abcdef0123")
  await s.send("GET / HTTP/1.1\r\n" &
               "Host: 127.0.0.1:" & $port & "\r\n" &
               "Upgrade: websocket\r\n" &
               "Connection: Upgrade\r\n" &
               "Sec-WebSocket-Key: " & key & "\r\n" &
               "Sec-WebSocket-Version: 13\r\n\r\n")
  let fd = AsyncFD(getFd(s))
  var resp = ""
  while not resp.contains("\r\n\r\n"):
    let chunk = await recvSomeOrIdle(fd, 4096)
    if chunk.len == 0: break
    resp.add(chunk)
  doAssert resp.startsWith("HTTP/1.1 101"), "handshake failed: " & resp

proc connectWs(port: int): Future[AsyncSocket] {.async.} =
  let sock = newAsyncSocket()
  await sock.connect("127.0.0.1", Port(port))
  await handshake(sock, port)
  return sock

proc sendPacket(sock: AsyncSocket; kind: char; payload: string) {.async.} =
  await sock.send(encodeWsClientFrame(
    wsOpBinary, encodePacket(kind, payload), randMaskKey()))

proc collectPayloads(sock: AsyncSocket; want: int): Future[seq[string]] {.async.} =
  ## Read WebSocket frames until `want` `D` payloads have arrived or the
  ## stream goes idle. Returns however many actually arrived — the caller
  ## asserts on the count, so "fewer" is a failure rather than a hang.
  let fd = AsyncFD(getFd(sock))
  var dec = initWsFrameDecoder()
  var parser = initPacketParser()
  var got: seq[string] = @[]
  while got.len < want:
    let chunk = await recvSomeOrIdle(fd, 65536)
    if chunk.len == 0: break
    dec.feed(chunk)
    while true:
      let msg = dec.popMessage()
      if not msg.complete: break
      if msg.opcode != wsOpBinary and msg.opcode != wsOpText: continue
      parser.feedString(msg.payload)
      while parser.pendingPackets() > 0:
        let (ok, kind, payload) = parser.pop()
        if not ok: break
        if kind == PacketTypeDisplay: got.add(payload)
  return got

proc firstMismatch(got: seq[string]): int =
  ## Index of the first payload that is not this position's echo, or `-1`.
  ## Reported as an index rather than by comparing two 400-element seqs, so a
  ## failure names the packet that went missing instead of printing the wire.
  for i in 0 ..< got.len:
    if got[i] != "echo:seq" & $i & "|": return i
  -1

proc httpGet(port: int; path: string): Future[(string, string)] {.async.} =
  ## Returns `(status line, body)`. Reads exactly `Content-Length` bytes so
  ## it does not depend on the server closing the connection.
  let sock = newAsyncSocket()
  await sock.connect("127.0.0.1", Port(port))
  await sock.send("GET " & path & " HTTP/1.1\r\n" &
                  "Host: 127.0.0.1:" & $port & "\r\n" &
                  "Connection: close\r\n\r\n")
  let fd = AsyncFD(getFd(sock))
  var resp = ""
  while not resp.contains("\r\n\r\n"):
    let chunk = await recvSomeOrIdle(fd, 4096)
    if chunk.len == 0: break
    resp.add(chunk)
  let headEnd = resp.find("\r\n\r\n")
  doAssert headEnd >= 0, "no HTTP headers in: " & resp
  let head = resp[0 ..< headEnd]
  var body = resp[headEnd + 4 ..^ 1]
  var contentLen = 0
  for line in head.splitLines():
    if line.toLowerAscii.startsWith("content-length:"):
      contentLen = parseInt(line.split(':')[1].strip())
  while body.len < contentLen:
    let chunk = await recvSomeOrIdle(fd, 4096)
    if chunk.len == 0: break
    body.add(chunk)
  sock.close()
  return (head.splitLines()[0], body)

# ---------------------------------------------------------------------------
# Server / process helpers
# ---------------------------------------------------------------------------

proc acceptTask(server: Server) {.async.} =
  try:
    await server.acceptLoop()
  except CatchableError:
    discard

proc startServer(cfg: ServeConfig): Server =
  ## `listen` first, THEN accept — so `boundPort` is already the kernel's
  ## answer and no test has to guess a port or race a bind.
  result = newServer(cfg)
  result.listen()
  asyncCheck acceptTask(result)

proc pumpDispatcher(ms: int) =
  ## Give the dispatcher `ms` of turns. Used only where the thing under test
  ## runs on the server's side of the socket (reaping) and the test itself
  ## has nothing to await.
  let deadline = epochTime() + float(ms) / 1000.0
  while epochTime() < deadline:
    try:
      poll(20)
    except ValueError, CatchableError:
      sleep(20)

proc procState(pid: int): char =
  ## `'-'` when the process is gone, otherwise its `/proc` state letter
  ## (`'Z'` for a zombie). The `comm` field may contain spaces and
  ## parentheses, so the state is read relative to the LAST `')'`.
  let statPath = "/proc/" & $pid & "/stat"
  if not fileExists(statPath): return '-'
  var raw = ""
  try:
    raw = readFile(statPath)
  except CatchableError:
    return '-'
  let close = raw.rfind(')')
  if close < 0 or close + 2 >= raw.len: return '-'
  raw[close + 2]

template captureStderr(sink: var string; body: untyped) =
  ## Redirect fd 2 to a temp file for the duration of `body`, then read it
  ## back. The bridge's stderr drain writes to fd 2, so this is how a test
  ## observes the relay — and it also keeps 256 KiB of relayed flood out of
  ## the suite's log. `unittest` reports on stdout, which is untouched.
  flushFile(stderr)
  let capPath = getTempDir() /
    ("isonim_tui_serve_stderr_" & $getpid() & "_" & $rand(1_000_000) & ".log")
  let capFd = posix.open(capPath.cstring,
                         O_RDWR or O_CREAT or O_TRUNC, 0o600.Mode)
  doAssert capFd >= 0, "cannot open " & capPath
  let savedFd = dup(STDERR_FILENO)
  doAssert savedFd >= 0
  doAssert dup2(capFd, STDERR_FILENO) >= 0
  discard posix.close(capFd)
  try:
    body
  finally:
    flushFile(stderr)
    discard dup2(savedFd, STDERR_FILENO)
    discard posix.close(savedFd)
  sink = try: readFile(capPath) except CatchableError: ""
  removeFile(capPath)

# ---------------------------------------------------------------------------
# Client flows
#
# Top-level rather than nested in the `test` bodies: `{.async.}` inside a
# proc body makes asyncmacro emit a closure iterator whose generated
# `except:` trips `[BareExcept]`, and this suite compiles warning-clean.
# ---------------------------------------------------------------------------

proc streamFlow(port: int; count: int): Future[seq[string]] {.async.} =
  ## Send `count` `P` packets back to back, then read until `count` `D`
  ## payloads have come back (or the stream stalls).
  let sock = await connectWs(port)
  for i in 0 ..< count:
    await sendPacket(sock, PacketTypeInput, "seq" & $i & "|")
  let got = await collectPayloads(sock, count)
  sock.close()
  return got

proc chattyFlow(port: int; marker: string;
                floodBytes: int): Future[seq[string]] {.async.} =
  ## Make the child log, then flood its stderr past the pipe capacity, then
  ## answer one more packet — so the third payload only exists if the child
  ## survived the flood.
  let sock = await connectWs(port)
  await sendPacket(sock, PacketTypeMeta, "log:" & marker)
  await sendPacket(sock, PacketTypeMeta, "flood:" & $floodBytes)
  await sendPacket(sock, PacketTypeInput, "after-flood|")
  let got = await collectPayloads(sock, 3)
  sock.close()
  return got

proc pidFlow(port: int): Future[string] {.async.} =
  ## Ask the child for its own pid, then hang up.
  let sock = await connectWs(port)
  await sendPacket(sock, PacketTypeMeta, "pid")
  let got = await collectPayloads(sock, 1)
  sock.close()
  return (if got.len == 1: got[0] else: "")

# ---------------------------------------------------------------------------

suite "isonim-tui-serve: bridge child I/O":

  setup:
    randomize()

  test "test_serve_bridge_no_packet_loss_merged_stderr":
    ## THE REGRESSION. With `poStdErrToStdOut` the child has ONE pipe named
    ## twice, so any second reader of `errorHandle` is a second reader of the
    ## packet stream and the bytes go to whichever loop calls `read` first.
    ## The count must be exact: 400 sent, 400 back, in order.
    when defined(windows):
      skip()
    else:
      let server = startServer(ServeConfig(
        port: Port(0), address: "127.0.0.1", staticDir: ".",
        launchApp: makeLauncher(fixturePath(), mergeStderr = true)))
      let port = int(server.boundPort())
      check port != 0

      let got = waitFor streamFlow(port, StreamPacketCount)
      check got.len == StreamPacketCount
      check firstMismatch(got) == -1
      server.close()
      pumpDispatcher(200)

  test "test_serve_bridge_no_packet_loss_separate_stderr":
    ## The same claim for a child whose stderr genuinely is its own pipe —
    ## the configuration in which the drain must keep running.
    when defined(windows):
      skip()
    else:
      let server = startServer(ServeConfig(
        port: Port(0), address: "127.0.0.1", staticDir: ".",
        launchApp: makeLauncher(fixturePath(), mergeStderr = false)))
      let port = int(server.boundPort())

      let got = waitFor streamFlow(port, StreamPacketCount)
      check got.len == StreamPacketCount
      check firstMismatch(got) == -1
      server.close()
      pumpDispatcher(200)

  test "test_serve_bridge_drains_separate_stderr_pipe":
    ## What the drain is FOR. The child writes a marker line, then 256 KiB —
    ## four pipe-capacities — and only then answers. Undrained, it blocks
    ## inside that write and `D "flooded"` never arrives; the marker also
    ## proves the relay reaches the bridge's own stderr, prefixed.
    when defined(windows):
      skip()
    else:
      const Marker = "child-diagnostic-marker-7f3a"
      var relayed = ""
      var got: seq[string] = @[]
      captureStderr(relayed):
        let server = startServer(ServeConfig(
          port: Port(0), address: "127.0.0.1", staticDir: ".",
          launchApp: makeLauncher(fixturePath(), mergeStderr = false)))
        let port = int(server.boundPort())

        got = waitFor chattyFlow(port, Marker, FloodBytes)
        server.close()
        pumpDispatcher(200)

      check got == @["logged", "flooded", "echo:after-flood|"]
      check ("[app] " & Marker) in relayed

  test "test_serve_bridge_reaps_the_child":
    ## `terminate()` alone leaves a `<defunct>` entry per browser connection
    ## for the life of the bridge. After the client hangs up the child must
    ## leave the process table entirely — never linger as `Z`.
    when defined(windows):
      skip()
    else:
      let server = startServer(ServeConfig(
        port: Port(0), address: "127.0.0.1", staticDir: ".",
        launchApp: makeLauncher(fixturePath(), mergeStderr = false)))
      let port = int(server.boundPort())

      let answer = waitFor pidFlow(port)
      check answer.startsWith("pid:")
      let childPid = parseInt(answer[4 ..^ 1])
      # Still alive here by construction, not by luck: `pidFlow` closes the
      # socket synchronously after its last `await`, so `waitFor` returns
      # without polling again and the bridge has had no turn to notice the
      # hang-up. This asserts the pid is a real process, not that we won a
      # race with the reaper.
      check procState(childPid) != '-'

      var state = procState(childPid)
      let deadline = epochTime() + float(ReapTimeoutMs) / 1000.0
      while state != '-' and epochTime() < deadline:
        pumpDispatcher(50)
        state = procState(childPid)
      check state == '-'
      server.close()

  test "test_serve_listen_boundport_and_static_bundle":
    ## `Port(0)` is only usable if the kernel's answer is readable between
    ## the bind and the first accept, and an embedded page must not be
    ## shadowed by a same-named file in the working directory.
    when defined(windows):
      skip()
    else:
      let shadowDir = getTempDir() / ("isonim_tui_serve_static_" & $getpid())
      createDir(shadowDir)
      writeFile(shadowDir / "index.html", "FROM DISK")
      defer: removeDir(shadowDir)

      let cfg = ServeConfig(
        port: Port(0), address: "127.0.0.1",
        staticDir: shadowDir,
        staticFiles: @[StaticFile(path: "/index.html",
                                  mime: "text/html; charset=utf-8",
                                  body: "FROM MEMORY")],
        launchApp: nil)
      let server = startServer(cfg)
      # The config still says 0; only `boundPort` knows.
      check int(cfg.port) == 0
      check int(server.boundPort()) != 0
      let port = int(server.boundPort())

      let (status, body) = waitFor httpGet(port, "/")
      check status.startsWith("HTTP/1.1 200")
      check body == "FROM MEMORY"

      let (status2, body2) = waitFor httpGet(port, "/missing.js")
      check status2.startsWith("HTTP/1.1 404")
      check body2.len > 0

      server.close()
      pumpDispatcher(100)
