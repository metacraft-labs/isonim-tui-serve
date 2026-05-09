# Package
version       = "0.1.0"
author        = "Metacraft Labs"
description   = "WebSocket bridge for isonim-tui's M26 packet driver — host a TUI app and stream its D/M/P packets to a browser-side xterm.js"
license       = "MIT"
srcDir        = "src"
bin           = @["isonim_tui_serve"]

# Dependencies
requires "nim >= 2.0.0"
