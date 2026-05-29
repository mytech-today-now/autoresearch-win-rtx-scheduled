# Acceptance Test Plan

## Provider Exclusivity

- Verify `package.json` and the lockfile include `ai-powered`.
- Verify source and configuration contain no Augment Code AI client setup, non-approved AI SDK imports, or provider API key settings.
- Verify dependency installation restores `ai-powered` without installing disallowed provider packages.

## Self-Installation

- Run `scripts/launch.ps1 -Version` from a temporary checkout path and verify it copies the wrapper to `%LOCALAPPDATA%\Programs\myTech.Today\autoresearch-karpathy`.
- Verify the installed script is relaunched with the original switches.
- Verify excluded folders such as `.git`, `node_modules`, logs, caches, temp files, and build output are not copied unless explicitly required.
- Repeat the launch and verify no duplicate wrapper directories are created.

## Upstream Clone Management

- Run with no upstream clone and verify `https://github.com/karpathy/autoresearch` is cloned into `%LOCALAPPDATA%\Programs\myTech.Today\autoresearch`.
- Run with an existing valid clone and verify the remote is validated and updated safely.
- Run with an unrelated directory at the clone path and verify the launcher logs an error without overwriting user data.

## Scheduled Task and Shortcut

- Verify the `\myTech.Today\autoresearch-karpathy` scheduled task is created with the required author, description, idle trigger, action, and security settings.
- Modify one task property, rerun the launcher, and verify the existing task is updated rather than duplicated.
- Verify the Start Menu shortcut points to the installed launcher through `powershell.exe -NoProfile -ExecutionPolicy Bypass -File`.
- Repeat shortcut creation and verify no duplicate shortcuts appear.

## Runtime Limits and State

- Run with default settings and verify the per-run and rolling-hour limits are both 5 minutes.
- Run with valid `-MaxRuntimeMinutes` and `-MaxRuntimePerHourMinutes` values and verify they are applied.
- Run with zero, negative, non-numeric, and unreasonably large values and verify the launcher rejects them before starting upstream autoresearch.
- Populate state history to consume the rolling-hour budget and verify the next run is skipped.
- Verify completed, skipped, crashed, and force-terminated runs are recorded in `state.json`.

## Process Management

- Start a simulated upstream autoresearch process, run the launcher again, and verify the existing instance is gracefully stopped before restart.
- Simulate a process that ignores graceful shutdown and verify forced termination is logged.
- Simulate an early upstream crash and verify the launcher logs the failure and does not restart during the same trigger event.

## Update and Removal

- Run `-Update` and verify upstream pull, wrapper update when applicable, npm dependency installation, and smoke validation are attempted in order.
- Verify update preserves wrapper-only files, config, state, and logs.
- Run `-Remove` and verify task deletion, shortcut deletion, and process stop behavior.
- Repeat `-Remove` and verify it remains successful when resources are already absent.

## Debug and Version

- Run with `-Debug` and verify each log line in `%HOMEDRIVE%\myTech.Today\logs\autoresearch-karpathy.jsonl` is valid JSON with `timestamp`, `level`, `message`, `source`, and optional `detail`.
- Run with `-Version` and verify wrapper version, `ai-powered` version, and last update timestamp are printed without starting upstream autoresearch.