## echo_packet_app — minimal test fixture.
##
## Reads framed packets from stdin; for each `P` packet received,
## emits a `D` packet whose payload is `"echo:" & inputPayload`.
## Used by `test_serve_packet_bridge.nim` to exercise the bridge with
## a real subprocess.

import std/[posix]
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
      elif kind == 'M' and payload == "quit":
        return

main()
