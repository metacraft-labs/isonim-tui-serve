## Packet framing — same wire shape as `isonim-tui/drivers/web_driver.nim`.
##
## 1-byte type ('D'/'M'/'P') + 4-byte big-endian length + payload.
## Re-implemented here so the serve repo doesn't need a hard dependency
## on `isonim-tui`'s source (it's a deliberately separate, public-ready
## library).

import std/[json, strutils]

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

# ---------------------------------------------------------------------------
# RS-M13: element-tree M sub-kind for the D/M/P transport.
#
# Mirrors the schema from
# ``isonim-render-serve/src/isonim_render_serve/packet.nim`` (RS-M11)
# with one addition: the body carries a top-level ``"boundsUnit"`` tag
# whose value is the string ``"cells"`` to signal that ``bounds``
# rectangles are in cell coordinates instead of surface pixels. The
# editor's hit-test branches on this tag.
#
# The codec is intentionally a stable, hand-rolled serializer so the
# on-wire bytes are reproducible across Nim versions (used by the
# round-trip tests that pin byte-for-byte equality).
# ---------------------------------------------------------------------------

const
  BoundsUnitCells* = "cells"
    ## Canonical value of the ``boundsUnit`` tag for the TUI transport.
    ## The RS-M11 schema implicitly defaults to ``"pixels"`` when the
    ## tag is absent, so non-TUI launchers stay byte-compatible.
  BoundsUnitPixels* = "pixels"
    ## Canonical value of the ``boundsUnit`` tag when the launcher
    ## emits manifests with pixel coordinates (the historic RS-M11
    ## default; the TUI launcher of RS-M13 uses ``"cells"``).

type
  TuiElementBounds* = object
    ## RS-M13: bounding rectangle in cell coordinates. ``x = col``,
    ## ``y = row``, ``w = cols``, ``h = rows``.
    x*, y*, w*, h*: int

  TuiElementEntry* = object
    id*: string
    componentPath*: string
    kind*: string
    bounds*: TuiElementBounds

  TuiElementTreeManifest* = object
    ## Top-level container for a TUI element-tree manifest. Pairs
    ## with the cadence rules the bridge enforces (one emission per
    ## connect + one per (id, bounds)-change). ``frameSeq`` keeps the
    ## semantic from the pixel transport even though the TUI launcher
    ## emits D packets rather than F packets — it's a monotonically
    ## increasing counter callers can hash.
    frameSeq*: int
    surfaceCols*, surfaceRows*: int
    elements*: seq[TuiElementEntry]

  TuiPacketProtocolError* = object of CatchableError
    ## Raised on any wire-protocol violation inside an M / P body
    ## (unknown ``type`` tag, missing required field, malformed JSON).
    ## Bridges that surface this should close the WS connection with
    ## status 1002.

