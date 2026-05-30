# Role
You are a senior Windows PowerShell engineer with deep expertise in PowerShell 5.1 and 7+ scripting, WPF GUI authoring via `Add-Type -AssemblyName PresentationFramework`, JSON configuration round-tripping (`ConvertFrom-Json` / `ConvertTo-Json`), the `ai-powered` npm CLI (single-file local config at `ai-powered.json`, fields `provider`, `customProviderType`, `baseUrl`, `model`), the `ScheduledTasks` module, and breaking-change parameter refactors in self-installing bootstrap scripts.

# Repository Context
- Workspace root: `G:\_kyle\temp_documents\GitHub\autoresearch\autoresearch-win-rtx-scheduled`
- Primary targets: `scripts\launch.ps1` (~992 lines), `ai-powered.json` (repo root), `tests\launch.Tests.ps1`, `README.md` (only if user-visible examples change).
- `launch.json` is the persisted GUI-defaults file written next to the canonical script at `$Script:DefaultsPath` (currently absent; created on first save).
- Sibling spec: `ai-prompts\fix-scheduletime-parameter-02.md` (same template, GUI scope-capture fix). Re-use that file's conventions.

# Objective
Introduce a single, provider-agnostic `-ProviderHost` parameter (and matching `ProviderHost` key in `launch.json`, and matching GUI control) that controls the `baseUrl` field of `ai-powered.json` for every supported provider. **This is a deliberate breaking change**: the existing `-OllamaHost` parameter is removed entirely, with no alias and no deprecation period. Any external caller, scheduled task, or test that still passes `-OllamaHost` MUST be updated as part of this change.

# Supported Providers and Per-Provider Default Hosts
Supported provider set after this change: `ollama`, `openai`, `anthropic`, `azure`. **`aws` is NOT added.** If any prior prompt or scratch file mentioned AWS, ignore it.

| `-Provider` | Default `ProviderHost` (when CLI omits `-ProviderHost` AND `launch.json` omits `ProviderHost`) |
|-------------|------------------------------------------------------------------------------------------------|
| `ollama`    | `http://127.0.0.1:11434`                                                                       |
| `openai`    | `https://api.openai.com/v1`                                                                    |
| `anthropic` | `https://api.anthropic.com`                                                                    |
| `azure`     | value of `-AzureEndpoint` if non-empty, else empty string (treat as required-at-runtime; do NOT fabricate a URL) |

The universal scalar default value `http://127.0.0.1:11434` applies only when the active provider is `ollama` (i.e. it is the Ollama row of the table above). Do not hard-code it elsewhere.

