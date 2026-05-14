## test_serve_select_story_roundtrip — RS-M13 P-packet body codec.
##
## Asserts:
##
##   1. ``encodeSelectStoryBody`` and ``encodeApplyMutationBody`` from
##      ``isonim_tui_serve/story_dispatch.nim`` emit byte-for-byte the
##      same bytes as ``isonim_render_serve``'s
##      ``encodeSelectStoryJson`` / ``encodeApplyMutationJson`` — the
##      same JSON shape travels through I packets (render-serve) AND
##      P packets (this repo), so the editor's encoders stay shared.
##   2. ``decodeTuiStoryEvent`` round-trips back to the same values.
##   3. Framing each body as a P packet via ``encodePacket('P', body)``
##      and feeding the bytes through the ``PacketParser`` yields one
##      P packet with the original body intact.
##
## RS-M13 fix-cycle 1: the reference encoders below are byte-for-byte
## vendored copies of ``isonim-render-serve``'s
## ``encodeSelectStoryJson`` / ``encodeApplyMutationJson`` /
## ``jsonEscape`` (defined in
## ``isonim-render-serve/src/isonim_render_serve/event_dispatch.nim``
## lines 307-372 at the RS-M12 revision). Importing render-serve as a
## sibling-repo dep is awkward from this test's build path; instead
## we vendor the source and force the inputs to exercise the escape
## paths (\\, \", \n, \t, low control char) so any future divergence
## between the two encoders surfaces here rather than as silent on-
## wire drift. If render-serve's encoders change, this file MUST
## change in lock-step.

import std/[json, strutils, unittest]
import isonim_tui_serve

# Reference jsonEscape — exact copy of render-serve's
# ``jsonEscape`` (event_dispatch.nim:307-331). Pinned to the RS-M12
# spec: ASCII content escape rules per RFC 8259 with the long form
# ``\u00XX`` for control characters below 0x20.
proc refJsonEscape(s: string): string =
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

# Reference encoders — exact copies of render-serve's
# ``encodeSelectStoryJson`` / ``encodeApplyMutationJson``
# (event_dispatch.nim:333-372). Field order is the spec contract:
# ``type, group, name, kind, storyId, properties?`` and
# ``type, target, key, value, scope``.
proc refSelectStoryBody(group, name, kind, storyId: string;
                        properties: JsonNode = nil): string =
  result = newStringOfCap(96 + storyId.len + group.len +
                          name.len + kind.len)
  result.add "{\"type\":\"select-story\""
  result.add ",\"group\":"
  result.add refJsonEscape(group)
  result.add ",\"name\":"
  result.add refJsonEscape(name)
  result.add ",\"kind\":"
  result.add refJsonEscape(kind)
  result.add ",\"storyId\":"
  result.add refJsonEscape(storyId)
  if properties != nil:
    result.add ",\"properties\":"
    result.add $properties
  result.add "}"

proc refApplyMutationBody(target, key: string; value: JsonNode;
                          scopeStr: string): string =
  result = newStringOfCap(96 + target.len + key.len)
  result.add "{\"type\":\"apply-mutation\""
  result.add ",\"target\":"
  result.add refJsonEscape(target)
  result.add ",\"key\":"
  result.add refJsonEscape(key)
  result.add ",\"value\":"
  if value == nil:
    result.add "null"
  else:
    result.add $value
  result.add ",\"scope\":"
  result.add refJsonEscape(scopeStr)
  result.add "}"

