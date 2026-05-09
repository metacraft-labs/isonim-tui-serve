# isonim-tui-serve

WebSocket bridge for the M26 *packet driver* in
[isonim-tui](../isonim-tui). Hosts a TUI app process and forwards
its `D`/`M`/`P` stdio packet stream to/from a browser tab running
[xterm.js](https://xtermjs.org/).

## What this library does

- Hand-rolled RFC 6455 WebSocket framing
  (`src/isonim_tui_serve/wsframe.nim`).
- Self-contained packet codec (`src/isonim_tui_serve/packet.nim`) —
  the same `D`/`M`/`P` 1-byte-type + 4-byte-BE-length wire shape
  that `isonim-tui/drivers/web_driver.nim` speaks.
- One-process bridge: launch a hosted app, pipe each WebSocket
  binary frame's payload (one full packet) into the child's stdin,
  pump the child's stdout through the WebSocket back to the
  browser.
- Reference HTML/JS in `static/` that mounts xterm.js (CDN-hosted)
  and exchanges packets with the bridge.

## Status (M26)

This repo lands as part of *isonim-tui's* M26 milestone. The packet
driver itself (`isonim_tui/drivers/web_driver.nim`) is the
load-bearing change in the corresponding sibling repo; the bridge
here is the optional serve-as-browser path that completes the
milestone.

The Playwright e2e test against the live browser
(`test_serve_browser_e2e` in the milestone doc) is *deferred to a
future milestone* — it requires browser-automation infrastructure
that isn't in scope for M26's "real packet I/O" goal. The Nim-side
bridge has its own integration test
(`tests/test_serve_packet_bridge.nim`) that runs the server,
connects with a hand-rolled WebSocket client, exchanges packets
against a real subprocess, and asserts byte parity.

## Commands

```sh
just build           # compile every test as a smoke check
just test            # run the integration suite
just lint            # nim check + nixfmt --check
just format          # nimpretty + nixfmt
```

## Project structure

```
src/
  isonim_tui_serve.nim                # public top-level — async server + handlers
  isonim_tui_serve/packet.nim         # packet (D/M/P) framing
  isonim_tui_serve/wsframe.nim        # RFC 6455 frame codec
tests/
  test_serve_packet_bridge.nim        # spawn server, websocket client, real subprocess
  test_serve_packet_framing.nim       # codec round-trip (no I/O)
  test_serve_wsframe_round_trip.nim   # ws codec round-trip (no I/O)
static/
  index.html                          # xterm.js + websocket glue
.github/workflows/ci.yml              # lint + test
flake.nix                             # nix devShell
Justfile                              # build/test/lint/format
isonim_tui_serve.nimble               # single-source-of-truth version
```

## Running locally

```sh
# 1. Build the bridge.
nim c -d:release -o:isonim-tui-serve src/isonim_tui_serve.nim

# 2. Start the bridge against an isonim-tui app that uses WebDriver.
./isonim-tui-serve --port 8765 --static static --app "./my-app"

# 3. Open http://localhost:8765/ in a browser.
```

## Specs

The authoritative spec for this library is the M26 entry in
`Front-Ends/IsoNim/isonim-tui.milestones.org` in the
`codetracer-specs` repo. Repo-level conformance is governed by
`metacraft-specs/policies/repo-requirements.md`.
