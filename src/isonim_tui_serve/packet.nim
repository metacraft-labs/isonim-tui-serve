## Packet framing — same wire shape as `isonim-tui/drivers/web_driver.nim`.
##
## 1-byte type ('D'/'M'/'P') + 4-byte big-endian length + payload.
## Re-implemented here so the serve repo doesn't need a hard dependency
## on `isonim-tui`'s source (it's a deliberately separate, public-ready
## library).

const
  PacketTypeDisplay* = 'D'
  PacketTypeMeta* = 'M'
  PacketTypeInput* = 'P'

proc encodePacket*(kind: char; payload: string): string =
  result = newString(5 + payload.len)
  result[0] = kind
  let n = uint32(payload.len)
  result[1] = char((n shr 24) and 0xFF)
  result[2] = char((n shr 16) and 0xFF)
  result[3] = char((n shr 8) and 0xFF)
  result[4] = char(n and 0xFF)
  if payload.len > 0:
    copyMem(addr result[5], unsafeAddr payload[0], payload.len)

type
  PacketParser* = object
    buf: string
    queue: seq[tuple[kind: char; payload: string]]

proc initPacketParser*(): PacketParser =
  PacketParser(buf: "", queue: @[])

proc feedString*(p: var PacketParser; data: string) =
  if data.len > 0:
    p.buf.add(data)
  var off = 0
  while p.buf.len - off >= 5:
    let kind = p.buf[off]
    let n = (uint32(byte(p.buf[off + 1])) shl 24) or
            (uint32(byte(p.buf[off + 2])) shl 16) or
            (uint32(byte(p.buf[off + 3])) shl 8) or
            uint32(byte(p.buf[off + 4]))
    if uint32(p.buf.len - off - 5) < n:
      break
    var payload = newString(int(n))
    if n > 0'u32:
      copyMem(addr payload[0], addr p.buf[off + 5], int(n))
    p.queue.add((kind: kind, payload: payload))
    off += 5 + int(n)
  if off > 0:
    if off >= p.buf.len:
      p.buf.setLen(0)
    else:
      p.buf = p.buf[off ..^ 1]

proc pop*(p: var PacketParser): (bool, char, string) =
  if p.queue.len == 0: return (false, '\0', "")
  let head = p.queue[0]
  p.queue.delete(0)
  return (true, head.kind, head.payload)

proc pendingPackets*(p: PacketParser): int {.inline.} = p.queue.len
