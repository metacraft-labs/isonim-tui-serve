## RS-M13: story-dispatch helpers on the D/M/P transport.
##
## The render-serve transport (F/M/I) carries ``select-story`` /
## ``apply-mutation`` events as ``I`` packets whose JSON body is
## documented in
## ``isonim-render-serve/src/isonim_render_serve/event_dispatch.nim``.
## RS-M13 routes the *same* JSON bodies through ``P`` packets on the
## TUI transport. This module:
##
##   * Defines ``TuiStoryEvent``, a value-typed variant that holds a
##     decoded ``select-story`` or ``apply-mutation`` payload.
##   * Provides ``encodeSelectStoryBody`` / ``encodeApplyMutationBody``
##     — byte-for-byte identical encoders to the render-serve repo's
##     ``encodeSelectStoryJson`` / ``encodeApplyMutationJson``. The
##     round-trip test pins this equality so the editor's JS sender
##     code (which emits I-bodies) can be re-used verbatim for P
##     bodies on the TUI transport.
##   * Provides ``decodeTuiStoryEvent`` for the launcher side.
##   * Provides ``TuiStoryDispatchSink`` — a thin StoryDispatchSink
##     analogue: the launcher's input loop reads P packets, parses
##     the JSON body, and routes ``select-story`` to ``mountFn`` and
##     ``apply-mutation`` to ``applyFn``.
##
## No transport-level changes: D/M/P framing is unchanged from RS-M0
## (the framing the isonim-tui packet driver speaks). The JSON layer
## inside the P body is what mirrors RS-M12.

import std/json

import ./packet

type
  TuiMutationScope* = enum
    tmsLocal = "local"
    tmsShared = "shared"

  TuiStoryEventKind* = enum
    tsekSelectStory, tsekApplyMutation

  TuiStoryEvent* = object
    case kind*: TuiStoryEventKind
    of tsekSelectStory:
      storyGroup*: string
      storyName*: string
      storyKind*: string
      storyId*: string
      properties*: JsonNode
    of tsekApplyMutation:
      mutationTarget*: string
      mutationKey*: string
      mutationValue*: JsonNode
      mutationScope*: TuiMutationScope

# ---------------------------------------------------------------------------
# Encoders — byte-for-byte identical to render-serve's I-body encoders.
# ---------------------------------------------------------------------------

proc storyJsonEscape(s: string): string =
  ## Mirrors ``isonim-render-serve``'s ``jsonEscape`` (and the editor's
  ## ``jsonEscapeString``) so the produced bytes line up. ASCII-only;
  ## RFC 8259 conformance for the characters the editor actually emits.
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

proc encodeSelectStoryBody*(storyGroup, storyName, storyKind,
                            storyId: string;
                            properties: JsonNode = nil): string =
  ## Hand-rolled deterministic encoder. Field order locked to
  ## ``type, group, name, kind, storyId, properties?`` so the on-wire
  ## bytes are reproducible AND byte-equal to the equivalent
  ## render-serve encoder.
  result = newStringOfCap(96 + storyId.len + storyGroup.len +
                          storyName.len + storyKind.len)
  result.add "{\"type\":\"select-story\""
  result.add ",\"group\":"
  result.add storyJsonEscape(storyGroup)
  result.add ",\"name\":"
  result.add storyJsonEscape(storyName)
  result.add ",\"kind\":"
  result.add storyJsonEscape(storyKind)
  result.add ",\"storyId\":"
  result.add storyJsonEscape(storyId)
  if properties != nil:
    result.add ",\"properties\":"
    result.add $properties
  result.add "}"

proc encodeApplyMutationBody*(target, key: string; value: JsonNode;
                              scope: TuiMutationScope): string =
  ## Hand-rolled deterministic encoder. Field order locked to
  ## ``type, target, key, value, scope`` — byte-equal to
  ## render-serve's ``encodeApplyMutationJson``.
  result = newStringOfCap(96 + target.len + key.len)
  result.add "{\"type\":\"apply-mutation\""
  result.add ",\"target\":"
  result.add storyJsonEscape(target)
  result.add ",\"key\":"
  result.add storyJsonEscape(key)
  result.add ",\"value\":"
  if value == nil:
    result.add "null"
  else:
    result.add $value
  result.add ",\"scope\":"
  result.add storyJsonEscape($scope)
  result.add "}"

