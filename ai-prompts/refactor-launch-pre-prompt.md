# Task
Refactor this repo in-place so `scripts\launch.ps1` runs `uv run train.py` via the `ai-powered` CLI against Ollama `qwen2.5-coder:latest`, executed by a Windows Scheduled Task. Apply edits directly to disk.

# Fixed context
- Repo root: `path\to\autoresearch-win-rtx`
- Shell: PowerShell 7+ on Windows (RTX GPU host)
- Keep the current `autoresearch` pin unchanged in every manifest
- Do not modify anything under `.augment\`
- Do not create any `.md` or README files
- Never emit the em-dash character; use `-` or `--`

# Allowed file changes (no others)
1. Rewrite `scripts\launch.ps1`.
2. Create/edit at most ONE `ai-powered` config (`ai-powered.json` or `.ai-powered.toml` at repo root) ONLY if required to bind ai-powered to Ollama + Qwen.

# `scripts\launch.ps1` - implement exactly
Header: `#Requires -Version 5.1`, `Set-StrictMode -Version Latest`, `$ErrorActionPreference='Stop'`, non-interactive, `try/catch` with non-zero exit codes.

Parameters and defaults:
- `-Model` = `qwen2.5-coder:latest`
- `-OllamaHost` = `http://127.0.0.1:11434`
- `-RepoRoot` = resolved repo root of the script
- `-LogDir` = `"$env:HOMEDRIVE\myTech.Today\logs"`
- `-ScheduleTime` = `03:00`
- `-ScheduleFrequency` = `Daily` (also accept `Hourly`, `Weekly`)
- Switches: `-RegisterTask`, `-RunNow`, `-Unregister`, `-Update`

Preflight (every run, fail fast with actionable message):
- Ensure `uv`, `ollama`, `ai-powered` are on PATH; if missing install via `winget` (fallback `pipx`/`pip`/`npm` as appropriate) and re-verify executability before continuing.
- If nothing listens on `-OllamaHost`, start `ollama serve` detached and wait until ready.
- `ollama pull $Model` if not already present.
- Verify `$RepoRoot`, the project virtualenv, and `train.py` exist.

`-Update`: upgrade `uv`, `ollama`, `ai-powered`, and re-pull `$Model`. Do NOT touch the `autoresearch` pin.

Execution (only when `-RunNow` or invoked by the scheduled task):
- Set env: `OLLAMA_HOST=$OllamaHost`, `AI_POWERED_MODEL=$Model`.
- Run `uv run train.py` through `ai-powered` so the model mediates orchestration. Use only documented `ai-powered`/`uv` flags; do not invent flags.
- Stream stdout+stderr as JSON lines appended to `"$env:HOMEDRIVE\myTech.Today\logs\autoresearch.jsonl"`, with one timestamped run file per invocation in `$LogDir`; retain only the 190 newest files, delete older.

Scheduled Task on `-RegisterTask`:
- Name: `Autoresearch-Train`
- Action: `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File <abs path to launch.ps1> -RunNow`
- Trigger: at `-ScheduleTime` on `-ScheduleFrequency`
- Principal `RunLevel Highest`, `-StartWhenAvailable`, restart-on-failure
- Idempotent: if task exists, unregister then re-register
- `-Unregister`: remove the task and exit 0

# Acceptance criteria (all must hold)
- `scripts\launch.ps1` matches the spec above.
- `pwsh -File scripts\launch.ps1 -RegisterTask` registers `Autoresearch-Train` without error.
- `pwsh -File scripts\launch.ps1 -RunNow` passes preflight, runs the workload, writes a JSONL log under `$LogDir`.
- `pwsh -File scripts\launch.ps1 -Unregister` removes the task.
- `autoresearch` pinned version unchanged in every manifest.
- No files under `.augment\` modified; no new `.md` files; no em-dash anywhere in changed files.

# After applying edits, print only
1. Paths of files created or modified.
2. The three exact commands: (a) register, (b) run once, (c) unregister.
3. One line: either `PREFLIGHT OK` or the precise remediation command needed on this machine.
