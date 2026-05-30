# Role
You are a senior Windows PowerShell engineer with deep expertise in PowerShell 5.1/7+ scripting, WPF GUI authoring (`Add-Type -AssemblyName PresentationFramework`), the `ScheduledTasks` module (`New-ScheduledTaskTrigger`, `Register-ScheduledTask`), and refactoring CLI parameter validation in self-installing bootstrap scripts.

# Objective
Refactor `scripts\launch.ps1` (CLI + WPF GUI) and the root `README.md` in the repository at `G:\_kyle\temp_documents\GitHub\autoresearch\autoresearch-win-rtx-scheduled` so that the semantics, validation, default value, and dropdown contents of the `-ScheduleTime` parameter change dynamically based on `-ScheduleFrequency`. Use the absolute minimum number of tokens required. Prefer surgical `str_replace` edits over rewrites.

# Scope of Work (all mandatory)

## 1. New `-ScheduleTime` Semantics by `-ScheduleFrequency`
Treat `-ScheduleTime` as a polymorphic string whose meaning depends on `-ScheduleFrequency`:

| Frequency | `-ScheduleTime` meaning | Allowed values | Default |
|---|---|---|---|
| `Hourly` | Minute-of-the-hour offset | `':00'`, `':10'`, `':20'`, `':30'`, `':40'`, `':50'` (10-minute increments) | `':00'` |
| `Daily`  | Local 24-hour time-of-day | `'00:00'`, `'00:15'`, `'00:30'`, ... `'23:45'` (every 15 minutes; 96 values) | `'18:00'` |
| `Weekly` | Weekday name | `'Sunday'`, `'Monday'`, `'Tuesday'`, `'Wednesday'`, `'Thursday'`, `'Friday'`, `'Saturday'` | `'Sunday'` |

Implementation requirements:
- The CLI must accept any of the above forms in a single `[string]$ScheduleTime` parameter (do not split into multiple params).
- Replace the existing static `[string]$ScheduleTime = '03:00'` default with a runtime resolver that picks the correct default for the current `-ScheduleFrequency` when the caller omits `-ScheduleTime`.
- Add a `Test-ScheduleTime` helper that validates the value against the active frequency and throws a clear error (e.g., `"ScheduleTime '<value>' is not valid for ScheduleFrequency '<freq>'. Expected one of: ..."`) listing the allowed set.
- Update `Get-TaskTrigger` so that:
  - `Hourly`: anchor at `[DateTime]::Today` + the chosen minute offset, with `-RepetitionInterval (New-TimeSpan -Hours 1)`.
  - `Daily`: anchor at `[DateTime]::Today.Add([TimeSpan]::Parse($ScheduleTime))`.
  - `Weekly`: use `-Weekly -DaysOfWeek $ScheduleTime` at a fixed sensible local time (preserve current `AddHours(3)` behavior unless a clearly better constant is justified).
- Preserve every other CLI parameter, switch, comment-based help block, and example. Update only the `.PARAMETER ScheduleTime`, `.PARAMETER ScheduleFrequency`, and any `.EXAMPLE` blocks whose literal values are no longer valid.

## 2. WPF GUI Updates
The GUI already exposes `CbFreq` and `CbTime`. Refactor the GUI logic only - do not restructure unrelated controls:
- Bind `CbTime` to a frequency-dependent list using the existing `applyFreqItems` script block pattern. Populate it from three pre-built `[Collections.Generic.List[string]]` collections (`$hourOptions`, `$timeOptions`, `$dayOptions`) matching the tables in §1.
- Update the `Label Content="Time (HH:mm, local)"` text to a dynamic label that reads `"Minute of hour"` / `"Time of day (HH:mm, local)"` / `"Day of week"` depending on the current selection in `CbFreq`. Re-evaluate on `CbFreq.SelectionChanged`.
- When `CbFreq` changes, if the prior `CbTime` selection is invalid for the new frequency, select the documented default for that frequency.
- Defaults-restore logic (`Read-LaunchDefaults`) must validate the persisted `ScheduleTime` against the persisted `ScheduleFrequency` before applying it; on mismatch, silently fall back to the frequency's default.