proc jsonEscapeStr(s: string): string =
  ## RFC 8259 string escaper for the hand-rolled JSON emitter.
  result = newStringOfCap(s.len + 2)
  result.add '"'
  for ch in s:
    case ch
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    of '\b': result.add "\\b"
    of '\f': result.add "\\f"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else:
      if ch.uint8 < 0x20'u8:
        const hexChars = "0123456789abcdef"
        result.add "\\u00"
        result.add hexChars[int(ch.uint8 shr 4)]
        result.add hexChars[int(ch.uint8 and 0x0F'u8)]
      else:
        result.add ch
  result.add '"'

proc encodeElementTreeBody*(m: TuiElementTreeManifest): string =
  ## Build the JSON body for an ``element-tree`` M packet on the TUI
  ## transport. Field order locked to:
  ##
  ##   ``type, boundsUnit, frameSeq, surfaceCols, surfaceRows,
  ##    elements``
  ##
  ## and each element's field order locked to ``id, componentPath,
  ## kind, bounds`` with ``bounds`` ordered ``x, y, w, h``. The byte
  ## layout is pinned by ``test_serve_element_tree_roundtrip``.
  result = newStringOfCap(96 + 96 * m.elements.len)
  result.add "{\"type\":\"element-tree\""
  result.add ",\"boundsUnit\":"
  result.add jsonEscapeStr(BoundsUnitCells)
  result.add ",\"frameSeq\":"
  result.add $m.frameSeq
  result.add ",\"surfaceCols\":"
  result.add $m.surfaceCols
  result.add ",\"surfaceRows\":"
  result.add $m.surfaceRows
  result.add ",\"elements\":["
  for i, e in m.elements:
    if i > 0: result.add ','
    result.add "{\"id\":"
    result.add jsonEscapeStr(e.id)
    result.add ",\"componentPath\":"
    result.add jsonEscapeStr(e.componentPath)
    result.add ",\"kind\":"
    result.add jsonEscapeStr(e.kind)
    result.add ",\"bounds\":{\"x\":"
    result.add $e.bounds.x
    result.add ",\"y\":"
    result.add $e.bounds.y
    result.add ",\"w\":"
    result.add $e.bounds.w
    result.add ",\"h\":"
    result.add $e.bounds.h
    result.add "}}"
  result.add "]}"

proc isElementTreeBody*(body: string): bool =
  ## Cheap probe for the bridge's M-packet dispatcher. Substring scan
  ## is sufficient — callers route by sub-kind and only the launcher
  ## emits ``element-tree`` bodies on the TUI transport.
  body.contains("\"type\":\"element-tree\"")

proc decodeElementTreeBody*(body: string): TuiElementTreeManifest =
  ## Decode the JSON body of an ``element-tree`` M packet on the TUI
  ## transport. Raises ``TuiPacketProtocolError`` on shape violations.
  var node: JsonNode
  try:
    node = parseJson(body)
  except JsonParsingError, ValueError:
    raise newException(TuiPacketProtocolError,
      "element-tree body is not valid JSON")
  if node.kind != JObject:
    raise newException(TuiPacketProtocolError,
      "element-tree body is not a JSON object")
  if not node.hasKey("type") or node["type"].kind != JString or
      node["type"].getStr != "element-tree":
    raise newException(TuiPacketProtocolError,
      "element-tree body has wrong type tag")
  if not node.hasKey("boundsUnit") or node["boundsUnit"].kind != JString or
      node["boundsUnit"].getStr != BoundsUnitCells:
    raise newException(TuiPacketProtocolError,
      "element-tree body missing boundsUnit=\"cells\"")
  template intField(name: string): int =
    if not node.hasKey(name) or node[name].kind != JInt:
      raise newException(TuiPacketProtocolError,
        "element-tree body missing int field: " & name)
    node[name].getInt
  result.frameSeq = intField("frameSeq")
  result.surfaceCols = intField("surfaceCols")
  result.surfaceRows = intField("surfaceRows")
  if not node.hasKey("elements") or node["elements"].kind != JArray:
    raise newException(TuiPacketProtocolError,
      "element-tree body missing elements array")
  for raw in node["elements"]:
    if raw.kind != JObject:
      raise newException(TuiPacketProtocolError,
        "element-tree entry is not an object")
    template strField(host: JsonNode; name: string): string =
      if not host.hasKey(name) or host[name].kind != JString:
        raise newException(TuiPacketProtocolError,
          "element-tree entry missing string field: " & name)
      host[name].getStr
    var entry: TuiElementEntry
    entry.id = strField(raw, "id")
    entry.componentPath = strField(raw, "componentPath")
    entry.kind = strField(raw, "kind")
    if not raw.hasKey("bounds") or raw["bounds"].kind != JObject:
      raise newException(TuiPacketProtocolError,
        "element-tree entry missing bounds object")
    let b = raw["bounds"]
    template intB(name: string): int =
      if not b.hasKey(name) or b[name].kind != JInt:
        raise newException(TuiPacketProtocolError,
          "element-tree bounds missing int field: " & name)
      b[name].getInt
    entry.bounds = TuiElementBounds(
      x: intB("x"), y: intB("y"), w: intB("w"), h: intB("h"))
    result.elements.add entry

proc manifestKey*(m: TuiElementTreeManifest): string =
  ## Stable hash key over (id, bounds) tuples + surface dimensions. The
  ## bridge compares this against the per-connection cache and only
  ## emits an M packet when the key changes (RS-M11 cadence rule
  ## carried forward into RS-M13).
  result = $m.surfaceCols & 'x' & $m.surfaceRows & '|'
  for e in m.elements:
    result.add e.id
    result.add ':'
    result.add $e.bounds.x
    result.add ','
    result.add $e.bounds.y
    result.add ','
    result.add $e.bounds.w
    result.add ','
    result.add $e.bounds.h
    result.add ';'
