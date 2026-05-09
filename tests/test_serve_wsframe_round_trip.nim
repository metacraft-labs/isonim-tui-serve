## test_serve_wsframe_round_trip — RFC 6455 codec round-trip.

import std/unittest
import isonim_tui_serve

suite "isonim-tui-serve: WebSocket framing":

  test "client→server masked frame decode":
    let mask: array[4, byte] = [byte 0xDE, 0xAD, 0xBE, 0xEF]
    let payload = "hello, websocket"
    let frame = encodeWsClientFrame(wsOpBinary, payload, mask)
    var dec = initWsFrameDecoder()
    dec.feed(frame)
    let msg = dec.popMessage()
    check msg.complete
    check msg.opcode == wsOpBinary
    check msg.payload == payload

  test "server→client unmasked frame round-trips":
    # Server-side encode produces an unmasked frame. Decoder accepts
    # both masked and unmasked because it inspects the MASK bit.
    let payload = "binary data " & $newSeq[char](200).len
    let frame = encodeWsBinaryFrame(payload)
    var dec = initWsFrameDecoder()
    dec.feed(frame)
    let msg = dec.popMessage()
    check msg.complete
    check msg.opcode == wsOpBinary
    check msg.payload == payload

  test "extended length 16-bit field":
    let payload = newString(200)  # > 125 → 2-byte length field
    let mask: array[4, byte] = [byte 1, 2, 3, 4]
    let frame = encodeWsClientFrame(wsOpBinary, payload, mask)
    var dec = initWsFrameDecoder()
    dec.feed(frame)
    let msg = dec.popMessage()
    check msg.complete
    check msg.payload.len == 200

  test "extended length 64-bit field":
    let payload = newString(70_000)  # > 65535 → 8-byte length field
    let mask: array[4, byte] = [byte 9, 8, 7, 6]
    let frame = encodeWsClientFrame(wsOpBinary, payload, mask)
    var dec = initWsFrameDecoder()
    dec.feed(frame)
    let msg = dec.popMessage()
    check msg.complete
    check msg.payload.len == 70_000

  test "fragmented stream feed":
    let payload = "fragmented"
    let mask: array[4, byte] = [byte 1, 2, 3, 4]
    let frame = encodeWsClientFrame(wsOpBinary, payload, mask)
    var dec = initWsFrameDecoder()
    # Feed 3 bytes at a time.
    var i = 0
    while i < frame.len:
      let j = min(i + 3, frame.len)
      dec.feed(frame[i ..< j])
      i = j
    let msg = dec.popMessage()
    check msg.complete
    check msg.payload == payload

  test "compute_accept_key against RFC 6455 sample":
    # RFC 6455 §1.3: dGhlIHNhbXBsZSBub25jZQ== → s3pPLMBiTxaQ9kYGzzhZRbK+xOo=
    check computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==") ==
      "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
