import { defineConfig, devices } from '@playwright/test';

/**
 * Playwright config for isonim-tui-serve.
 *
 * The test under tests/e2e/browser_e2e.spec.ts spawns its own
 * isonim-tui-serve subprocess on an ephemeral port — we deliberately
 * do NOT use Playwright's `webServer` option here because the bridge
 * needs to be torn down per-test (it owns one child app process per
 * WebSocket connection and we want a fresh fixture each run).
 *
 * baseURL is intentionally omitted; the spec computes its own URL
 * from the ephemeral port chosen at startup.
 */
export default defineConfig({
  testDir: '.',
  testMatch: /.*\.spec\.ts$/,
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: 0,
  workers: 1,
  reporter: [
    ['list'],
    ['html', { outputFolder: 'playwright-report', open: 'never' }],
  ],
  timeout: 60_000,
  expect: {
    timeout: 15_000,
  },
  use: {
    headless: true,
    trace: 'retain-on-failure',
    video: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: {
        ...devices['Desktop Chrome'],
        // Allow overriding the Chromium binary so the suite works on
        // NixOS (where Playwright's bundled Chrome refuses to start
        // due to glibc/loader assumptions). Set
        // PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=$(which chromium) when
        // running on Nix; CI uses Playwright's bundled binary on
        // ubuntu-latest where it works out of the box.
        launchOptions: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH
          ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH }
          : {},
      },
    },
  ],
});
