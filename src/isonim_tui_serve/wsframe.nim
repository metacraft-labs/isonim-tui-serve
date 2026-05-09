## Minimal RFC 6455 WebSocket framing.
##
## Implements:
##
##   * Server-side frame *encode* (FIN + opcode + length, no mask).
##   * Server-side frame *decode* of client→server frames (mandatory
##     mask per RFC 6455 §5.3).
##   * Binary, text, ping, pong, close opcodes. Continuation frames
##     are *not* supported — the test client and the reference HTML
##     send each packet as a single frame, which is plenty for the
##     bridge use-case.
##
## Hand-rolled because:
##
##   * The Nim ecosystem has WebSocket libs (e.g. `ws`, `news`) but
##     pulling them in would force a heavier dep tree on the serve
##     repo. The framing itself is ~80 LOC of bit-twiddling.
##   * Predictable behaviour is more important than spec coverage for
##     a development bridge.
##
## *No threads, no mocks.* Pure functions over `string` + a single
## stream-state object.

type
  WsOpcode* = enum
    wsOpContinuation = 0x0
    wsOpText = 0x1
    wsOpBinary = 0x2
    wsOpClose = 0x8
    wsOpPing = 0x9
    wsOpPong = 0xA

  WsMessage* = object
    complete*: bool
    opcode*: WsOpcode
    payload*: string

  WsFrameDecoder* = object
    buf: string
    queue: seq[WsMessage]

proc initWsFrameDecoder*(): WsFrameDecoder =
  WsFrameDecoder(buf: "", queue: @[])

# ---------------------------------------------------------------------------
# Encode (server → client; no mask)
# ---------------------------------------------------------------------------

proc encodeWsFrame*(opcode: WsOpcode; payload: string): string =
  ## Build one un-masked WebSocket frame. FIN=1, no extensions, no
  ## continuations.
  let n = payload.len
  var hdr = newString(2)
  hdr[0] = char(0x80 or (uint8(ord(opcode)) and 0x0F))
  if n < 126:
    hdr[1] = char(uint8(n))  # MASK bit clear
  elif n <= 0xFFFF:
    hdr[1] = char(126)
    hdr.add char((n shr 8) and 0xFF)
    hdr.add char(n and 0xFF)
  else:
    hdr[1] = char(127)
    let n64 = uint64(n)
    for shift in countdown(7, 0):
      hdr.add char(uint8((n64 shr (shift * 8)) and 0xFF))
  result = hdr & payload

proc encodeWsBinaryFrame*(payload: string): string {.inline.} =
  encodeWsFrame(wsOpBinary, payload)

proc encodeWsTextFrame*(payload: string): string {.inline.} =
  encodeWsFrame(wsOpText, payload)

# ---------------------------------------------------------------------------
# Encode (client → server; with mask) — used by the test
# ---------------------------------------------------------------------------

proc encodeWsClientFrame*(opcode: WsOpcode; payload: string;
                          mask: array[4, byte]): string =
  ## Build one frame from a client-side perspective: MASK bit set,
  ## payload XOR-masked with the given key. Used by the integration
  ## test that talks to the server with a hand-rolled client.
  let n = payload.len
  var hdr = newString(2)
  hdr[0] = char(0x80 or (uint8(ord(opcode)) and 0x0F))
  if n < 126:
    hdr[1] = char(0x80 or uint8(n))
  elif n <= 0xFFFF:
    hdr[1] = char(0x80 or 126)
    hdr.add char((n shr 8) and 0xFF)
    hdr.add char(n and 0xFF)
  else:
    hdr[1] = char(0x80 or 127)
    let n64 = uint64(n)
    for shift in countdown(7, 0):
      hdr.add char(uint8((n64 shr (shift * 8)) and 0xFF))
  for b in mask:
    hdr.add char(b)
  var masked = newString(n)
  for i in 0 ..< n:
    masked[i] = char(uint8(payload[i]) xor mask[i mod 4])
  result = hdr & masked

# ---------------------------------------------------------------------------
# Decode (client → server; mask required)
# ---------------------------------------------------------------------------

proc tryParseFrame(buf: string; off: var int;
                   out_msg: var WsMessage): bool =
  ## Try to parse one full frame starting at `buf[off]`. On success,
  ## advance `off` to the byte after the frame and fill `out_msg`.
  ## Returns false (and leaves `off` untouched) if the buffer doesn't
  ## yet hold a complete frame.
  let start = off
  if buf.len - start < 2: return false
  let b0 = uint8(buf[start])
  let b1 = uint8(buf[start + 1])
  let opcode = WsOpcode(int(b0 and 0x0F))
  let masked = (b1 and 0x80) != 0
  var lenField = int(b1 and 0x7F)
  var headerLen = 2
  var payloadLen = lenField
  if lenField == 126:
    if buf.len - start < headerLen + 2: return false
    payloadLen = (int(uint8(buf[start + 2])) shl 8) or
                 int(uint8(buf[start + 3]))
    headerLen += 2
  elif lenField == 127:
    if buf.len - start < headerLen + 8: return false
    payloadLen = 0
    for i in 0 ..< 8:
      payloadLen = (payloadLen shl 8) or int(uint8(buf[start + 2 + i]))
    headerLen += 8
  var maskKey: array[4, byte]
  if masked:
    if buf.len - start < headerLen + 4: return false
    for i in 0 ..< 4:
      maskKey[i] = byte(buf[start + headerLen + i])
    headerLen += 4
  if buf.len - start < headerLen + payloadLen: return false
  var payload = newString(payloadLen)
  for i in 0 ..< payloadLen:
    let raw = byte(buf[start + headerLen + i])
    payload[i] = char(if masked: raw xor maskKey[i mod 4] else: raw)
  out_msg = WsMessage(complete: true, opcode: opcode, payload: payload)
  off = start + headerLen + payloadLen
  true

proc feed*(d: var WsFrameDecoder; data: string) =
  if data.len > 0:
    d.buf.add(data)
  var off = 0
  while off < d.buf.len:
    var msg: WsMessage
    if not tryParseFrame(d.buf, off, msg):
      break
    d.queue.add msg
  if off > 0:
    if off >= d.buf.len:
      d.buf.setLen(0)
    else:
      d.buf = d.buf[off ..^ 1]

proc popMessage*(d: var WsFrameDecoder): WsMessage =
  if d.queue.len == 0:
    return WsMessage(complete: false)
  let m = d.queue[0]
  d.queue.delete(0)
  m
