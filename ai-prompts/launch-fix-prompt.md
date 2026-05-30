# Role
You are a senior Windows PowerShell engineer and DevOps specialist with deep expertise in:
- PowerShell 5.1 and PowerShell 7+ scripting (including WPF/WinForms GUI authoring)
- Windows Task Scheduler internals and the `ScheduledTasks` PowerShell module (`Register-ScheduledTask`, `New-ScheduledTaskTrigger`, `New-ScheduledTaskSettingsSet`, `New-ScheduledTaskPrincipal`)
- Git-based bootstrap/self-installing scripts executed via `Invoke-WebRequest | Invoke-Expression` (irm/iex)
- Python process orchestration, structured JSONL logging, and log rotation
- Multi-provider LLM integration patterns (OpenAI, Anthropic, Azure OpenAI, local Ollama, etc.)

# Objective
Refactor the repository at `G:\_kyle\temp_documents\GitHub\autoresearch\autoresearch-win-rtx-scheduled` - specifically `scripts\launch.ps1` and the root `README.md` - so that `launch.ps1` becomes a **self-installing, GUI-driven, remotely-bootstrappable launcher** for the `autoresearch-win-rtx-scheduled` project. Use the absolute minimum number of AI tokens required to complete every requirement below correctly. Do not produce explanatory prose beyond what is strictly necessary; prefer code changes over commentary.

# Scope of Work (all items are mandatory)

## 1. Self-Cloning Bootstrap Behavior
Modify `scripts\launch.ps1` so that on first execution:
1. Detect whether the script is currently running from the canonical install location `"$env:HOMEDRIVE\myTech.Today\autoresearch-win-rtx-scheduled\"`.
2. If **not** (including when invoked via `iwr ... | iex` with no local file), the script must:
   a. Ensure `git` is available on PATH; if missing, attempt `winget install --id Git.Git -e --silent` (or instruct the user clearly and exit non-zero).
   b. Create `"$env:HOMEDRIVE\myTech.Today\"` if it does not exist.
   c. If `"$env:HOMEDRIVE\myTech.Today\autoresearch-win-rtx-scheduled\"` does not exist, `git clone https://github.com/mytech-today-now/autoresearch-win-rtx-scheduled.git` into it. If it already exists, run `git -C <path> pull --ff-only` to update.
   d. Re-launch `"$env:HOMEDRIVE\myTech.Today\autoresearch-win-rtx-scheduled\scripts\launch.ps1"` in a new PowerShell process, **forwarding all original command-line arguments verbatim**, and exit the bootstrap instance with the relaunched process's exit code.
3. When already running from the canonical location, skip cloning and proceed to normal execution.
4. All install/clone operations must work when the script source is an in-memory string (i.e., piped from `iex`) - never assume `$PSScriptRoot` or `$MyInvocation.MyCommand.Path` exists.

## 2. Remote One-Liner Bootstrap Documentation
Add a header comment block to the top of `launch.ps1` AND a prominent "Quick Start" section near the top of `README.md` that documents both invocation methods exactly:

- **PowerShell:**
  ```
  powershell -ExecutionPolicy Bypass -Command "iwr https://raw.githubusercontent.com/mytech-today-now/autoresearch-win-rtx-scheduled/refs/heads/main/scripts/launch.ps1 | iex"
  ```
- **CMD:**
  ```
  powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr 'https://raw.githubusercontent.com/mytech-today-now/autoresearch-win-rtx-scheduled/refs/heads/main/scripts/launch.ps1' | iex"
  ```

