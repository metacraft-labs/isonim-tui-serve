/**
 * test_serve_browser_e2e — end-to-end browser test for the
 * isonim-tui-serve bridge.
 *
 * *Claim.* The reference HTML/JS in static/index.html, when loaded in
 * a real Chromium tab against a live isonim-tui-serve subprocess
 * that hosts the `echo_packet_app` fixture, can:
 *
 *   1. Mount xterm.js in the page.
 *   2. Open a binary WebSocket to the bridge.
 *   3. Type a keystroke into the terminal — onData fires, encodes a
 *      `P paste|<key>` packet, and ships it through the WebSocket.
 *   4. Receive the fixture's echoed `D` packet (`echo:paste|<key>`)
 *      and feed the payload bytes into term.write so the characters
 *      appear in the rendered terminal buffer.
 *
 * Real-stack: real Chromium, real WebSocket, real bridge process,
 * real subprocess fixture. No mocks anywhere.
 */
import { test, expect, type Page } from '@playwright/test';
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { createServer } from 'node:net';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';

const repoRoot = resolve(__dirname, '..', '..');
const serveBin = resolve(repoRoot, 'test-logs', 'isonim_tui_serve');
const fixtureBin = resolve(repoRoot, 'tests', 'echo_packet_app');
const staticDir = resolve(repoRoot, 'static');

function pickFreePort(): Promise<number> {
  return new Promise((resolveP, rejectP) => {
    const srv = createServer();
    srv.unref();
    srv.on('error', rejectP);
    srv.listen(0, '127.0.0.1', () => {
      const addr = srv.address();
      if (addr && typeof addr === 'object') {
        const port = addr.port;
        srv.close(() => resolveP(port));
      } else {
        rejectP(new Error('listen() returned non-object address'));
      }
    });
  });
}

function waitForHttp(port: number, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolveP, rejectP) => {
    const tick = () => {
      const sock = new (require('node:net').Socket)();
      const onErr = () => {
        sock.destroy();
        if (Date.now() > deadline) {
          rejectP(new Error(`server on :${port} did not come up in ${timeoutMs}ms`));
        } else {
          setTimeout(tick, 100);
        }
      };
      sock.once('error', onErr);
      sock.connect(port, '127.0.0.1', () => {
        sock.end();
        resolveP();
      });
    };
    tick();
  });
}

interface Bridge {
  port: number;
  proc: ChildProcessWithoutNullStreams;
  stderr: string;
}

async function startBridge(): Promise<Bridge> {
  if (!existsSync(serveBin)) {
    throw new Error(
      `bridge binary not found at ${serveBin}; run \`just build\` first to compile it`
    );
  }
  if (!existsSync(fixtureBin)) {
    throw new Error(
      `echo_packet_app fixture not found at ${fixtureBin}; run \`just build\` first to compile it`
    );
  }
  const port = await pickFreePort();
  const proc = spawn(
    serveBin,
    ['--port', String(port), '--static', staticDir, '--app', fixtureBin],
    { stdio: ['ignore', 'pipe', 'pipe'] }
  );
  const bridge: Bridge = { port, proc, stderr: '' };
  proc.stderr.on('data', (d: Buffer) => {
    bridge.stderr += d.toString('utf-8');
  });
  // Surface unexpected exits early.
  proc.on('exit', (code, sig) => {
    bridge.stderr += `\n[bridge exited code=${code} sig=${sig}]\n`;
  });
  await waitForHttp(port, 10_000);
  return bridge;
}

async function stopBridge(b: Bridge): Promise<void> {
  if (b.proc.exitCode === null && b.proc.signalCode === null) {
    b.proc.kill('SIGTERM');
    await new Promise<void>((r) => {
      const t = setTimeout(() => {
        try { b.proc.kill('SIGKILL'); } catch {} r();
      }, 2000);
      b.proc.on('exit', () => { clearTimeout(t); r(); });
    });
  }
}

async function readTerminalText(page: Page): Promise<string> {
  // xterm.js stores rendered cells in `term.buffer.active`. We expose
  // `term` on window in the test bootstrap (see fixturePage below).
  return await page.evaluate(() => {
    const t = (window as any).__ttyTerm;
    if (!t) return '';
    const buf = t.buffer.active;
    let out = '';
    for (let row = 0; row < buf.length; row++) {
      const line = buf.getLine(row);
      if (!line) continue;
      const s = line.translateToString(true);
      if (s.length > 0) out += s + '\n';
    }
    return out;
  });
}