## 3. README.md Update
Edit `README.md` in place:
- Locate (or add, near the existing scheduling documentation) a "Scheduling" section.
- Document the three frequency modes and the new `-ScheduleTime` value sets in a single markdown table identical in shape to the one in §1.
- Update any pre-existing CLI examples whose `-ScheduleTime` values are no longer valid (e.g., `'03:00'`, `'00:15'`, `'02:00'`) to use values from the new allowed sets.
- Do not introduce new top-level headings unrelated to this change. Do not add changelog files.

# Guidelines
- Use `codebase-retrieval` and `view` on `scripts\launch.ps1` and `README.md` before editing to confirm current line numbers, the GUI XAML structure, the existing `applyFreqItems` block, and every `.EXAMPLE` block that references `-ScheduleTime`.
- Use `str-replace-editor` for all edits. Do not rewrite either file wholesale.
- Match the surrounding PowerShell style: same cmdlet casing, same parameter-block layout, same comment density. Do not add narrative comments.
- Respect `.augment/rules/no-em-dash.md`: never emit em-dash characters; use `-` or `--`.
- Respect `.augment/rules/character-count-management.md`: do not modify files under `.augment/`.
- Do not break the `-NoGui` headless path, the self-cloning bootstrap, the per-run JSONL logging, or the Task Scheduler visibility behavior established by prior changes.

# What to Avoid
- Do NOT split `-ScheduleTime` into multiple parameters or add `-ScheduleDay` / `-ScheduleMinute` aliases.
- Do NOT use `[ValidateSet(...)]` on `-ScheduleTime` (the valid set depends on another parameter; validate in code via `Test-ScheduleTime`).
- Do NOT silently coerce invalid CLI values - throw with the allowed list.
- Do NOT change the type or default of `-ScheduleFrequency`.
- Do NOT add or remove unrelated GUI controls.
- Do NOT commit, push, or run destructive git operations without explicit user permission.

# Output Format / Deliverables (in order)
1. A short numbered task plan (<= 8 lines) registered via the task-management tools.
2. `str-replace-editor` edits to `scripts\launch.ps1` covering: parameter block, `Test-ScheduleTime` helper, default resolution, `Get-TaskTrigger`, GUI option collections, dynamic label, `SelectionChanged` handler, defaults validation, and updated comment-based help / `.EXAMPLE` blocks.
3. `str-replace-editor` edits to `README.md` covering: the Scheduling table and updated examples.
4. A 5-to-10-line final summary listing files changed, the new allowed value sets, and one verification command (e.g., `pwsh -File .\scripts\launch.ps1 -NoGui -RegisterTask -ScheduleFrequency Weekly -ScheduleTime Wednesday`).

# Success Criteria (complete only when all are true)
- [ ] `-ScheduleFrequency Hourly  -ScheduleTime ':30'`     registers a task firing at HH:30 every hour.
- [ ] `-ScheduleFrequency Daily   -ScheduleTime '18:00'`   registers a task firing daily at 18:00 (and `'18:00'` is the default when `-ScheduleTime` is omitted under `Daily`).
- [ ] `-ScheduleFrequency Weekly  -ScheduleTime 'Wednesday'` registers a weekly task on Wednesdays.
- [ ] Any other `-ScheduleTime` value for the active frequency raises a clear error listing the allowed set.
- [ ] The GUI dropdown for `CbTime` and its label both update reactively when `CbFreq` changes, and selecting Hourly/Daily/Weekly exposes exactly the value sets in §1.
- [ ] Persisted defaults round-trip correctly and invalid persisted combinations fall back silently.
- [ ] `README.md` documents the new semantics with a table and valid examples.
- [ ] No em-dashes in any modified file; no unrelated edits; no new files created.

# Token Budget
Target <= 1200 tokens of new code/comments combined across `launch.ps1` and `README.md`. Prefer reusing the existing `applyFreqItems` and defaults-load patterns over inventing new abstractions.
