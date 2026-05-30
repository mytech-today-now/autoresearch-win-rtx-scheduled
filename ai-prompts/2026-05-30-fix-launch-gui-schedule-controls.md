# Role
You are a senior Windows PowerShell engineer fluent in PowerShell 5.1 and 7+, WPF GUI authoring via `Add-Type -AssemblyName PresentationFramework`, XAML-driven controls (`ComboBox`, `Label`, `RadioButton`), event-handler scope semantics in PowerShell (closures, `.GetNewClosure()`, `$script:` scope), and surgical refactoring of self-installing bootstrap scripts.

# Repository Context
- Workspace root: `G:\_kyle\temp_documents\GitHub\autoresearch\autoresearch-win-rtx-scheduled`
- Target file: `scripts\launch.ps1` (single-file CLI + WPF GUI launcher, ~992 lines). The Schedule `GroupBox` lives in the embedded XAML near line 788; the `Show-LaunchGui` body and `$applyFreqItems` script block sit near lines 800-840.
- Related helpers already exist and MUST NOT be changed: `Get-ScheduleTimeOptions`, `Get-ScheduleTimeDefault`, `Test-ScheduleTime`, `Get-TaskTrigger`, `Initialize-LaunchConfig`, the `Autoresearch-Train` registration path, and the `-NoGui` headless path.

# Objective
Refactor the **Schedule** controls inside `Show-LaunchGui` so the `LblTime` label, `CbTime` ComboBox option set, and `CbTime` default selection update **reactively and idempotently** whenever the user changes `CbFreq`. The user must be able to flip between Hourly/Daily/Weekly arbitrarily many times with correct contents every time and no stale items or WPF exceptions.

| `CbFreq` | `LblTime.Content`             | `CbTime` items                                                       | Default  |
|----------|-------------------------------|----------------------------------------------------------------------|----------|
| Hourly   | `Minute of hour`              | `:00`, `:10`, `:20`, `:30`, `:40`, `:50`                             | `:00`    |
| Daily    | `Time of day (HH:mm, local)`  | `00:00`..`23:45` in 15-minute steps (96 entries, existing data set)  | `18:00`  |
| Weekly   | `Day of week`                 | `Sunday`..`Saturday`                                                 | `Sunday` |

# Required Behavior
1. `CbFreq.add_SelectionChanged` must clear `CbTime.SelectedIndex` to `-1`, null out `CbTime.ItemsSource`, reassign the correct list, then set `SelectedIndex` to the documented default's index - synchronously, before the dispatcher returns.
2. Use `$script:` scope (preferred) OR a uniform `.GetNewClosure()` pattern so handlers reliably capture `$C`, `$hourOptions`, `$timeOptions`, `$dayOptions`, and `$applyFreqItems` under `Set-StrictMode -Version Latest`. Apply the chosen pattern to ALL handlers in `Show-LaunchGui`, not just `CbFreq`.
3. Run `applyFreqItems` exactly once after XAML load AND after `Read-LaunchDefaults` restoration. If a persisted `ScheduleFrequency` is present, select it first, then run `applyFreqItems`, then restore `ScheduleTime` only if it appears in the new option set; otherwise silently fall back to the frequency's default.
4. Reuse the existing data sources (`Get-ScheduleTimeOptions`, `Get-ScheduleTimeDefault`) inside the GUI so CLI and GUI share one source of truth.

# Constraints
- Edit ONLY `scripts\launch.ps1`. Do not modify XAML structure beyond what is strictly necessary; the fix belongs in the PowerShell that loads it.
- Preserve PS 5.1 + 7+ compatibility (no `??`, `?.`, ternary, or `using namespace`). Preserve `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`.
- Do not change CLI parameters, `[ValidateSet]` lists, defaults, or the `-NoGui` path.
- Do not add MessageBoxes, new GroupBoxes, new files, or new top-level functions.
- Do not modify anything under `.augment\`, `pyproject.toml`, `package.json`, or `.augment\extensions.json`.
- Honor `.augment\rules\no-em-dash.md`: never emit `U+2014`; use `-` or `--`.
- Do not commit, push, branch, tag, or run destructive git operations without explicit permission.
- Do not log or echo secrets anywhere.

# Workflow
1. Use `view` and `codebase-retrieval` to confirm current line numbers, symbol shapes, and existing handler-registration style BEFORE editing.
2. Register a short numbered task plan (<= 8 items) via the task tools; update states as you progress.
3. Make minimal, contiguous `str-replace-editor` edits. Group related edits into one tool call where possible. Match surrounding cmdlet casing and comment density; do not add narrative comments.
4. After editing, run `diagnostics` on `scripts\launch.ps1` and resolve any reported issues.

# Verification (you must execute and report)
Provide a numbered manual checklist (<= 10 steps) the user can run in a fresh PowerShell session, and additionally run these headless smoke tests yourself via `launch-process` and paste the exit codes:
- `pwsh -NoProfile -File .\scripts\launch.ps1 -NoGui` (preflight only; exits 0).
- Dot-source the script in a child `pwsh` and call `Get-ScheduleTimeOptions` + `Test-ScheduleTime` for each frequency with valid and invalid values; confirm valid passes and invalid throws.
- Manually instruct the user to launch the GUI and cycle Hourly -> Daily -> Weekly -> Hourly, confirming the table above at each step and that `Save as Defaults` -> close -> relaunch restores the prior pair.

# Token / Edit Budget
Target **<= 550 tokens** of net new or modified PowerShell across `scripts\launch.ps1`. Prefer the smallest viable change set that satisfies every success criterion. Do not refactor unrelated code paths "while you're in there".

# Deliverables (in this order)
1. A 3-to-6-line root-cause diagnosis citing concrete line numbers.
2. The `str-replace-editor` edits implementing the fix.
3. Headless smoke-test output (exit codes + any thrown messages).
4. The numbered manual GUI verification checklist.
5. A 5-to-10-line summary listing files changed, the scope-stabilization pattern chosen and why, and any optional follow-ups (do not perform unsolicited).