# ---------------------------------------------------------------------------
# Decoder.
# ---------------------------------------------------------------------------

proc decodeTuiStoryEvent*(body: string): TuiStoryEvent =
  ## Parse a P-packet JSON body into the typed variant. Raises
  ## ``TuiPacketProtocolError`` on schema violation.
  var node: JsonNode
  try:
    node = parseJson(body)
  except JsonParsingError as e:
    raise newException(TuiPacketProtocolError,
      "P JSON parse error: " & e.msg)
  if node.kind != JObject:
    raise newException(TuiPacketProtocolError,
      "P JSON root must be an object")
  if "type" notin node or node["type"].kind != JString:
    raise newException(TuiPacketProtocolError,
      "P JSON missing string field 'type'")
  let kind = node["type"].getStr
  case kind
  of "select-story":
    template strField(name: string): string =
      if name notin node or node[name].kind != JString:
        raise newException(TuiPacketProtocolError,
          "select-story: missing string field '" & name & "'")
      node[name].getStr
    let props =
      if "properties" in node and node["properties"].kind != JNull:
        node["properties"]
      else:
        nil
    result = TuiStoryEvent(kind: tsekSelectStory,
      storyGroup: strField("group"),
      storyName: strField("name"),
      storyKind: strField("kind"),
      storyId: strField("storyId"),
      properties: props)
  of "apply-mutation":
    template strField(name: string): string =
      if name notin node or node[name].kind != JString:
        raise newException(TuiPacketProtocolError,
          "apply-mutation: missing string field '" & name & "'")
      node[name].getStr
    if "value" notin node:
      raise newException(TuiPacketProtocolError,
        "apply-mutation: missing 'value'")
    let scopeStr = strField("scope")
    let scope =
      case scopeStr
      of "local": tmsLocal
      of "shared": tmsShared
      else:
        raise newException(TuiPacketProtocolError,
          "apply-mutation: unknown scope '" & scopeStr & "'")
    result = TuiStoryEvent(kind: tsekApplyMutation,
      mutationTarget: strField("target"),
      mutationKey: strField("key"),
      mutationValue: node["value"],
      mutationScope: scope)
  else:
    raise newException(TuiPacketProtocolError,
      "unknown P JSON type: " & kind)

# ---------------------------------------------------------------------------
# In-process dispatch sink.
# ---------------------------------------------------------------------------

type
  TuiStoryMountFn* = proc(storyId: string; properties: JsonNode)
                         {.closure, gcsafe.}
  TuiApplyMutationFn* = proc(target, key: string; value: JsonNode;
                             scope: TuiMutationScope)
                            {.closure, gcsafe.}

  TuiStoryDispatchSink* = ref object
    ## Routes decoded ``TuiStoryEvent`` values to launcher callbacks.
    ## Mirrors ``isonim-render-serve``'s ``StoryDispatchSink`` (which
    ## decorates an inner ``AnyInputSink``) but, because the TUI
    ## transport doesn't have a generic "input sink" surface (P
    ## packets are EITHER select-story OR apply-mutation today —
    ## resize / key / mouse routing is a future RS-M13.x), we keep
    ## the API focused on those two callbacks and let the launcher
    ## handle resize via its own argv. Unknown P bodies surface as
    ## a ``TuiPacketProtocolError`` to the caller.
    mountFn*: TuiStoryMountFn
    applyFn*: TuiApplyMutationFn
    currentStoryId*: string

proc newTuiStoryDispatchSink*(mountFn: TuiStoryMountFn;
                              applyFn: TuiApplyMutationFn):
                              TuiStoryDispatchSink =
  TuiStoryDispatchSink(mountFn: mountFn, applyFn: applyFn,
                       currentStoryId: "")

proc submit*(sink: TuiStoryDispatchSink; event: TuiStoryEvent) =
  case event.kind
  of tsekSelectStory:
    sink.currentStoryId = event.storyId
    if sink.mountFn != nil:
      sink.mountFn(event.storyId, event.properties)
  of tsekApplyMutation:
    if sink.applyFn != nil:
      sink.applyFn(event.mutationTarget, event.mutationKey,
                   event.mutationValue, event.mutationScope)
