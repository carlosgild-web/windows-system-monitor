import { defineConfig } from '@playwright/test'

/**
 * The README screenshots and GIF (docs/showcase/). Windows only: the tests start the real monitors
 * from a clean scratch copy (start_monitoring.bat video) with a scripted model, then drive the
 * console. Dev-only: not part of the runtime, the Docker image or CI.
 */
export default defineConfig({
  testDir: './tests',
  timeout: 240_000,
  expect: { timeout: 60_000 },
  fullyParallel: false,
  workers: 1,
  reporter: 'list',
  globalSetup: './setup.ts',
  globalTeardown: './teardown.ts',
  use: { baseURL: 'http://localhost:5758', locale: 'en-US', colorScheme: 'light' },
})