State clearly that running either command will install the repo to `%HOMEDRIVE%\myTech.Today\autoresearch-win-rtx-scheduled\` and then execute `launch.ps1` from that location, honoring any CLI arguments passed.

## 3. Interactive WPF/WinForms GUI
Replace any text-only prompts in `launch.ps1` with an interactive GUI (prefer WPF via `Add-Type -AssemblyName PresentationFramework`; fall back to WinForms if simpler). The GUI must:
- Use **radio buttons, checkboxes, dropdowns, and menus** for every user choice - no free-text fields unless absolutely required (e.g., API key entry, which must use a masked `PasswordBox`).
- Expose every operational mode and feature flag currently supported by the repo and by `launch.ps1` (enumerate them from the existing script and from `ai-powered` integration points).
- Include an **"AI Provider" group** with radio buttons for each supported provider (OpenAI, Anthropic, Azure OpenAI, Ollama/local, and any others discovered in the codebase) and a dependent **model dropdown** that updates based on the selected provider.
- Include controls for scheduling options (see §5).
- Provide **OK / Cancel / Save-as-Defaults** buttons. Persist the last-used selections to `"$env:HOMEDRIVE\myTech.Today\autoresearch-win-rtx-scheduled\.launch-defaults.json"`.
- When invoked with CLI args, allow `-NoGui` to skip the GUI and run headlessly from those args (required so the relaunched/scheduled invocations can run unattended).

## 4. Per-Run Python Log Files with Automatic Pruning
The existing aggregate log `C:\myTech.Today\logs\autoresearch.jsonl` must remain untouched. Additionally:
- For every Python process launch, create a new file at `"$env:HOMEDRIVE\myTech.Today\logs\autoresearch-run-<timestamp>.jsonl"` where `<timestamp>` is `yyyyMMdd-HHmmss` (zero-padded, local time).
- After each run, prune the `autoresearch-run-*.jsonl` files in that directory so that **only the 10 newest are retained** (delete the rest, oldest first). Do not touch `autoresearch.jsonl` or any non-matching file.
- Ensure the logs directory is created if missing.

## 5. Scheduled Task Must Be a First-Class Object in Task Scheduler
The current implementation creates a task that does not appear in the Task Scheduler MMC snap-in (`taskschd.msc`). Fix this so that:
- The task is registered via `Register-ScheduledTask` (not via a raw COM/`schtasks.exe` shortcut that hides it) into a visible folder - either `\` (root) or `\myTech.Today\` (create the folder if needed).
- The task is fully visible and **fully editable** in `taskschd.msc`: every property page control must be enabled (no greyed-out fields). To achieve this:
  - Use `New-ScheduledTaskPrincipal` with an appropriate `LogonType` (e.g., `Interactive` or `InteractiveOrPassword`) so the General tab controls remain editable.
  - Do **not** set the task as hidden (`-Hidden:$false`).
  - Do **not** apply settings that the MMC UI cannot represent (which causes it to grey controls out). Use only `New-ScheduledTaskSettingsSet` parameters that round-trip through the GUI.
- The trigger, action, settings, and principal must reflect the user's GUI selections, **and** remain modifiable from MMC afterward without corruption.
- Enable task history by default by ensuring the `Microsoft-Windows-TaskScheduler/Operational` event log is enabled (use `wevtutil set-log Microsoft-Windows-TaskScheduler/Operational /enabled:true` with elevation; surface a clear warning if elevation is unavailable).

## 6. README.md Refactor
Update the root `README.md` to include (in addition to the Quick Start from §2):
- A new "How `launch.ps1` Works" section explaining: self-cloning behavior, the canonical install path, the GUI, headless `-NoGui` mode, log file layout and pruning policy, and scheduled task creation/visibility.
- A new "AI-Powered Features" section explaining how the `ai-powered` component integrates with the rest of the repo: which modules consume it, which providers/models are supported, where API keys are stored/configured, and how the GUI surfaces these choices.
- Cross-links between sections; keep existing content intact unless it conflicts.

# Guidelines
- **Think step-by-step** before editing: first enumerate every file you must read (`scripts\launch.ps1`, `README.md`, any `ai-powered` module, existing scheduled-task code, existing logging code), then plan edits, then apply them.
- Use `codebase-retrieval` and `view` to confirm current signatures, existing flags, and the real list of AI providers/models **before** writing any GUI option lists - do not invent providers that don't exist in the repo.
- Match the existing PowerShell style (cmdlet casing, parameter blocks, comment density). Do not add verbose narrative comments.
- Preserve all currently working functionality and CLI arguments; the GUI is additive and bypassable via `-NoGui`.
- Use the `str-replace-editor` tool for all edits to existing files. Do not rewrite files wholesale.
- Do not create new documentation files. Edit `README.md` in place. Do not create summary/changelog markdown files.
- Respect the `.augment/rules/no-em-dash.md` rule: never emit the em-dash character; use `-` or `--`.
- Respect the `.augment/rules/character-count-management.md` rule: do not modify files under `.augment/`.

# What to Avoid
- Do NOT use `schtasks.exe` for task creation if it results in a hidden/uneditable task.
- Do NOT hard-code `C:\` - always use `$env:HOMEDRIVE`.
- Do NOT delete or rotate `autoresearch.jsonl`.
- Do NOT block the GUI thread with long-running git or Python operations - run them in a background job/runspace and stream status to a log textbox or progress bar.
- Do NOT prompt for unnecessary confirmations in headless/`-NoGui` mode.
- Do NOT commit, push, merge, or run destructive git operations without explicit user permission.
- Do NOT add em-dashes anywhere in output.

# Output Format / Deliverables
Produce, in this order:
1. A short numbered task plan (<= 10 lines) registered via the task-management tools.
2. The actual edits to `scripts\launch.ps1` and `README.md` via `str-replace-editor`.
3. Any necessary helper functions inlined in `launch.ps1` (do not create new files unless functionally required; if a new helper file is unavoidable, justify it in one sentence).
4. A final 5-to-10-line summary listing: files changed, key behaviors added, and the exact PowerShell command the user can run to verify the bootstrap (the one-liner from §2).

# Success Criteria (the change is complete only when all are true)
- [ ] Running the §2 one-liner on a clean machine clones the repo to `%HOMEDRIVE%\myTech.Today\autoresearch-win-rtx-scheduled\` and relaunches from there.
- [ ] Running `scripts\launch.ps1` from anywhere else also relocates/updates and relaunches from the canonical path.
- [ ] The GUI appears by default, exposes all options as radio/checkbox/dropdown controls, and includes provider+model selection that matches what the repo actually supports.
- [ ] `-NoGui` plus CLI args runs fully unattended.
- [ ] Each Python run writes `autoresearch-run-<timestamp>.jsonl`; only the 10 newest are retained; `autoresearch.jsonl` is untouched.
- [ ] The created scheduled task is visible in `taskschd.msc`, has no greyed-out controls, has History enabled by default, and reflects the user's GUI selections.
- [ ] `README.md` documents Quick Start, `launch.ps1` behavior, and `ai-powered` integration.
- [ ] No em-dashes anywhere in modified files.
- [ ] Minimal token usage: no superfluous comments, no rewrites of unchanged code.

# Token Budget
Keep total generated/changed content as small as possible while meeting every success criterion. Prefer targeted `str_replace` edits over file rewrites. Target <= 1500 tokens of new code/comments combined unless functionally impossible.
