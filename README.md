# autoresearch

> Convert your gaming PC into an autonomous AI researcher.

> This repository is a fork of [jsegov/autoresearch-win-rtx](https://github.com/jsegov/autoresearch-win-rtx) (Windows), which is itself a Windows fork of the original [karpathy/autoresearch](https://github.com/karpathy/autoresearch). On top of the Windows port, this fork adds a self-installing WPF GUI launcher (`scripts\launch.ps1`), Windows Task Scheduler integration, multi-provider AI routing via `ai-powered`, and tiered VRAM floors by architecture.

![teaser](progress.png)

*One day, frontier AI research used to be done by meat computers in between eating, sleeping, having other fun, and synchronizing once in a while using sound wave interconnect in the ritual of "group meeting". That era is long gone. Research is now entirely the domain of autonomous swarms of AI agents running across compute cluster megastructures in the skies. The agents claim that we are now in the 10,205th generation of the code base, in any case no one could tell if that's right or wrong as the "code" is now a self-modifying binary that has grown beyond human comprehension. This repo is the story of how it all began. -@karpathy, March 2026*.

The idea: give an AI agent a small but real LLM training setup and let it experiment autonomously overnight. It modifies the code, trains for 5 minutes, checks if the result improved, keeps or discards, and repeats. You wake up in the morning to a log of experiments and (hopefully) a better model. The training code here is a simplified single-GPU implementation of [nanochat](https://github.com/karpathy/nanochat). The core idea is that you're not touching any of the Python files like you normally would as a researcher. Instead, you are programming the `program.md` Markdown files that provide context to the AI agents and set up your autonomous research org. The default `program.md` in this repo is intentionally kept as a bare bones baseline, though it's obvious how one would iterate on it over time to find the "research org code" that achieves the fastest research progress, how you'd add more agents to the mix, etc. A bit more context on this project is here in this [tweet](https://x.com/karpathy/status/2029701092347630069) and [this tweet](https://x.com/karpathy/status/2031135152349524125).

## Fork scope

- Upstream source: [karpathy/autoresearch](https://github.com/karpathy/autoresearch) (original); [jsegov/autoresearch-win-rtx](https://github.com/jsegov/autoresearch-win-rtx) (direct Windows upstream).
- Primary objective: run natively on Windows with desktop consumer NVIDIA GPUs (Turing with >=8 GB VRAM, Ampere/Ada/Blackwell with >=10 GB VRAM), without unofficial Triton-on-Windows stacks.
- Scope of changes: compatibility and stability updates required for that target platform.
- The original Linux/H100-oriented path from upstream is removed in this fork and is not supported here.
- If you need the upstream Linux/H100 path, use [karpathy/autoresearch](https://github.com/karpathy/autoresearch).

## Quick Start: `launch.ps1` GUI (recommended local clone)

Clone the repo locally, inspect `scripts\launch.ps1`, and launch from your checkout. That gives you the same WPF GUI and the same canonical install path `%HOMEDRIVE%\myTech.Today\autoresearch-win-rtx-scheduled\`, but only after the launcher is already on your machine and visible for review. Any extra CLI arguments are forwarded verbatim to the launched script; pass `-NoGui` with explicit action switches for CLI-only use, and add `-SchedulerPolicy Unattended` when you want the registered task to run without an active desktop session (see [How `launch.ps1` Works](#how-launchps1-works)).

- **Local clone and launch:**

  ```powershell
  git clone https://github.com/mytech-today-now/autoresearch-win-rtx-scheduled.git
  cd autoresearch-win-rtx-scheduled
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\launch.ps1
  ```

See [How `launch.ps1` Works](#how-launchps1-works) for behavior details and [AI-Powered Features](#ai-powered-features) for provider/model configuration.

## How `launch.ps1` Works

- **Self-installing from a local launch.** On every invocation, `launch.ps1` checks whether it is running from the canonical install path `%HOMEDRIVE%\myTech.Today\autoresearch-win-rtx-scheduled\scripts\launch.ps1`. If not, it ensures `git` is on PATH (installing via `winget install --id Git.Git` if missing), clones (or `git pull --ff-only` updates) the repo into the canonical path, then re-launches itself from there forwarding all CLI arguments. The recommended first run is a local checkout so you can inspect the launcher before any self-install or update work happens.
- **Interactive WPF GUI (default).** With no action switch and without `-NoGui`, a WPF launcher window appears with radio buttons for the action (Preflight only, Run training now, Register scheduled task, Register task and run now, Unregister scheduled task, Update toolchain), an [AI Provider](#ai-powered-features) group (Ollama, OpenAI, Anthropic, Azure OpenAI) and a dependent model dropdown, an editable Ollama-host combo (enabled only for Ollama), a scheduler policy group with explicit interactive / idle-only / unattended choices, Azure endpoint/deployment fields (shown only for Azure), schedule frequency/time dropdowns (Weekly switches the time dropdown to weekday names), a masked `PasswordBox` for API keys, an "Enable Task Scheduler history" checkbox, and **OK / Cancel / Save as Defaults** buttons. Save-as-Defaults persists selections (excluding the API key) to `%HOMEDRIVE%\myTech.Today\autoresearch-win-rtx-scheduled\scripts\launch.json`. This file is human-readable JSON and is auto-created with current values on first run if missing; both the GUI and `-NoGui` CLI read it so the two surfaces behave identically (explicit CLI parameters always override stored values).
- **Headless / preflight modes.** Pass `-NoGui` with explicit action switches (`-RunNow`, `-RunLoop`, `-RegisterTask`, `-Unregister`, `-Update`) plus provider/model/schedule/policy parameters to run from the CLI without the WPF window. `-NoGui` with **no** action switch performs preflight only (verify tools, install if missing, ensure `.venv` via `uv sync`, start Ollama and pull the model when Ollama is selected), prints next-step hints, and exits 0. `-RegisterTask` and `-RunNow` can be combined to both schedule and run immediately. `-Unregister` removes the task and exits before preflight. The scheduled task now invokes the script in `-NoGui -TaskSupervisor` form; that supervisor launches the hidden `-RunLoop` child, records the child PID, redacted command line, and exit code in `%HOMEDRIVE%\myTech.Today\logs\autoresearch-task-launch.json`, and exits with the child code. `-SchedulerPolicy Unattended` uses S4U logon so the task can run without an active desktop session, while `-SchedulerPolicy IdleOnly` keeps the logged-on idle wait window and logs skips if the window expires.
- **`-Update` action.** Runs compatibility-checked updates in place: `uv self update` stays on the current minor line, `winget upgrade --id Ollama.Ollama --version <compatible patch>` stays on the current Ollama line when the provider is Ollama, and `npm install -g ai-powered@<package-lock pin>` installs the pinned CLI version. The launcher refreshes the session `PATH`, runs a smoke check after each step, rolls back a failed step before continuing, then restarts the Ollama daemon and re-pulls `-Model` when Ollama is selected. Combinable with `-RegisterTask` and/or `-RunNow`.
- **Per-run logs with pruning.** Each Python run writes to `%HOMEDRIVE%\myTech.Today\logs\autoresearch-run-<yyyyMMdd-HHmmss>.jsonl` (local time). Retention is hybrid: keep anything newer than 14 days, keep up to 25 older `autoresearch-run-*.jsonl` files, and always preserve the most recent successful run plus the most recent failure when available. The aggregate append-only log `%HOMEDRIVE%\myTech.Today\logs\autoresearch.jsonl` is never rotated, so it remains a companion diagnostic stream rather than the only record. Both surfaces capture timestamped `info`/`warn`/`error`/`stdout`/`stderr` JSON lines (UTC `ts`).
- **Scheduled task is a first-class object.** The task is registered via `Register-ScheduledTask` into the visible `\myTech.Today\` folder as `Autoresearch-Train`, with `-SchedulerPolicy` controlling whether the principal is interactive, idle-only, or unattended. `Interactive` and `IdleOnly` use `InteractiveToken`, while `Unattended` uses `S4U`; `IdleOnly` keeps the launcher-enforced 5-minute idle gate with a 1-hour wait window and logs the skip reason if the window expires. The task uses only GUI-roundtrippable `New-ScheduledTaskSettingsSet` options: `-StartWhenAvailable`, `-AllowStartIfOnBatteries`, `-DontStopIfGoingOnBatteries`, `-RestartCount 3`, `-RestartInterval 5m`, `-MultipleInstances IgnoreNew`. `-ScheduleTime` is polymorphic: in `Hourly` mode it is a minute-of-hour offset (`':00'`..`':50'` in 10-minute steps, default `':00'`); in `Daily` mode it is a local 24-hour time-of-day (`'00:00'`..`'23:45'` in 15-minute steps, default `'18:00'`); in `Weekly` mode it is a weekday name (`'Sunday'`..`'Saturday'`, default `'Sunday'`) and the trigger fires that day at 03:00 local. The GUI repurposes the time dropdown and its label to match. The task is not hidden, is fully editable in `taskschd.msc` (no greyed-out controls), and the trigger/action/principal reflect the GUI/CLI selections. Task history is enabled by default via `wevtutil set-log Microsoft-Windows-TaskScheduler/Operational /enabled:true` (requires elevation; a warning is logged if elevation is unavailable).

### `launch.ps1` parameter reference

| Parameter | Type / values | Default | Purpose |
| --- | --- | --- | --- |
| `-Provider` | `ollama` \| `openai` \| `anthropic` \| `azure` | `ollama` | Selects the AI backend; exported as `AI_PROVIDER` (`ollama` maps to `custom` for `ai-powered`). |
| `-Model` | string | `qwen2.5-coder:latest` | Model tag/name; exported as `AI_POWERED_MODEL` and `AI_MODEL`. |
| `-OllamaHost` | URL | `http://127.0.0.1:11434` | Ollama daemon base URL; exported as `OLLAMA_HOST`. |
| `-ApiKey` | string | _(empty)_ | Provider key; mapped to `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, or `AZURE_OPENAI_API_KEY`. Never persisted. |
| `-AzureEndpoint` / `-AzureDeployment` | string | _(empty)_ | Azure-only; exported as `AZURE_OPENAI_ENDPOINT` / `AZURE_OPENAI_DEPLOYMENT`. |
| `-RepoRoot` | path | parent of `scripts\` | Repo containing `train.py`; `.venv` is auto-created via `uv sync` if missing. |
| `-LogDir` | path | `%HOMEDRIVE%\myTech.Today\logs` | Destination for aggregate + per-run JSONL logs. Hybrid pruning is controlled by `-LogRetentionDays` and `-LogRetentionCount`. |
| `-LogRetentionDays` | number | `14` | Keeps recent per-run logs for this many days before count-based rotation applies. |
| `-LogRetentionCount` | number | `25` | Keeps this many older per-run logs, while always preserving the latest success and latest failure. |
| `-ScheduleFrequency` | `Hourly` \| `Daily` \| `Weekly` | `Daily` | Trigger cadence for `-RegisterTask`. |
| `-ScheduleTime` | depends on `-ScheduleFrequency` (see [Scheduling](#scheduling)) | frequency-specific (`':00'` / `'18:00'` / `'Sunday'`) | Polymorphic schedule slot; validated against the active frequency at runtime. |
| `-SchedulerPolicy` | `Interactive` \| `IdleOnly` \| `Unattended` | `IdleOnly` | Chooses the task logon mode and idle behavior. |
| `-RegisterTask` / `-RunNow` / `-Unregister` / `-Update` | switch | off | Action selectors; see above. |
| `-NoGui` | switch | off | Skip the WPF launcher (required for unattended/scheduled use). |

### Scheduling

The meaning, allowed value set, and default of `-ScheduleTime` change with `-ScheduleFrequency`. The GUI's time dropdown and its label re-bind whenever the frequency selector changes; invalid CLI values raise an error listing the allowed set.

| Frequency | `-ScheduleTime` meaning | Allowed values | Default |
| --- | --- | --- | --- |
| `Hourly` | Minute-of-the-hour offset | `':00'`, `':10'`, `':20'`, `':30'`, `':40'`, `':50'` (10-minute steps) | `':00'` |
| `Daily`  | Local 24-hour time-of-day | `'00:00'`, `'00:15'`, `'00:30'`, ... `'23:45'` (15-minute steps; 96 values) | `'18:00'` |
| `Weekly` | Weekday name | `'Sunday'`, `'Monday'`, `'Tuesday'`, `'Wednesday'`, `'Thursday'`, `'Friday'`, `'Saturday'` | `'Sunday'` |

CLI examples:

```powershell
pwsh -File .\scripts\launch.ps1 -NoGui -RegisterTask -ScheduleFrequency Hourly -ScheduleTime ':30'
pwsh -File .\scripts\launch.ps1 -NoGui -RegisterTask -ScheduleFrequency Daily  -ScheduleTime '18:00'
pwsh -File .\scripts\launch.ps1 -NoGui -RegisterTask -ScheduleFrequency Weekly -ScheduleTime 'Wednesday' -SchedulerPolicy Unattended
```

### Scheduler policy

| Policy | Logon mode | Idle behavior | Best for |
| --- | --- | --- | --- |
| `Interactive` | `InteractiveToken` | No idle wait window | Attended runs where a signed-in session is required but idle is not. |
| `IdleOnly` | `InteractiveToken` | Launcher waits up to 1 hour for 5 minutes of idle time and logs the skip reason if the window expires. | Current attended-workstation behavior. |
| `Unattended` | `S4U` | No idle wait window | True overnight / headless use without an active desktop session. |

## AI-Powered Features

The repository routes all AI orchestration through the [`ai-powered`](https://www.npmjs.com/package/ai-powered) npm CLI (pinned in `package.json` and configured by `ai-powered.json` at the repo root). `train.py` is launched as `uv run train.py` so the model mediates orchestration via `ai-powered`'s SDK bindings.

Supported providers and the GUI/CLI surface:

| Provider | `-Provider` value | GUI model defaults | Required credentials |
| --- | --- | --- | --- |
| Ollama (local) | `ollama` | `qwen2.5-coder:latest`, `qwen2.5-coder:7b`, `qwen2.5-coder:3b`, `llama3.1:8b`, `llama3.2:3b` | none (uses `-OllamaHost`, default `http://127.0.0.1:11434`) |
| OpenAI | `openai` | `gpt-4o`, `gpt-4o-mini`, `gpt-4-turbo`, `o1`, `o1-mini` | `OPENAI_API_KEY` (set from `-ApiKey` or GUI `PasswordBox`) |
| Anthropic | `anthropic` | `claude-3-5-sonnet-latest`, `claude-3-5-haiku-latest`, `claude-3-opus-latest` | `ANTHROPIC_API_KEY` |
| Azure OpenAI | `azure` | `gpt-4o`, `gpt-4o-mini`, `gpt-4-turbo` | `AZURE_OPENAI_API_KEY`, plus `-AzureEndpoint` / `-AzureDeployment` |

The selected provider/model is exported to the child process as `AI_PROVIDER`, `AI_POWERED_MODEL`, and `AI_MODEL`. For Ollama, `OLLAMA_HOST` is also exported and the script will install/start the local `ollama` daemon and `ollama pull` the requested model during preflight. For non-Ollama providers the Ollama preflight steps are skipped.

API keys are **never persisted** to `launch.json`; only the provider, model, host, schedule, log directory, and Azure endpoint/deployment selections are saved. Supply the API key via the masked GUI field or the `-ApiKey` parameter at invocation time. See [How `launch.ps1` Works](#how-launchps1-works) for full launcher behavior.

## How it works

The repo is deliberately kept small and only really has three files that matter:

- **`prepare.py`** — fixed constants, one-time data prep (downloads TinyStories data, trains a BPE tokenizer), and runtime utilities (dataloader, evaluation).
- **`train.py`** — the single file the agent edits. Contains the full GPT model, optimizer (Muon + AdamW), and training loop. Everything is fair game: architecture, hyperparameters, optimizer, batch size, etc. **This file is edited and iterated on by the agent**.
- **Resumable checkpoints.** Each run writes to its own artifact directory under `artifacts/checkpoints/run-<id>/`, with `checkpoint.pt` for model/optimizer/step state and `metadata.json` for run metadata. To resume a compatible run, pass `--resume-from` with either the run directory or the checkpoint file, for example `uv run train.py --resume-from artifacts/checkpoints/run-20260907-123456-12345-abcd1234`. Fresh runs always get a new run directory, so concurrent runs do not overwrite one another.
- **`program.md`** — baseline instructions for one agent. Point your agent here and let it go. **This file is edited and iterated on by the human**.

By design, training runs for a **fixed 5-minute time budget** (wall clock, excluding startup/compilation), regardless of the details of your compute. The metric is **val_bpb** (validation bits per byte) — lower is better, and vocab-size-independent so architectural changes are fairly compared.

If you are new to neural networks, this ["Dummy's Guide"](https://x.com/hooeem/status/2030720614752039185) looks pretty good for a lot more context.

## Quick start (PowerShell)

**Requirements:** A single NVIDIA GPU, Python 3.10+, [uv](https://docs.astral.sh/uv/).

- Single runtime path uses PyTorch SDPA attention and eager execution (no FA3/`torch.compile` fast path).
- Native Windows support targets desktop consumer GPUs with a tiered VRAM policy (Turing >=8 GB, Ampere/Ada/Blackwell >=10 GB), official PyTorch CUDA wheels, and SDPA attention.
- Default dataset is now TinyStories GPT-4 clean for practical consumer-GPU setup.

```powershell

# 1. Install uv project manager (if you don't already have it)
winget install --id=astral-sh.uv -e

# 2. Install dependencies
uv sync

# 3. Download data and train tokenizer (one-time)
#    Default dataset: TinyStories GPT-4 clean
uv run prepare.py

# 4. Manually run a single training experiment (~5 min)
uv run train.py
```

Quick validation run (recommended after setup):

```powershell
uv run train.py --smoke-test
```

## PowerShell test bootstrap

`tests/launch.Tests.ps1` now bootstraps Pester 5.0.0 automatically when the
module is missing. If you want to provision the dependency ahead of time, use
the repo-owned setup script from the same shell family you plan to use for the
tests:

```powershell
# Windows PowerShell 5.1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-pester.ps1

# PowerShell 7+
pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/install-pester.ps1
```

After that, run the test file directly with the same host:

```powershell
powershell -NoProfile -File tests/launch.Tests.ps1
pwsh -NoProfile -File tests/launch.Tests.ps1
```

You can also run the same suite through npm with `npm run test:powershell`,
or include it in the standard aggregated check with `npm test`.

If the module is still wrong or missing, the test file now prints a setup
message that names the required version and the exact install command.

If the above commands all work ok, your setup is working and you can go into autonomous research mode.

## Running the agent

Simply spin up your Claude/Codex or whatever you want in this repo (and disable all permissions), then you can prompt something like:

```
Hi have a look at program.md and let's kick off a new experiment! let's do the setup first.
```

The `program.md` file is essentially a super lightweight "skill".

## Project structure

```
prepare.py      — constants, data prep + runtime utilities (do not modify)
train.py        — model, optimizer, training loop (agent modifies this)
program.md      — agent instructions
pyproject.toml  — dependencies
```

## Design choices

- **Single file to modify.** The agent only touches `train.py`. This keeps the scope manageable and diffs reviewable.
- **Fixed time budget.** Training always runs for exactly 5 minutes, regardless of your specific platform. This means you can expect approx 12 experiments/hour and approx 100 experiments while you sleep. There are two upsides of this design decision. First, this makes experiments directly comparable regardless of what the agent changes (model size, batch size, architecture, etc). Second, this means that autoresearch will find the most optimal model for your platform in that time budget. The downside is that your runs (and results) become not comparable to other people running on other compute platforms.
- **Self-contained.** No external dependencies beyond PyTorch and a few small packages. No distributed training, no complex configs. One GPU, one file, one metric.

## Platform support

This fork's platform policy is explicit and tiered.

| Architecture | Minimum VRAM floor | Supported desktop consumer GPUs |
| --- | --- | --- |
| Turing | `>=8 GB` | `RTX 2060 12GB`, `RTX 2060 SUPER 8GB`, `RTX 2070 8GB`, `RTX 2070 SUPER 8GB`, `RTX 2080 8GB`, `RTX 2080 SUPER 8GB`, `RTX 2080 Ti 11GB` |
| Ampere | `>=10 GB` | `RTX 3060 12GB`, `RTX 3080 10GB`, `RTX 3080 12GB`, `RTX 3080 Ti 12GB`, `RTX 3090 24GB`, `RTX 3090 Ti 24GB` |
| Ada | `>=10 GB` | `RTX 4060 Ti 16GB`, `RTX 4070 12GB`, `RTX 4070 SUPER 12GB`, `RTX 4070 Ti 12GB`, `RTX 4070 Ti SUPER 16GB`, `RTX 4080 16GB`, `RTX 4080 SUPER 16GB`, `RTX 4090 24GB` |
| Blackwell | `>=10 GB` | `RTX 5060 Ti 16GB`, `RTX 5070 12GB`, `RTX 5070 Ti 16GB`, `RTX 5080 16GB`, `RTX 5090 32GB` |
- Desktop only: laptop GPUs are not officially supported due to wide power and thermal variance.
- Floor policy: Turing desktop GPUs are supported at >=8 GB VRAM; Ampere/Ada/Blackwell desktop GPUs require >=10 GB VRAM.
- `RTX 2060 6GB` remains out of matrix support due to VRAM floor.
- Runtime path is intentionally unified across platforms: PyTorch SDPA attention + eager optimizer steps.
- Runtime adaptation is profile-driven: compute capability, BF16/TF32 support, OS, and VRAM tier determine candidate batch sizes and checkpointing strategy.
- Supported consumer profiles run a short eager-mode autotune pass and cache the selected candidate per GPU/runtime fingerprint.
- Autotune env controls: `AUTORESEARCH_DISABLE_AUTOTUNE=1` skips probing; `AUTORESEARCH_AUTOTUNE_REFRESH=1` refreshes the cached decision.
- Tested hardware in this repo remains RTX 3080 10 GB on Windows. Other listed SKUs are matrix-supported but may be less field-tested here.
- Non-goals for this fork include FA3/H100-specialized paths, unofficial Triton-for-Windows stacks, AMD/ROCm, Apple Metal, and multi-GPU training.
- Default dataset is `karpathy/tinystories_gpt4_clean` for consumer-GPU practicality.

## Smaller compute and notable forks

Seeing as there seems to be a lot of interest in tinkering with autoresearch on much smaller compute platforms than an H100, a few extra words. If you're going to try running autoresearch on smaller computers (Macbooks etc.), I'd recommend one of the forks below. On top of this, here are some recommendations for how to tune the defaults for much smaller models for aspiring forks:

1. To get half-decent results I'd use a dataset with a lot less entropy, e.g. this [TinyStories dataset](https://huggingface.co/datasets/karpathy/tinystories-gpt4-clean). These are GPT-4 generated short stories. Because the data is a lot narrower in scope, you will see reasonable results with a lot smaller models (if you try to sample from them after training).
2. You might experiment with decreasing `vocab_size`, e.g. from 8192 down to 4096, 2048, 1024, or even - simply byte-level tokenizer with 256 possibly bytes after utf-8 encoding.
3. In `prepare.py`, you'll want to lower `MAX_SEQ_LEN` a lot, depending on the computer even down to 256 etc. As you lower `MAX_SEQ_LEN`, you may want to experiment with increasing `DEVICE_BATCH_SIZE` in `train.py` slightly to compensate. The number of tokens per fwd/bwd pass is the product of these two.
4. Also in `prepare.py`, you'll want to decrease `EVAL_TOKENS` so that your validation loss is evaluated on a lot less data.
5. In `train.py`, the primary single knob that controls model complexity is the `DEPTH` (default 8, here). A lot of variables are just functions of this, so e.g. lower it down to e.g. 4.
6. You'll want to most likely use `WINDOW_PATTERN` of just "L", because "SSSL" uses alternating banded attention pattern that may be very inefficient for you. Try it.
7. You'll want to lower `TOTAL_BATCH_SIZE` a lot, but keep it powers of 2, e.g. down to `2**14` (~16K) or so even, hard to tell.

I think these would be the reasonable hyperparameters to play with. Ask your favorite coding agent for help and copy paste them this guide, as well as the full source code.

### Notable forks

- [miolini/autoresearch-macos](https://github.com/miolini/autoresearch-macos) (MacOS)
- [trevin-creator/autoresearch-mlx](https://github.com/trevin-creator/autoresearch-mlx) (MacOS)
- [jsegov/autoresearch-win-rtx](https://github.com/jsegov/autoresearch-win-rtx) (Windows)
- [andyluo7/autoresearch](https://github.com/andyluo7/autoresearch) (AMD)

## License

MIT
