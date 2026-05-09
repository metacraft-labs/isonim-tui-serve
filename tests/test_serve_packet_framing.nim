## test_serve_packet_framing — packet codec round-trip.
##
## Round-trip a representative packet sequence through encode + parse;
## the decoded `(kind, payload)` pairs must match what was encoded.
## Exercises partial-buffer carry-over by feeding the parser in
## prime-sized chunks.

import std/unittest
import isonim_tui_serve

suite "isonim-tui-serve: packet codec":

  test "encode + parse round-trip across chunked feeds":
    var p = initPacketParser()
    let pkts = @[
      ('D', "hello world"),
      ('M', "resize|80|24"),
      ('P', "key|enter|0|"),
      ('D', ""),
      ('P', "key|a|97|"),
      ('M', "ping"),
    ]
    var combined = ""
    for (k, v) in pkts:
      combined.add encodePacket(k, v)
    # Feed in 7-byte chunks to exercise partial-packet boundary handling.
    var i = 0
    while i < combined.len:
      let j = min(i + 7, combined.len)
      p.feedString(combined[i ..< j])
      i = j
    check p.pendingPackets() == pkts.len
    var decoded: seq[(char, string)] = @[]
    while p.pendingPackets() > 0:
      let (ok, kind, payload) = p.pop()
      check ok
      decoded.add (kind, payload)
    check decoded == pkts

  test "empty payload still produces a packet":
    var p = initPacketParser()
    p.feedString(encodePacket('D', ""))
    let (ok, kind, payload) = p.pop()
    check ok
    check kind == 'D'
    check payload == ""

  test "large payload survives chunking":
    var p = initPacketParser()
    var big = newString(50_000)
    for i in 0 ..< big.len: big[i] = char((i mod 95) + 32)
    let pkt = encodePacket('D', big)
    # Feed one byte at a time.
    for ch in pkt:
      p.feedString($ch)
    let (ok, kind, payload) = p.pop()
    check ok
    check kind == 'D'
    check payload == big
