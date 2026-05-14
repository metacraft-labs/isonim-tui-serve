## test_serve_element_tree_roundtrip — RS-M13 element-tree codec.
##
## Asserts the hand-rolled JSON serializer in
## ``isonim_tui_serve/packet.nim`` produces byte-for-byte the locked
## wire shape, and that decoding the bytes round-trips back to the
## same manifest. Also asserts the ``boundsUnit: "cells"`` tag is
## present (the RS-M13 addition vs. the RS-M11 schema).

import std/[strutils, unittest]
import isonim_tui_serve

suite "RS-M13: element-tree body codec":

  test "encodeElementTreeBody emits the locked byte shape":
    let manifest = TuiElementTreeManifest(
      frameSeq: 7,
      surfaceCols: 80,
      surfaceRows: 24,
      elements: @[
        TuiElementEntry(
          id: "task_app/views/TaskRow#1",
          componentPath: "task_app/views/TaskRow#1",
          kind: "row",
          bounds: TuiElementBounds(x: 2, y: 5, w: 76, h: 1)),
        TuiElementEntry(
          id: "task_app/views/FilterBar",
          componentPath: "task_app/views/FilterBar",
          kind: "bar",
          bounds: TuiElementBounds(x: 0, y: 22, w: 80, h: 1))])

    let body = encodeElementTreeBody(manifest)
    const Expected =
      "{\"type\":\"element-tree\"" &
      ",\"boundsUnit\":\"cells\"" &
      ",\"frameSeq\":7" &
      ",\"surfaceCols\":80" &
      ",\"surfaceRows\":24" &
      ",\"elements\":[" &
        "{\"id\":\"task_app/views/TaskRow#1\"" &
        ",\"componentPath\":\"task_app/views/TaskRow#1\"" &
        ",\"kind\":\"row\"" &
        ",\"bounds\":{\"x\":2,\"y\":5,\"w\":76,\"h\":1}}," &
        "{\"id\":\"task_app/views/FilterBar\"" &
        ",\"componentPath\":\"task_app/views/FilterBar\"" &
        ",\"kind\":\"bar\"" &
        ",\"bounds\":{\"x\":0,\"y\":22,\"w\":80,\"h\":1}}" &
      "]}"
    check body == Expected

  test "decodeElementTreeBody round-trips":
    let manifest = TuiElementTreeManifest(
      frameSeq: 3,
      surfaceCols: 100,
      surfaceRows: 30,
      elements: @[
        TuiElementEntry(
          id: "a", componentPath: "demo/A", kind: "tile",
          bounds: TuiElementBounds(x: 0, y: 0, w: 10, h: 2)),
        TuiElementEntry(
          id: "b", componentPath: "demo/B", kind: "row",
          bounds: TuiElementBounds(x: 10, y: 0, w: 90, h: 2))])
    let body = encodeElementTreeBody(manifest)
    check isElementTreeBody(body)
    let decoded = decodeElementTreeBody(body)
    check decoded.frameSeq == manifest.frameSeq
    check decoded.surfaceCols == manifest.surfaceCols
    check decoded.surfaceRows == manifest.surfaceRows
    check decoded.elements.len == manifest.elements.len
    for i in 0 ..< manifest.elements.len:
      check decoded.elements[i].id == manifest.elements[i].id
      check decoded.elements[i].componentPath ==
            manifest.elements[i].componentPath
      check decoded.elements[i].kind == manifest.elements[i].kind
      check decoded.elements[i].bounds.x == manifest.elements[i].bounds.x
      check decoded.elements[i].bounds.y == manifest.elements[i].bounds.y
      check decoded.elements[i].bounds.w == manifest.elements[i].bounds.w
      check decoded.elements[i].bounds.h == manifest.elements[i].bounds.h

  test "decode rejects missing boundsUnit tag":
    const Body =
      "{\"type\":\"element-tree\"" &
      ",\"frameSeq\":1,\"surfaceCols\":80,\"surfaceRows\":24" &
      ",\"elements\":[]}"
    expect TuiPacketProtocolError:
      discard decodeElementTreeBody(Body)

  test "decode rejects wrong boundsUnit value":
    const Body =
      "{\"type\":\"element-tree\"" &
      ",\"boundsUnit\":\"pixels\"" &
      ",\"frameSeq\":1,\"surfaceCols\":80,\"surfaceRows\":24" &
      ",\"elements\":[]}"
    expect TuiPacketProtocolError:
      discard decodeElementTreeBody(Body)

  test "manifestKey is stable across calls":
    let manifest = TuiElementTreeManifest(
      frameSeq: 1,
      surfaceCols: 80,
      surfaceRows: 24,
      elements: @[
        TuiElementEntry(
          id: "a", componentPath: "demo/A", kind: "row",
          bounds: TuiElementBounds(x: 1, y: 2, w: 3, h: 4))])
    let key1 = manifestKey(manifest)
    let key2 = manifestKey(manifest)
    check key1 == key2
    check key1.contains("80x24")
    check key1.contains("a:1,2,3,4")
