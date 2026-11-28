import { defineConfig } from '@playwright/test'

/**
 * The recorder starts the real monitors from a clean scratch copy (video mode) inside each take
 * and stops them at the end. The page is the 1920x1080 stage, which hosts the real console in an
 * iframe on the console's own origin (:5758).
 */
export default defineConfig({
  testDir: '.',
  testMatch: 'record.spec.ts',
  outputDir: 'out/test-results',
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 25 * 60_000,
  // A model turn on a CPU-only laptop takes tens of seconds.
  expect: { timeout: 120_000 },
  reporter: [['list']],
  use: {
    baseURL: 'http://localhost:5758',
    viewport: { width: 1920, height: 1080 },
    deviceScaleFactor: 1,
    colorScheme: 'light',
    locale: 'en-US',
    actionTimeout: 90_000,
  },
})