suite "RS-M13: select-story / apply-mutation body codec":

  test "select-story body matches render-serve byte-for-byte":
    let body = encodeSelectStoryBody(
      storyGroup = "Task App / Pages",
      storyName = "Inbox",
      storyKind = "skPage",
      storyId = "Task App / Pages / Inbox")
    let expected = refSelectStoryBody(
      "Task App / Pages", "Inbox", "skPage", "Task App / Pages / Inbox")
    check body == expected

  test "select-story body with properties JSON":
    let props = %*{"filter": "active"}
    let body = encodeSelectStoryBody(
      storyGroup = "g", storyName = "n", storyKind = "skComponent",
      storyId = "g / n", properties = props)
    let expected = refSelectStoryBody("g", "n", "skComponent", "g / n",
                                       properties = props)
    check body == expected
    check body.contains(",\"properties\":{\"filter\":\"active\"}")

  test "apply-mutation body — bool value, local scope":
    let v = newJBool(true)
    let body = encodeApplyMutationBody(
      target = "task_app/views/TaskRow#3",
      key = "completed",
      value = v,
      scope = tmsLocal)
    let expected = refApplyMutationBody(
      "task_app/views/TaskRow#3", "completed", v, "local")
    check body == expected

  test "apply-mutation body — string value, shared scope":
    let v = newJString("solarized")
    let body = encodeApplyMutationBody(
      target = "settings_app/views/Toggle#Theme",
      key = "theme",
      value = v,
      scope = tmsShared)
    let expected = refApplyMutationBody(
      "settings_app/views/Toggle#Theme", "theme", v, "shared")
    check body == expected

  test "select-story decode round-trip":
    let body = encodeSelectStoryBody(
      storyGroup = "Task App / Pages",
      storyName = "Inbox",
      storyKind = "skPage",
      storyId = "Task App / Pages / Inbox")
    let ev = decodeTuiStoryEvent(body)
    check ev.kind == tsekSelectStory
    check ev.storyGroup == "Task App / Pages"
    check ev.storyName == "Inbox"
    check ev.storyKind == "skPage"
    check ev.storyId == "Task App / Pages / Inbox"
    check ev.properties == nil

  test "apply-mutation decode round-trip":
    let v = newJBool(true)
    let body = encodeApplyMutationBody(
      target = "task_app/views/TaskRow#3",
      key = "completed",
      value = v,
      scope = tmsLocal)
    let ev = decodeTuiStoryEvent(body)
    check ev.kind == tsekApplyMutation
    check ev.mutationTarget == "task_app/views/TaskRow#3"
    check ev.mutationKey == "completed"
    check ev.mutationValue.kind == JBool
    check ev.mutationValue.getBool == true
    check ev.mutationScope == tmsLocal

  test "P packet framing carries the JSON body intact":
    let body = encodeSelectStoryBody(
      storyGroup = "g", storyName = "n", storyKind = "skPage",
      storyId = "g / n")
    let pkt = encodePacket(PacketTypeInput, body)
    var parser = initPacketParser()
    parser.feedString(pkt)
    check parser.pendingPackets() == 1
    let (ok, kind, payload) = parser.pop()
    check ok
    check kind == PacketTypeInput
    check payload == body
    # And the body decodes back to the original event.
    let ev = decodeTuiStoryEvent(payload)
    check ev.kind == tsekSelectStory
    check ev.storyId == "g / n"

  # RS-M13 fix-cycle 1: edge-case parity. The original suite used
  # inputs with no escapable characters, so the simpler hand-rolled
  # reference encoder accidentally produced the same bytes as
  # ``encodeSelectStoryBody``. The tests below force every escape
  # path in the spec'd ``jsonEscape`` (\\, \", \n, \r, \t, low
  # control char) plus a multi-byte UTF-8 input so any future
  # divergence between the tui-serve and render-serve encoders
  # surfaces here.

  test "select-story body matches reference under heavy escape input":
    # Inputs cover every spec'd escape path: backslash, double-
    # quote, newline (\n), carriage-return (\r), tab (\t), plus a
    # low control character (0x01) that takes the long ``\u00XX``
    # form.
    let storyIdInput = "id\nwith\rcontrols\x01"
    let body = encodeSelectStoryBody(
      storyGroup = "Task App / Pages \"alpha\"",
      storyName = "Inbox\\nested",
      storyKind = "sk\tComponent",
      storyId = storyIdInput)
    let expected = refSelectStoryBody(
      "Task App / Pages \"alpha\"",
      "Inbox\\nested",
      "sk\tComponent",
      storyIdInput)
    check body == expected
    # Every escape sequence must surface in the produced bytes; the
    # legacy hand-rolled reference (which just concatenated the raw
    # string into the JSON literal) would NOT have produced these
    # — that is the exact silent-drift the fix-cycle 1 finding
    # called out.
    check body.contains("\\\"alpha\\\"")
    check body.contains("Inbox\\\\nested")
    check body.contains("sk\\tComponent")
    check body.contains("id\\nwith\\rcontrols\\u0001")

  test "select-story body matches reference with multi-byte UTF-8":
    let body = encodeSelectStoryBody(
      storyGroup = "demo",
      storyName = "target-\xF0\x9F\x8E\xAF",
      storyKind = "skPage",
      storyId = "demo / target-\xF0\x9F\x8E\xAF")
    let expected = refSelectStoryBody(
      "demo", "target-\xF0\x9F\x8E\xAF", "skPage",
      "demo / target-\xF0\x9F\x8E\xAF")
    check body == expected
    # Multi-byte UTF-8 passes through verbatim (the encoder is
    # ASCII-aware but does not re-encode high bytes — they round-
    # trip as-is). 0xF0 0x9F 0x8E 0xAF is the UTF-8 encoding of
    # U+1F3AF DIRECT HIT (the target emoji).
    check body.contains("target-\xF0\x9F\x8E\xAF")

  test "apply-mutation body matches reference under escape inputs":
    let v = newJString("line1\nline2\t\"quoted\"")
    let body = encodeApplyMutationBody(
      target = "app/views/Widget#a\"b\\c",
      key = "label\nwith\tcontrols",
      value = v,
      scope = tmsLocal)
    let expected = refApplyMutationBody(
      "app/views/Widget#a\"b\\c",
      "label\nwith\tcontrols",
      v,
      "local")
    check body == expected
    # The JsonNode value's serialisation goes through std/json so it
    # carries its own escape rules; what we own is the *outer*
    # frame's escape rules — assert they fired.
    check body.contains("Widget#a\\\"b\\\\c")
    check body.contains("label\\nwith\\tcontrols")