test.describe('isonim-tui-serve: browser e2e', () => {
  let bridge: Bridge | null = null;

  test.beforeEach(async () => {
    bridge = await startBridge();
  });

  test.afterEach(async () => {
    if (bridge) {
      await stopBridge(bridge);
      bridge = null;
    }
  });

  test('test_serve_browser_e2e', async ({ page }) => {
    if (!bridge) throw new Error('bridge not started');
    const url = `http://127.0.0.1:${bridge.port}/`;

    // Capture browser console — failed CDN loads or websocket errors
    // here are the most common cause of false negatives.
    const consoleMsgs: string[] = [];
    page.on('console', (m) => consoleMsgs.push(`[${m.type()}] ${m.text()}`));
    page.on('pageerror', (e) => consoleMsgs.push(`[pageerror] ${e.message}`));

    await page.goto(url, { waitUntil: 'load' });

    // Wait for xterm.js to mount and the websocket to connect.
    await page.waitForFunction(
      () => {
        const s = document.getElementById('status');
        return !!s && s.textContent === 'connected';
      },
      undefined,
      { timeout: 20_000 }
    );

    // Expose the Terminal instance for buffer inspection. The page
    // script declares `term` as a `const` inside its IIFE; we walk
    // the rendered DOM to find the xterm container and ask for the
    // attached object via xterm's data attributes.
    //
    // Simpler path: re-read the variable through a small evaluate
    // that the page exports during connect. We patch by writing a
    // helper after navigation: hook into the Terminal by locating
    // it through xterm's well-known DOM artifacts.
    await page.evaluate(() => {
      // xterm.js mounts into div#terminal; the `Terminal` instance is
      // not directly exposed, but we can fish it out of the prototype
      // chain via the `xterm` element's parent reference. We instead
      // monkey-patch Terminal.prototype.write on the next message and
      // record the bytes from the wire. Easier and decoupled from
      // xterm's internals: install a passive WebSocket sniffer.
      const w = window as any;
      w.__rxBuffer = new Uint8Array(0);
      const origWS = window.WebSocket;
      // The page already opened its WebSocket at script time, so we
      // can't intercept it pre-construction. Instead, wrap the
      // existing one's `addEventListener` retroactively by patching
      // `MessageEvent` capture from this point forward.
      // We register a *second* listener on the live WebSocket — found
      // by walking globals isn't possible (it's lexically scoped),
      // so we open our OWN parallel WebSocket. The bridge spawns one
      // echo subprocess per connection, so this is independent.
      const ws2 = new origWS(
        (location.protocol === 'https:' ? 'wss://' : 'ws://') +
          location.host +
          '/'
      );
      ws2.binaryType = 'arraybuffer';
      w.__sniffWS = ws2;
      ws2.addEventListener('message', (e: MessageEvent) => {
        if (e.data instanceof ArrayBuffer) {
          const chunk = new Uint8Array(e.data);
          const next = new Uint8Array(w.__rxBuffer.length + chunk.length);
          next.set(w.__rxBuffer);
          next.set(chunk, w.__rxBuffer.length);
          w.__rxBuffer = next;
        }
      });
      // Send a known P-paste packet through the sniffer connection.
      ws2.addEventListener('open', () => {
        const enc = new TextEncoder();
        const payload = enc.encode('paste|hi');
        const buf = new Uint8Array(5 + payload.length);
        buf[0] = 'P'.charCodeAt(0);
        const n = payload.length;
        buf[1] = (n >>> 24) & 0xff;
        buf[2] = (n >>> 16) & 0xff;
        buf[3] = (n >>> 8) & 0xff;
        buf[4] = n & 0xff;
        buf.set(payload, 5);
        ws2.send(buf);
      });
    });

    // Wait until the sniffer has captured at least one full D packet
    // from its own dedicated bridge connection.
    const packet = await page.waitForFunction(
      () => {
        const w = window as any;
        const buf: Uint8Array = w.__rxBuffer;
        if (!buf || buf.length < 5) return null;
        const n =
          (buf[1] << 24) | (buf[2] << 16) | (buf[3] << 8) | buf[4];
        if (buf.length < 5 + n) return null;
        const kind = String.fromCharCode(buf[0]);
        const dec = new TextDecoder();
        const payload = dec.decode(buf.slice(5, 5 + n));
        return { kind, payload };
      },
      undefined,
      { timeout: 15_000 }
    );
    const got = await packet.jsonValue();

    // The fixture echoes `paste|hi` back as `echo:paste|hi` in a D
    // packet — that's the round-trip we care about.
    expect(got.kind).toBe('D');
    expect(got.payload).toBe('echo:paste|hi');

    // Now exercise the *primary* path: type into the xterm terminal
    // (which uses the page's original WebSocket). We focus the
    // terminal first, then dispatch keystrokes via Playwright.
    await page.click('#terminal');
    await page.keyboard.type('y');

    // Wait until the rendered terminal buffer contains the echoed
    // payload from the fixture's D-packet response. The page's
    // term.write feeds the raw payload bytes (including the `echo:`
    // prefix and `paste|` envelope) into the terminal as text.
    await expect
      .poll(
        async () => {
          return await page.evaluate(() => {
            // xterm doesn't expose the Terminal instance globally,
            // but each row is reachable via the DOM under
            // .xterm-rows > div. Render text via DOM scan.
            const rows = document.querySelectorAll('.xterm-rows > div');
            let s = '';
            rows.forEach((r) => { s += (r as HTMLElement).innerText + '\n'; });
            return s;
          });
        },
        {
          timeout: 15_000,
          message:
            'expected echoed `paste|y` payload to appear in the rendered terminal',
        }
      )
      .toContain('paste|y');

    if (consoleMsgs.length > 0) {
      console.log('browser console output:\n' + consoleMsgs.join('\n'));
    }
  });
});
