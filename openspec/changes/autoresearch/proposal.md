## Why

The repository needs a concrete specification for refactoring autoresearch into a Windows-only idle-time automation wrapper powered exclusively by the `ai-powered` npm package. This change removes reliance on Augment Code AI or any other external AI service APIs while making the runtime safe, idempotent, and suitable for unattended Scheduled Task execution.

## What Changes

- Add a Windows Scheduled Task based launcher named `autoresearch-karpathy` under the `\myTech.Today` task folder.
- Add per-user self-installation into `%LOCALAPPDATA%\Programs\myTech.Today\autoresearch-karpathy` and maintain an upstream clone at `%LOCALAPPDATA%\Programs\myTech.Today\autoresearch`.
- Add a robust `scripts/launch.ps1` workflow for install, launch, update, remove, version, debug logging, runtime budgeting, and process cycling.
- Add idempotent Windows Start Menu shortcut generation for `autoresearch.lnk`.
- Standardize runtime state, configuration, and structured JSON Lines logging under per-user locations.
- Require `ai-powered` as the sole AI interface and remove all legacy Augment Code AI or other external AI provider integrations.
- Add acceptance coverage for scheduled task configuration, install/update/remove behavior, runtime limits, logging, shortcuts, dependency validation, and idempotency.

## Capabilities

### New Capabilities
- `autoresearch`: Specifies the Windows idle-time autoresearch wrapper, including installation, scheduling, launch behavior, runtime limits, updates, removal, diagnostics, logging, dependency rules, and acceptance tests.

### Modified Capabilities
- None.

## Impact

- Affected code: `scripts/launch.ps1`, shortcut creation logic, package metadata, AI integration code, dependency installation logic, and any legacy provider configuration.
- Affected systems: Windows 10/11 Task Scheduler, PowerShell 5.1 or later, Git, npm, per-user Programs and AppData folders, Start Menu shortcuts, and local state/log files.
- Affected dependencies: `ai-powered` becomes the exclusive AI package; Augment Code AI and other external AI SDKs or service configurations are removed.
- Operational impact: The application runs only from the installed per-user wrapper location and only through idle-triggered or user-invoked launcher behavior.