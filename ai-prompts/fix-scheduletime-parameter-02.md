# Role
You are a senior Windows PowerShell engineer with deep expertise in PowerShell 5.1 and 7+ scripting, WPF GUI authoring via `Add-Type -AssemblyName PresentationFramework`, XAML-driven controls (`ComboBox`, `Label`, `RadioButton`), event-handler scope semantics in PowerShell (closures, `.GetNewClosure()`, script-scope vs. function-scope), the `ScheduledTasks` module (`New-ScheduledTaskTrigger`, `Register-ScheduledTask`), and surgical refactoring of self-installing bootstrap scripts.

# Repository Context
- Workspace root: `G:\_kyle\temp_documents\GitHub\autoresearch\autoresearch-win-rtx-scheduled`
- Primary target file: `scripts\launch.ps1` (single-file CLI + WPF GUI launcher; ~992 lines).
- Secondary target file: `README.md` (root) - update only if user-visible scheduling examples change.
- Prior change spec: `ai-prompts\fix-scheduletime-parameter.md` (v1). v2 (this file) focuses on **making the v1 specification actually work at runtime in the GUI**.

# Objective
Make the WPF launcher GUI in `scripts\launch.ps1` **reactively** swap the `CbTime` ComboBox's label, options, and default selection whenever the user changes `CbFreq`, per the table below. The CLI semantics and validation are already in place; the runtime defect is that the `CbFreq.SelectionChanged` handler does not visibly update `LblTime.Content` or `CbTime.ItemsSource` because the registered script block does not capture the enclosing function's locals (`$C`, `$hourOptions`, `$timeOptions`, `$dayOptions`, `$applyFreqItems`). Diagnose, fix, and verify.

| `CbFreq` selection | `LblTime.Content`              | `CbTime` options                                                                 | Default selection |
|--------------------|--------------------------------|----------------------------------------------------------------------------------|-------------------|
| `Hourly`           | `Minute of hour`               | `:00`, `:10`, `:20`, `:30`, `:40`, `:50`                                         | `:00`             |
| `Daily`            | `Time of day (HH:mm, local)`   | `00:00`, `00:15`, `00:30`, ..., `23:45` (15-minute steps, 96 entries)            | `18:00`           |
| `Weekly`           | `Day of week`                  | `Sunday`, `Monday`, `Tuesday`, `Wednesday`, `Thursday`, `Friday`, `Saturday`     | `Sunday`          |

# Mandatory Investigation Steps (do these first)
1. Read `scripts\launch.ps1` end-to-end with `view`. Locate `Show-LaunchGui` and the `$applyFreqItems` script block (currently near lines 746-907). Note the existing logic appears correct in source but fails at runtime.
2. Confirm with `codebase-retrieval` how event-handler script blocks are registered elsewhere (`Add_Checked`, `add_SelectionChanged`, `Add_Click`) and whether any use `.GetNewClosure()` or script-scoped variables.
3. Identify the **root cause**: WPF event handlers invoke the script block on the UI dispatcher in a scope that does NOT inherit the caller's locals. `$C`, `$applyFreqItems`, `$hourOptions`, `$timeOptions`, `$dayOptions`, and `$d` are function-local; the handler sees them as `$null` under `Set-StrictMode -Version Latest`, which silently swallows the failure (the handler throws, WPF logs nothing visible to the user).
4. Verify the same defect affects `populateModels` (provider RadioButtons) and the OK/Cancel/Defaults Click handlers, even if their visible symptoms differ.

# Required Fix (apply all)

## A. Scope-stable event handlers
Refactor every event-handler registration inside `Show-LaunchGui` so the script blocks reliably see the controls and helpers they need. Use ONE of these patterns consistently throughout the function (pick the one that minimizes diff and matches surrounding style):
- **Preferred:** promote `$C`, `$hourOptions`, `$timeOptions`, `$dayOptions`, `$applyFreqItems`, `$populateModels`, `$collect`, and `$d` to `$script:` scope inside `Show-LaunchGui` and reference them as `$script:C`, `$script:applyFreqItems`, etc. inside every handler.
- **Acceptable alternative:** append `.GetNewClosure()` to each script block at registration time, e.g. `$C.CbFreq.add_SelectionChanged({ ... }.GetNewClosure())`. Apply uniformly to ALL handlers in the function, not just `CbFreq`.

Whichever pattern you choose, the `CbFreq.SelectionChanged` handler must:
1. Reset `CbTime.SelectedIndex` to `-1`.
2. Invoke the equivalent of `& $applyFreqItems` (or its inlined body) so `LblTime.Content`, `CbTime.ItemsSource`, and the default selection all update synchronously before the dispatcher returns.

## B. ItemsSource refresh semantics
- Continue using `[System.Collections.Generic.List[string]]` for the three option collections, but assign them to `CbTime.ItemsSource` only after clearing any prior selection (`CbTime.SelectedIndex = -1`) and clearing `CbTime.ItemsSource = $null` immediately before reassignment. This avoids WPF "Items collection must be empty before using ItemsSource" / stale-binding artifacts when switching frequencies repeatedly.
- After reassigning `ItemsSource`, set `CbTime.SelectedIndex` to the index of the documented default for that frequency.

## C. Initial state on window load
- Ensure `applyFreqItems` runs exactly once after XAML load AND after `Read-LaunchDefaults` restoration, so the initial `CbTime` matches the initial `CbFreq` (which defaults to `Daily` per the XAML `IsSelected="True"`).
- If persisted defaults specify a `ScheduleFrequency`, select that ComboBoxItem first, then run `applyFreqItems`, then attempt to select the persisted `ScheduleTime` only if it appears in the new option set; otherwise leave the documented default selected.

