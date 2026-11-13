# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions match
`_meta.version` in `monitoring_settings.json`.

## [Unreleased]

### Changed
- The four alert actions live once in `scripts/lib/MonitorActions.ps1` instead of being copied into each monitor.
  Side effects: template values containing `$` are inserted literally, the email recipient is escaped in every
  monitor, and rotated logs are always named `monitor.<timestamp>.log`.

## [1.5.0] - 2026-11-13

First public release.

### Added
- Five independent monitors (process, CPU/RAM, disk, network, spreadsheet metric), all driven by
  `monitoring_settings.json`.
- Escalating actions (`log_to_file`, `popup`, `email_draft`, `run_script`) with a per-incident spam guard.
- Live web console (`:5758`) and settings editor (`:5757`), both Python standard library only.
- `doctor.bat` health check (environment, config schema, paths, runtime), and a preflight in the launcher that
  blocks a broken config before any monitor is restarted.
- Sample `run_script` remediation handlers in `scripts/actions/`.
- Made-up sample workbook for the ebook sales monitor.
- Pester and Python test suites; CI on Windows PowerShell 5.1 with PSScriptAnalyzer.

### Fixed
- The editor and console APIs reject cross-origin and DNS-rebinding requests; `/api/open-file` only opens
  spreadsheets inside the project folder.
- `popup` actions work in the performance, disk and network monitors (they were silently ignored).
- Stopping the monitors no longer leaves orphaned hidden Excel processes.
- The stop script's exit wait now runs (`$PID` loop-variable bug).
- Settings are always read as UTF-8; a settings file saved with a BOM no longer blanks the console.
- Config paths are relative to the project folder, so the repo runs from any location.
- `{latency_ms}` in network templates refers to the threshold, consistent with the other monitors.

[Unreleased]: https://github.com/carlosgild-web/windows-system-monitor/compare/v1.5.0...HEAD
[1.5.0]: https://github.com/carlosgild-web/windows-system-monitor/releases/tag/v1.5.0
