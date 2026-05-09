## Justfile - isonim-tui-serve.

alias t := test
alias fmt := format

src-paths := "--path:src --path:tests"
nim-flags := "--styleCheck:usages --styleCheck:error"

tests := "tests/test_serve_packet_framing.nim tests/test_serve_wsframe_round_trip.nim tests/test_serve_packet_bridge.nim"

build:
    @mkdir -p test-logs
    nim c {{nim-flags}} {{src-paths}} --mm:orc -d:release --threads:on \
        -o:test-logs/isonim_tui_serve src/isonim_tui_serve.nim 2>&1 | tee test-logs/build.log
    @for t in {{tests}}; do \
      echo "Building $t"; \
      nim c {{nim-flags}} {{src-paths}} --mm:orc -d:release --threads:on \
          -o:test-logs/$(basename $t .nim) $t 2>&1 | tee -a test-logs/build.log; \
    done

test: test-orc

test-unit:
    @mkdir -p test-logs
    @for t in tests/test_serve_packet_framing.nim tests/test_serve_wsframe_round_trip.nim; do \
      echo "[unit] $t"; \
      nim c {{nim-flags}} {{src-paths}} --mm:orc -d:release --threads:on \
          -r $t 2>&1 | tee -a test-logs/test-unit.log; \
    done

test-integration:
    @mkdir -p test-logs
    @for t in tests/test_serve_packet_bridge.nim; do \
      echo "[integration] $t"; \
      nim c {{nim-flags}} {{src-paths}} --mm:orc -d:release --threads:on \
          -r $t 2>&1 | tee -a test-logs/test-integration.log; \
    done

test-orc:
    just _matrix orc release on
    just _matrix orc debug on

test-arc:
    just _matrix arc release on

test-refc:
    just _matrix refc release on

test-threads-off:
    just _matrix orc release off

test-all: test-orc test-arc test-refc test-threads-off

# Run the Playwright browser e2e suite. Requires Node + Chromium —
# bootstrap with `cd tests/e2e && npm install && npx playwright install chromium`.
# Builds the bridge and fixture binaries first so the suite can spawn them.
test-e2e: build
    cd tests/e2e && npx playwright test

_matrix mm mode threads:
    @mkdir -p test-logs
    @for t in {{tests}}; do \
      echo "[{{mm}}/{{mode}}/threads:{{threads}}] $t"; \
      nim c {{nim-flags}} {{src-paths}} \
        --mm:{{mm}} -d:{{mode}} --threads:{{threads}} \
        -r $t 2>&1 | tee -a test-logs/{{mm}}-{{mode}}-threads-{{threads}}.log; \
    done

lint: lint-nim lint-nix lint-markdown

lint-nim:
    @mkdir -p test-logs
    nim check {{nim-flags}} {{src-paths}} --mm:orc src/isonim_tui_serve.nim 2>&1 | tee test-logs/lint-nim.log
    @for t in {{tests}}; do \
      echo "Checking $t"; \
      nim check {{nim-flags}} {{src-paths}} --mm:orc --threads:on $t 2>&1 | tee -a test-logs/lint-nim.log; \
    done

lint-nix:
    nixfmt --check flake.nix

lint-markdown:
    @if command -v markdownlint-cli2 >/dev/null 2>&1; then \
      markdownlint-cli2 "**/*.md" "#**/node_modules/**" "#test-logs/**" "#tests/e2e/playwright-report/**" || true; \
    else \
      echo "markdownlint-cli2 not available; skipping"; \
    fi

format: format-nim format-nix

format-nim:
    @if command -v nimpretty >/dev/null 2>&1; then \
      nimpretty src/isonim_tui_serve.nim src/isonim_tui_serve/*.nim tests/*.nim; \
    else \
      echo "nimpretty not available; skipping Nim formatting"; \
    fi

format-nix:
    nixfmt flake.nix

bump-version version:
    sed -i 's/^version[[:space:]]*=.*/version       = "{{version}}"/' isonim_tui_serve.nimble

bench *FLAGS:
    @echo "isonim-tui-serve has no benchmark suite yet — bridge throughput will land in a follow-up milestone."

bench-quick:
    just bench --quick

clean:
    rm -rf test-logs nim-cache
