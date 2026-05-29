## Context

The current repository must be refactored into a Windows automation wrapper for Andrej Karpathy's upstream `autoresearch` project. The wrapper owns installation, scheduling, runtime governance, diagnostics, and local integration. The upstream clone owns the actual autoresearch application code.

The target runtime is Windows 10/11 with PowerShell 5.1 or later, Git, npm, and per-user filesystem access. The solution must avoid global system changes except the named scheduled task, Start Menu shortcut, install directories, configuration, state, and logs. The `ai-powered` npm package is the only allowed AI interface.

## Goals / Non-Goals

**Goals:**
- Run autoresearch only through an idle-triggered Windows Scheduled Task or explicit user launcher invocation.
- Self-install the wrapper into `%LOCALAPPDATA%\Programs\myTech.Today\autoresearch-karpathy` and manage the upstream clone at `%LOCALAPPDATA%\Programs\myTech.Today\autoresearch`.
- Keep every operation idempotent across repeated launches, updates, removals, shortcut creation, and task registration.
- Enforce a default 5 minute per-run limit and a default 5 minute rolling-hour runtime budget.
- Provide structured JSON Lines diagnostics when `-Debug` is active.
- Remove Augment Code AI and all other external AI service integrations in favor of `ai-powered`.

**Non-Goals:**
- Supporting non-Windows operating systems.
- Replacing the upstream autoresearch algorithm or research workflow beyond dependency and launch integration.
- Installing machine-wide services, global npm packages, or system-wide configuration.
- Automatically deleting user data from directories that are not verified as managed install roots.

## Decisions

### Per-user install root

Use `%LOCALAPPDATA%\Programs\myTech.Today` as the program base. This avoids administrative installs, supports spaces in paths, and keeps wrapper and upstream code isolated from the original checkout.

Alternative considered: run directly from the checkout. Rejected because scheduled task actions would depend on a mutable development path and could break when the checkout is moved.

### Single self-contained PowerShell launcher

Implement install, scheduled task management, shortcut creation, dependency checks, runtime limits, update, removal, version, and debug logging in `scripts/launch.ps1`. Helper functions may be used inside the script, but the launcher must remain self-contained for deployment.

Alternative considered: split logic across multiple scripts. Rejected because scheduled task and raw URL bootstrap workflows need one dependable entry point.

### Task Scheduler as the idle gate

Configure Task Scheduler idle settings for standard Windows idle detection, then have the launcher validate budget and process state before running. This keeps idle detection in Windows while making runtime limits testable and auditable in the wrapper.

Alternative considered: polling idle state from PowerShell only. Rejected because it duplicates platform scheduling behavior and risks running outside user expectations.

### Runtime history as local JSON state

Persist invocation history in `%LOCALAPPDATA%\myTech.Today\autoresearch-karpathy\state.json` and prune entries outside the rolling hour. This makes the per-hour budget durable across scheduled task invocations and user sessions.

Alternative considered: storing budget state only in memory. Rejected because scheduled task invocations are separate processes.

### JSON Lines logging for debug mode

Write one valid JSON object per line to `%HOMEDRIVE%\myTech.Today\logs\autoresearch-karpathy.jsonl` when `-Debug` is active. This supports append-only diagnostics without requiring a database.

Alternative considered: free-form text logs. Rejected because structured fields are required for filtering and reliable troubleshooting.

## Risks / Trade-offs

- [Risk] Creating scheduled tasks can require elevation on some Windows configurations. Mitigation: detect privilege failures, provide actionable messages, and request elevation only when needed.
- [Risk] Existing directories can contain unrelated user data. Mitigation: validate Git remotes and managed paths before updating or removing; never overwrite unknown data without confirmation.
- [Risk] Git or npm may be absent or misconfigured. Mitigation: preflight dependencies, log failures, and exit without partial destructive actions.
- [Risk] Forced process termination can lose upstream work. Mitigation: attempt graceful shutdown first, record the reason, and use force only after a timeout.
- [Risk] Dependency changes can reintroduce non-approved AI providers. Mitigation: make `ai-powered` the only AI package and add tests that search package manifests and source files for disallowed providers.

## Migration Plan

1. Add or replace AI integration code so all AI calls flow through `ai-powered`.
2. Add `scripts/launch.ps1` with install, scheduling, runtime, logging, update, remove, version, and shortcut functions.
3. Update package metadata to depend on `ai-powered` and remove disallowed AI provider dependencies.
4. Add acceptance tests and static checks for provider exclusivity, idempotency, scheduled task configuration, and PowerShell behavior.
5. Validate from a clean checkout, from the installed wrapper path, and through repeated invocations.

Rollback consists of removing the scheduled task and shortcut, stopping running upstream processes, and restoring repository files from version control. Managed install directories are removed only after explicit user confirmation.

## Open Questions

- What exact command starts the upstream autoresearch application after dependencies are installed?
- Should the wrapper pin a specific `ai-powered` version or accept the package version from `package-lock.json`?
- Should the scheduled task run with highest privileges by default, or only retry with elevation if creation fails?