## D. Preserve unrelated behavior
- Do NOT modify XAML structure beyond what is strictly necessary (you may keep the XAML untouched - the fix is in the PowerShell that loads it).
- Do NOT alter CLI parameters, `Test-ScheduleTime`, `Get-ScheduleTimeOptions`, `Get-ScheduleTimeDefault`, `Get-TaskTrigger`, the `Autoresearch-Train` task registration, the self-cloning bootstrap, JSONL logging, or the `-NoGui` headless path.
- Do NOT introduce new top-level functions unless absolutely required; prefer in-place edits to `Show-LaunchGui`.

# Guidelines
- Use `view` (with `search_query_regex` where helpful) and `codebase-retrieval` to confirm current line numbers and symbol shapes BEFORE editing.
- Use `str-replace-editor` for all edits. Do NOT rewrite either file wholesale. Each `str_replace` should be a minimal, contiguous block.
- Match surrounding style: cmdlet casing, parameter-block layout, comment density. Do NOT add narrative or rationale comments; match the existing terse convention.
- Honor `.augment/rules/no-em-dash.md`: never emit the em-dash character (U+2014). Use `-` or `--`.
- Honor `.augment/rules/character-count-management.md`: do NOT modify any file under `.augment/`.
- PowerShell must remain compatible with both Windows PowerShell 5.1 and PowerShell 7+ (no `??`, no `?.`, no ternary operator, no `using namespace` directives added).
- Preserve `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` semantics; any new code must run cleanly under both.

# What to Avoid
- Do NOT split `-ScheduleTime` into multiple parameters, add aliases, or apply `[ValidateSet(...)]` to it.
- Do NOT change `-ScheduleFrequency`'s type, default, or `[ValidateSet]`.
- Do NOT add or remove unrelated GUI controls, GroupBoxes, or Buttons.
- Do NOT add MessageBox prompts, dialogs, or other interactive UI.
- Do NOT introduce new files (no new modules, no new tests in new files, no new docs) unless explicitly requested.
- Do NOT commit, push, tag, branch, rebase, or run any destructive git operation without explicit user permission.
- Do NOT install or upgrade packages, do NOT modify `pyproject.toml`, `package.json`, or `.augment/extensions.json`.
- Do NOT print, log, or echo secrets (API keys, tokens) anywhere, including diagnostic output.

# Deliverables (in this exact order)
1. A short numbered task plan (<= 8 items) registered via the task-management tools, with states updated as work progresses.
2. A 3-to-6-line root-cause diagnosis explaining WHY the GUI currently fails to update (scope capture in WPF event handlers under StrictMode), citing concrete line numbers from `scripts\launch.ps1`.
3. One or more `str-replace-editor` edits to `scripts\launch.ps1` implementing fixes A through D. Group related edits into a single tool call where possible.
4. If, and only if, the visible CLI examples in `README.md` reference `-ScheduleTime` values no longer valid for their stated frequency, one `str-replace-editor` edit to `README.md` correcting those examples. Otherwise skip.
5. A manual verification checklist (numbered, <= 10 steps) the user can execute in a fresh PowerShell session to confirm the fix, including the exact commands and expected GUI state at each step.
6. A 5-to-10-line final summary listing: files changed, the chosen scope-stabilization pattern (script-scope vs. `.GetNewClosure()`) and why, and any follow-ups the user should consider (but do not perform unsolicited).

# Success Criteria (every item must be true)
- [ ] Launching `pwsh -File .\scripts\launch.ps1` (no args) opens the GUI; selecting `Hourly` in `CbFreq` immediately changes `LblTime` to `Minute of hour` and `CbTime` to the six `:MM` options with `:00` selected.
- [ ] Selecting `Daily` immediately changes `LblTime` to `Time of day (HH:mm, local)` and `CbTime` to the 96 `HH:mm` options with `18:00` selected.
- [ ] Selecting `Weekly` immediately changes `LblTime` to `Day of week` and `CbTime` to the seven weekday names with `Sunday` selected.
- [ ] Repeatedly cycling `Hourly -> Daily -> Weekly -> Hourly` produces correct labels and option sets every time, with no stale items and no WPF exceptions in the console.
- [ ] Clicking `Save as Defaults`, closing the window, and relaunching restores the prior `CbFreq` + `CbTime` correctly; an invalid persisted pair falls back silently to the frequency's documented default.
- [ ] `pwsh -File .\scripts\launch.ps1 -NoGui -RegisterTask -ScheduleFrequency Hourly -ScheduleTime ':30'` still registers the task without invoking the GUI.
- [ ] `pwsh -File .\scripts\launch.ps1 -NoGui -RegisterTask -ScheduleFrequency Weekly -ScheduleTime 'Wednesday'` still registers a weekly task.
- [ ] No em-dashes appear in any modified line; no file under `.augment/` is modified; no new files are created.
- [ ] Script runs without errors under both Windows PowerShell 5.1 and PowerShell 7+ with `Set-StrictMode -Version Latest`.

# Token / Edit Budget
Target **<= 600 tokens** of net new or modified PowerShell across `scripts\launch.ps1`. Prefer the smallest viable change set that satisfies every success criterion. Do not refactor unrelated code paths "while you're in there".
