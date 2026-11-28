import { join } from 'node:path'

import { COPY, powershell } from './env'

/** Stops the scratch copy's monitors, console and editor. */
export default async function teardown() {
  if (process.env.SHOWCASE_KEEP_RUNNING) return
  powershell(join(COPY, 'scripts', 'stop_monitoring.ps1'))
}
