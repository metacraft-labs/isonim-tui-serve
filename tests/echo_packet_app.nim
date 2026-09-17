## echo_packet_app — minimal test fixture.
##
## Reads framed packets from stdin; for each `P` packet received,
## emits a `D` packet whose payload is `"echo:" & inputPayload`.
## Used by `test_serve_packet_bridge.nim` to exercise the bridge with
## a real subprocess.
##
## `M` packets are commands, so a test can make this fixture do the
## three things the bridge's child-handling has to survive:
##
##   * `pid`        — answer `D "pid:<n>"`, so a test can watch the OS
##                    process table and prove the bridge reaps it.
##   * `log:<text>` — write `<text>` to stderr, then answer `D "logged"`.
##   * `flood:<n>`  — write `<n>` bytes to stderr, then answer
##                    `D "flooded"`. With a stderr pipe nobody drains,
##                    any `n` above the 64 KiB pipe capacity wedges this
##                    process mid-write and the `D` never comes.
##   * `quit`       — exit.

import std/[posix, strutils]
import isonim_tui_serve

proc writeAll(fd: cint; s: string) =
  if s.len == 0: return
  var off = 0
  while off < s.len:
    let p = cast[pointer](cast[uint](unsafeAddr s[0]) + uint(off))
    let n = posix.write(fd, p, s.len - off)
    if n <= 0: return
    off += int(n)

proc main() =
  ## Read from raw stdin FD so we wake on every chunk the kernel
  ## delivers (rather than waiting for a 4096-byte buffer to fill).
  var parser = initPacketParser()
  var buf: array[4096, byte]
  while true:
    let n = posix.read(STDIN_FILENO, addr buf[0], buf.len)
    if n <= 0: break
    var s = newString(int(n))
    for i in 0 ..< int(n): s[i] = char(buf[i])
    parser.feedString(s)
    while parser.pendingPackets() > 0:
      let (ok, kind, payload) = parser.pop()
      if not ok: break
      if kind == 'P':
        writeAll(STDOUT_FILENO, encodePacket('D', "echo:" & payload))
      elif kind == 'M':
        if payload == "quit":
          return
        elif payload == "pid":
          writeAll(STDOUT_FILENO, encodePacket('D', "pid:" & $getpid()))
        elif payload.startsWith("log:"):
          writeAll(STDERR_FILENO, payload[4 ..^ 1] & "\n")
          writeAll(STDOUT_FILENO, encodePacket('D', "logged"))
        elif payload.startsWith("flood:"):
          let total = parseInt(payload[6 ..^ 1])
          # One 1 KiB line at a time: enough lines that no plausible pipe
          # capacity swallows the lot, and still line-shaped so a drain that
          # relays it produces readable output.
          let line = repeat('x', 1023) & "\n"
          var written = 0
          while written < total:
            writeAll(STDERR_FILENO, line)
            written += line.len
          writeAll(STDOUT_FILENO, encodePacket('D', "flooded"))

main()