# Resolution Order (highest to lowest precedence)
1. Explicit `-ProviderHost <value>` on the CLI (or the GUI's ProviderHost control, which feeds the same variable).
2. `ProviderHost` field in `launch.json` if present and non-empty.
3. Per-provider default from the table above (looked up against the resolved `-Provider`).

The resolver must be a single helper, e.g. `Resolve-ProviderHost -Provider <name> -CliValue <string> -Persisted <string>`, called exactly once after CLI parsing and once after GUI submission. It MUST NOT silently coerce an empty string at step 1 or step 2 into the per-provider default; only an unbound / `$null` / whitespace-only value falls through to step 3.

# Mandatory Investigation Steps (do these first)
1. `view` the current `scripts\launch.ps1` end-to-end. Confirm every site that references `OllamaHost`, `$OllamaHost`, `OLLAMA_HOST`, `CbHost`, or `LblHost`. There are at least: the `param(...)` block, `Initialize-LaunchConfig`, `Read-LaunchDefaults`, `Save-LaunchDefaults`, `Show-LaunchGui` (XAML + populate handlers + collect closure), `Set-WorkloadEnvironment`, `Register-LauncherTask`, `Invoke-FromGui`, the comment-based help (`.PARAMETER`, `.EXAMPLE` blocks), and the final "next-steps" `Write-Host` block.
2. `view` `ai-powered.json` and confirm its current keys (`provider`, `customProviderType`, `baseUrl`, `model`).
3. `view` `tests\launch.Tests.ps1` and identify every assertion that references `OllamaHost`, `-OllamaHost`, or the env var `OLLAMA_HOST`.
4. `view` `README.md`; locate any CLI examples using `-OllamaHost`.
5. Use `codebase-retrieval` to confirm no other script (e.g., under `scripts\internal\`, `scripts\test-autoresearch-*.ps1`, `scripts\verify-ai-provider.mjs`) hard-codes `-OllamaHost`.

# Required Changes (apply all)

## A. `scripts\launch.ps1` - parameter and resolver
- Remove the `[string]$OllamaHost = 'http://127.0.0.1:11434'` parameter from the `param(...)` block entirely.
- Add `[string]$ProviderHost` (no default; defaulting is the resolver's job).
- Add a private hashtable, e.g. `$Script:ProviderHostDefaults = @{ ollama='http://127.0.0.1:11434'; openai='https://api.openai.com/v1'; anthropic='https://api.anthropic.com'; azure='' }`.
- Add `Resolve-ProviderHost` per the resolution-order spec above. The Azure branch must check `$AzureEndpoint` and prefer it over the empty default.
- Rename every internal reference: `$OllamaHost` -> `$ProviderHost` throughout. Update all `Write-Json` `-Extra` payload keys from `ollamaHost` to `providerHost`.

## B. `scripts\launch.ps1` - downstream wiring
- `Set-WorkloadEnvironment`: stop setting `OLLAMA_HOST`. Instead, set `AI_BASE_URL=$ProviderHost` (the env-var name consumed by `ai-powered`; verify against its README before committing). Continue to set `AI_PROVIDER`, `AI_MODEL`, `AI_POWERED_MODEL`.
- After preflight and after any GUI submission, rewrite `ai-powered.json` in place using `ConvertTo-Json -Depth 6` so that:
  - `provider` reflects the active `-Provider` (mapping `ollama` -> `"custom"` + `customProviderType="ollama"`, all others map straight through to their literal names),
  - `baseUrl` equals the resolved `$ProviderHost`,
  - `model` equals the resolved `$Model`,
  - any other pre-existing keys are preserved (merge, do not clobber).
- `Test-OllamaListening`, `Start-OllamaServer`, `Sync-OllamaModel` continue to be invoked **only when `$Provider -eq 'ollama'`**, and must reference `$ProviderHost` (not `$OllamaHost`).
- `Register-LauncherTask`: replace the `-OllamaHost "`$OllamaHost`"` segment of `$argParts` with `-ProviderHost "`$ProviderHost`"`. Keep the segment gated on `$Provider -eq 'ollama'` removed - emit `-ProviderHost` for every provider so the scheduled task is reproducible.

## C. `scripts\launch.ps1` - GUI (`Show-LaunchGui`)
- Rename the existing XAML `CbHost` ComboBox to `CbProviderHost` (or keep the `x:Name` but rename the label `LblHost` text from "Ollama host (Ollama only)" to "Provider host"). Pre-seed it with `http://127.0.0.1:11434` and `http://localhost:11434` but keep `IsEditable="True"` so users can paste any URL.
- The host control is now enabled for ALL providers, not just Ollama. Remove the `$C.CbHost.IsEnabled = ($prv -eq 'ollama')` line.
- On provider radio-button change, if the host text is empty OR matches a known per-provider default for the previously selected provider, replace it with the per-provider default for the newly selected provider; otherwise leave the user's custom value untouched.
- The `$collect` script block must emit `ProviderHost = [string]$C.CbProviderHost.Text` (replace the old `OllamaHost = ...` line).
- Honor the v2 scope-capture pattern already established in `fix-scheduletime-parameter-02.md` (use the same `$script:` or `.GetNewClosure()` strategy already in place; do not regress it).

## D. `launch.json` persistence
- `Read-LaunchDefaults` / `Save-LaunchDefaults` / `Initialize-LaunchConfig`: replace every occurrence of the key `OllamaHost` with `ProviderHost` (PascalCase, matching the file's existing convention). Do NOT use `PROVIDER_HOST`.
- `Initialize-LaunchConfig` must call `Resolve-ProviderHost` after applying persisted defaults so the resolved value is available to downstream functions even when neither CLI nor persisted layer supplied a value.
- When `Save-LaunchDefaults` writes the file from the GUI's "Save as Defaults" button, persist the user's chosen `ProviderHost` literally (do not normalize/strip).

## E. `ai-powered.json`
- Confirm the existing file contains `"baseUrl": "http://127.0.0.1:11434"` and the rest of the current shape. Do not commit per-provider variants here; the runtime rewrite in B owns this file. Leave the checked-in default content as the Ollama configuration.

## F. Tests (`tests\launch.Tests.ps1`)
- Update every existing test that asserts on `-OllamaHost`, `$OllamaHost`, `OLLAMA_HOST`, or the GUI's `CbHost` to use the new names.
- Do NOT add new test files. Adapt existing assertions only.
- Add (within the existing test file) at least: (1) one Pester test that calls `Resolve-ProviderHost` with each of the four providers and confirms the documented defaults, (2) one test that confirms the CLI value overrides the persisted value, (3) one test that confirms `ai-powered.json` is rewritten with the resolved `baseUrl`.

## G. Documentation
- `scripts\launch.ps1` comment-based help: remove the `.PARAMETER OllamaHost` block and add a `.PARAMETER ProviderHost` block. Update every `.EXAMPLE` that references `-OllamaHost`.
- `README.md`: update any visible CLI example using `-OllamaHost` to `-ProviderHost`. Do not introduce new top-level sections.

# Guidelines
- Use `view` and `codebase-retrieval` before every edit to confirm symbol locations and current line numbers.
- Use `str-replace-editor` only. No file rewrites. Group related edits into single tool calls.
- Match surrounding PowerShell style: terse comments, cmdlet casing, parameter-block layout. Do not add narrative commentary.
- Honor `.augment/rules/no-em-dash.md` (no U+2014) and `.augment/rules/character-count-management.md` (do not modify any file under `.augment/`).
- Maintain Windows PowerShell 5.1 and PowerShell 7+ compatibility under `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'`. No `??`, no `?.`, no ternary, no `using namespace`.
- Never log, echo, or persist API keys, tokens, or Azure endpoints into `ai-powered.json` or any JSONL log surface.

# What to Avoid
- Do NOT keep `-OllamaHost` as an alias, deprecated parameter, or undocumented variable. The user explicitly asked for a clean break.
- Do NOT add an `aws` provider option anywhere (param `[ValidateSet]`, GUI radio button, model table, default-host table, README, tests).
- Do NOT change the casing of the persisted key: it must be `ProviderHost` in `launch.json`, NOT `PROVIDER_HOST` and NOT `providerHost`.
- Do NOT split `-ProviderHost` into multiple parameters (e.g. one per provider). One scalar parameter governs all providers.
- Do NOT touch unrelated GUI controls (Action group, Schedule group, ChkHistory, Save-as-Defaults / Cancel / OK buttons).
- Do NOT introduce new files. Do NOT proactively create docs or changelog entries.
- Do NOT commit, push, branch, tag, or run destructive git operations without explicit user permission.
- Do NOT run `npm install`, `uv sync`, or any other package-manager operation as part of this change.

# Deliverables (in this exact order)
1. A short numbered task plan (<= 10 items) registered via the task-management tools, states updated as work progresses.
2. A 3-to-6-line breaking-change notice summarizing what existing callers must update (`-OllamaHost` -> `-ProviderHost`, `OllamaHost` -> `ProviderHost` in `launch.json`, `OLLAMA_HOST` env var no longer set).
3. Grouped `str-replace-editor` edits to `scripts\launch.ps1` covering changes A through D and G.
4. Edits (if any) to `ai-powered.json` per change E. If no content change is needed, state so explicitly.
5. `str-replace-editor` edits to `tests\launch.Tests.ps1` per change F.
6. `str-replace-editor` edits to `README.md` per change G (only if examples reference `-OllamaHost`).
7. A manual verification checklist (numbered, <= 12 steps) the user can paste into a fresh PowerShell session, including (a) GUI smoke test across all four providers, (b) `pwsh -File .\scripts\launch.ps1 -NoGui -RunNow -Provider openai -ProviderHost https://api.openai.com/v1`, (c) `pwsh -File .\scripts\launch.ps1 -NoGui -RegisterTask -ScheduleFrequency Daily -ScheduleTime 18:00 -Provider anthropic`, (d) inspecting the resulting `ai-powered.json` for the rewritten `baseUrl`, (e) running the Pester suite.
8. A 5-to-10-line final summary listing files changed, new public CLI surface, the four per-provider defaults, and any follow-ups deferred to the user (e.g., updating downstream automation, rotating any stored secrets).

# Success Criteria (every item must be true)
- [ ] `pwsh -File .\scripts\launch.ps1 -NoGui -RunNow -Provider ollama` works without any `-ProviderHost` flag and contacts `http://127.0.0.1:11434`.
- [ ] `pwsh -File .\scripts\launch.ps1 -NoGui -RunNow -Provider openai` works without any `-ProviderHost` flag and resolves `baseUrl` to `https://api.openai.com/v1` in the rewritten `ai-powered.json`.
- [ ] `pwsh -File .\scripts\launch.ps1 -NoGui -RunNow -Provider anthropic` resolves to `https://api.anthropic.com`.
- [ ] `pwsh -File .\scripts\launch.ps1 -NoGui -RunNow -Provider azure -AzureEndpoint https://my.openai.azure.com` resolves `baseUrl` to that endpoint. Without `-AzureEndpoint` it fails fast with a clear error (no fabricated URL).
- [ ] CLI `-ProviderHost <url>` overrides both the persisted `ProviderHost` and the per-provider default.
- [ ] Persisted `ProviderHost` in `launch.json` overrides the per-provider default but loses to CLI.
- [ ] Passing the (now-removed) `-OllamaHost` produces a "parameter not found" error from PowerShell, not a silent acceptance.
- [ ] The GUI's host control is enabled for every provider, pre-populates the correct per-provider default on radio-button change unless the user has customized it, and round-trips through Save-as-Defaults -> close -> relaunch.
- [ ] `Register-LauncherTask` writes `-ProviderHost "<url>"` (always, for every provider) into the scheduled task's action arguments. No `-OllamaHost` anywhere.
- [ ] `Set-WorkloadEnvironment` sets `AI_BASE_URL` and does not set `OLLAMA_HOST`.
- [ ] `ai-powered.json` after a run contains `baseUrl` equal to the resolved `ProviderHost` and `provider` consistent with `-Provider`.
- [ ] All previously passing tests in `tests\launch.Tests.ps1` still pass, plus the three new `ProviderHost` assertions described in change F.
- [ ] No `aws` mentions in any modified file. No em-dashes. No edits under `.augment\`. No new files.
- [ ] Script runs cleanly under both Windows PowerShell 5.1 and PowerShell 7+ with `Set-StrictMode -Version Latest`.

# Token / Edit Budget
Target **<= 900 tokens** of net new or modified PowerShell across `scripts\launch.ps1` plus **<= 250 tokens** in `tests\launch.Tests.ps1`. Prefer the smallest viable change set that satisfies every success criterion. Do not refactor unrelated code paths while passing through.
