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
(`test_serve_browser_e2e`, in `tests/e2e/browser_e2e.spec.ts`) now
ships alongside the Nim integration test. It spawns a real
`isonim-tui-serve` subprocess hosting the `echo_packet_app`
fixture, opens a real Chromium tab against the reference frontend
in `static/index.html`, types a keystroke into the rendered xterm.js
terminal, and asserts the fixture's `D` echo packet appears both on
the WebSocket wire and in the rendered terminal buffer. The Nim-side
bridge keeps its own integration test
(`tests/test_serve_packet_bridge.nim`) that runs the server,
connects with a hand-rolled WebSocket client, and asserts byte
parity without booting a browser.

## Commands

```sh
just build           # compile every test as a smoke check
just test            # run the integration suite (Nim only)
just test-e2e        # run the Playwright browser suite (separate target)
just lint            # nim check + nixfmt --check
just format          # nimpretty + nixfmt
```

### Running the Playwright e2e suite locally

The browser test lives under `tests/e2e/`. It needs Node 20+ and a
working Chromium. One-time bootstrap:

```sh
cd tests/e2e
npm install
npx playwright install chromium    # ~280 MiB into ~/.cache/ms-playwright
```

Then:

```sh
just test-e2e
# or, from tests/e2e/: npx playwright test
```

On NixOS the bundled Chromium can't run as a generic dynamically
linked binary; export `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH` to point
at a Nix-built Chromium instead:

```sh
nix shell nixpkgs#chromium nixpkgs#nodejs_20 -- \
  bash -c 'PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=$(which chromium) just test-e2e'
```

The CI job (`playwright-e2e` in `.github/workflows/ci.yml`) runs on
`ubuntu-latest` where Playwright's bundled binary works directly via
`npx playwright install --with-deps chromium`.

## Project structure

```text
src/
  isonim_tui_serve.nim                # public top-level — async server + handlers
  isonim_tui_serve/packet.nim         # packet (D/M/P) framing
  isonim_tui_serve/wsframe.nim        # RFC 6455 frame codec
tests/
  test_serve_packet_bridge.nim        # spawn server, websocket client, real subprocess
  test_serve_packet_framing.nim       # codec round-trip (no I/O)
  test_serve_wsframe_round_trip.nim   # ws codec round-trip (no I/O)
  e2e/                                # Playwright browser e2e suite
    package.json
    playwright.config.ts
    browser_e2e.spec.ts               # real Chromium against bridge + xterm.js
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
