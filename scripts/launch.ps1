#Requires -Version 5.1
# Local Quick Start. Clone the repository, review this script, then run it
# from the checkout. The launcher will keep using its canonical install path
# for subsequent runs and forwards any CLI arguments verbatim.
#   PowerShell:
#     git clone https://github.com/mytech-today-now/autoresearch-win-rtx-scheduled.git
#     Set-Location autoresearch-win-rtx-scheduled
#     powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\launch.ps1
<#
.SYNOPSIS
    Runs `uv run train.py` via the `ai-powered` CLI against a selected AI
    provider, optionally executed by a Windows Scheduled Task. Self-installs
    to %HOMEDRIVE%\myTech.Today\autoresearch-win-rtx-scheduled\ when invoked
    from anywhere else. Presents a WPF GUI
    by default; pass -NoGui for unattended/headless invocations. The GUI and
    CLI now expose an explicit scheduler policy so the task can be registered
    as interactive, idle-only, or unattended.

.DESCRIPTION
    Performs preflight checks (PATH, dependencies, Ollama daemon, model),
    streams stdout/stderr as JSON lines to a per-invocation log, and manages
    a Scheduled Task named Autoresearch-Train. Pure non-interactive workflow.
    Compatible with Windows PowerShell 5.1 and PowerShell 7+. Examples use
    pwsh when available; replace it with powershell.exe when running under
    Windows PowerShell 5.1.

    Persisted launcher defaults are human-readable, non-secret convenience
    settings stored per user under %LOCALAPPDATA%\myTech.Today\autoresearch-
    win-rtx-scheduled\launch.json. The file contains provider, model, Ollama
    host, Azure endpoint/deployment, log directory, schedule, and scheduler
    policy values only. It is not encrypted; the API key is never written.
    A legacy launch.json beside the canonical script is read for compatibility
    but is never written by the current launcher.

    USAGE OVERVIEW
    --------------
    The script has five mutually independent ACTION switches. If none are
    supplied, the script only runs preflight and prints usage hints; it will
    NOT train and will NOT create a scheduled task.

      Switch          Effect
      --------------  ----------------------------------------------------------
      (none)          Preflight only. Prints next-step hints and exits 0.
      -RunNow         Runs `uv run train.py` once, in the foreground.
                      Does NOT register a scheduled task.
      -RunLoop        Runs the autoresearch experiment loop described in
                      program.md. Requires a clean source checkout and runs
                      each edit, commit, and training run in an isolated
                      experiment worktree, staging only train.py, until
                      -MaxLoopMinutes elapses or the consecutive failure
                      threshold is reached.
      -RegisterTask   Creates/replaces the `Autoresearch-Train` scheduled
                      task. Does NOT run training in this invocation. The
                      task's action drives -TaskSupervisor, which launches
                      the hidden -RunLoop child, not a single -RunNow.
      -Unregister     Removes the scheduled task if present and exits.
      -Update         Upgrades uv, Ollama, ai-powered, and re-pulls the model.

    Combine -RegisterTask with -RunNow or -RunLoop to both schedule the
    task AND run training (or the loop) immediately in the same invocation.

.PARAMETER Model
    Ollama model tag used by `ai-powered` for code/research mediation. Must
    either already exist locally or be pullable from the Ollama registry; the
    preflight step will `ollama pull` it if missing. Exported to the child
    process as AI_POWERED_MODEL and AI_MODEL.
    Default: 'qwen2.5-coder:latest'.

    Example:
        pwsh -File .\scripts\launch.ps1 -RunNow -Model 'qwen2.5-coder:7b'

.PARAMETER OllamaHost
    Base URL of the Ollama HTTP daemon. Used for health probes
    (`/api/tags`), exported as OLLAMA_HOST to child processes, and consulted
    when starting `ollama serve` if the daemon is not already listening.
    Default: 'http://127.0.0.1:11434'.

    Example (point at a remote Ollama box on the LAN):
        pwsh -File .\scripts\launch.ps1 -RunNow `
             -OllamaHost 'http://192.168.1.10:11434'

.PARAMETER RepoRoot
    Absolute path to the autoresearch repo root (the directory containing
    `train.py` and `pyproject.toml`). If omitted, it defaults to the parent
    of the `scripts\` directory containing this script. The path is
    normalized and any trailing slash is stripped. The repo's `.venv` will
    be created via `uv sync` during preflight if missing.

    Example:
        pwsh -File .\scripts\launch.ps1 -RunNow `
             -RepoRoot 'G:\_kyle\temp_documents\GitHub\autoresearch-win-rtx'

.PARAMETER LogDir
    Directory where logs are written. Created if missing. Two log surfaces
    are produced:
      * <LogDir>\autoresearch.jsonl                  (append-only aggregate)
      * <LogDir>\autoresearch-run-<UTC-stamp>.jsonl  (one per invocation)
    Per-run files are retained with a hybrid policy: keep anything newer
    than `-LogRetentionDays`, keep up to `-LogRetentionCount` older files,
    and always preserve the most recent success and most recent failure when
    they exist. Before deleting any eligible files, the aggregate log receives
    a pruning plan; a completion summary is appended after the delete
    attempts. The aggregate log is never rotated.
    Default: "$env:HOMEDRIVE\myTech.Today\logs" (typically C:\myTech.Today\logs).

    Example:
        pwsh -File .\scripts\launch.ps1 -RunNow -LogDir 'D:\logs\autoresearch'

.PARAMETER LogRetentionCount
    Number of older per-run logs to keep after the age window has been
    honored. This still preserves the most recent success and most recent
    failure when present.
    Default: 25.

.PARAMETER LogRetentionDays
    Age window, in days, during which per-run logs are always retained.
    Default: 14.

.PARAMETER ScheduleTime
    Polymorphic schedule slot whose meaning depends on -ScheduleFrequency:
      * Hourly  - minute-of-hour offset: ':00', ':10', ':20', ':30', ':40',
                  ':50'. Default ':00'.
      * Daily   - local 24-hour time-of-day '00:00'..'23:45' in 15-minute
                  steps (96 values). Default '18:00'.
      * Weekly  - weekday name 'Sunday'..'Saturday'. Default 'Sunday'.
    Only consulted when -RegisterTask is supplied. Validated at runtime by
    Test-ScheduleTime; invalid values raise an error listing the allowed
    set for the active frequency.

    Example (every hour at HH:30 local):
        pwsh -File .\scripts\launch.ps1 -RegisterTask `
             -ScheduleFrequency Hourly -ScheduleTime ':30'

.PARAMETER ScheduleFrequency
    Trigger cadence for the scheduled task. Only consulted when
    -RegisterTask is supplied. Allowed values:
      * Hourly  - Fires at HH:<minute> every hour (minute from -ScheduleTime).
      * Daily   - Fires once a day at -ScheduleTime ('HH:mm').
      * Weekly  - Fires on -ScheduleTime (weekday name) at 03:00 local.
    Default: 'Daily'.

    Example (every hour at the top of the hour):
        pwsh -File .\scripts\launch.ps1 -RegisterTask `
             -ScheduleFrequency Hourly -ScheduleTime ':00'

.PARAMETER SchedulerPolicy
    Task policy for scheduled launches. The selected policy is shown in the
    GUI and recorded in the task description and logs before registration.
    Allowed values:
      * Interactive - Current user, interactive logon, no idle wait.
      * IdleOnly    - Current user, interactive logon, launcher waits up to
                      1 hour for 5 minutes of idle time and logs the reason
                      if the wait window expires.
      * Unattended  - Current user, S4U logon, no active desktop session
                      required.
    Default: 'IdleOnly'.

    AI-generated training code requires an interactive review before execution.
    IdleOnly and Unattended loops that use AI edits fail closed; use -NoAiEdit
    for an unattended run of the checked-in training code.

    Example (register an unattended overnight task):
        pwsh -File .\scripts\launch.ps1 -NoGui -RegisterTask `
             -SchedulerPolicy Unattended

.PARAMETER RegisterTask
    Switch. When set, creates (or replaces) a Windows scheduled task named
    `Autoresearch-Train` that uses a first-class `-TaskSupervisor`
    invocation on the configured trigger. The selected scheduler policy
    controls whether the task is interactive, idle-only, or unattended. The
    registered task action launches the hidden `-RunLoop` child, records its
    PID/command/exit code, and mirrors the child exit status back to Task
    Scheduler. An existing task with the same name is unregistered first.

    Example (schedule daily at 03:00 - the defaults):
        pwsh -File .\scripts\launch.ps1 -RegisterTask

.PARAMETER RunNow
    Switch. When set, runs `uv run train.py` once in the foreground after
    preflight. Stdout and stderr are streamed line-by-line into the JSONL
    log files. The script's exit code matches `uv run train.py`'s exit code.
    This switch does NOT register a scheduled task.

    Example (run a single training experiment now):
        pwsh -File .\scripts\launch.ps1 -RunNow

.PARAMETER Unregister
    Switch. When set, removes the `Autoresearch-Train` scheduled task if it
    exists and exits immediately. Preflight is skipped. Safe to run when no
    task is present (logs an info line and exits 0).

    Example:
        pwsh -File .\scripts\launch.ps1 -Unregister

.PARAMETER Update
    Switch. When set, upgrades the toolchain in place:
      * `uv self update <compatible patch on the current minor line>`
      * `winget upgrade --id Ollama.Ollama --version <compatible patch>` (silent)
      * `npm install -g ai-powered@<pinned package-lock version>`
    The launcher records exact before/after versions, runs a smoke check after
    each step, and rolls back a failed step before continuing. Then it restarts
    the Ollama daemon if needed and re-pulls -Model. Can be combined with
    -RegisterTask and/or -RunNow.

    Example (update everything, then run training once):
        pwsh -File .\scripts\launch.ps1 -Update -RunNow

.PARAMETER Debug
    Switch. When set, writes verbose 'debug'-level JSON records into the
    aggregate and per-run log files capturing:
      * Each preflight step (tool resolution, install attempts and outcomes,
        Ollama probe results, model catalog inspection, repo layout checks).
      * Every GUI state transition (XAML load, control resolution, frequency
        selection, time list rebuilds, default application, snapshot collection).
      * Any exception raised inside a WPF event handler (which WPF would
        otherwise silently swallow), including stack trace.
    Debug records are also echoed to the console in DarkCyan. Has no other
    effect on script behaviour.

    Example:
        pwsh -File .\scripts\launch.ps1 -Debug

.PARAMETER NoBootstrap
    Switch. When set, skips the canonical self-install/bootstrap handoff and
    keeps running from the current checkout without cloning or relaunching.
    The `AUTORESEARCH_DOT_SOURCE_ONLY=1` environment variable enables
    import-only mode for test harnesses and returns immediately after loading
    helper functions.

.PARAMETER TaskSupervisor
    Internal switch used by the scheduled task action. Launches the hidden
    `-RunLoop` child process, records the child PID, a redacted command line,
    and exit code in the task launch state file, and exits with the child's
    status so Task Scheduler can see the real result.

.PARAMETER MaxConsecutiveIterationFailures
    Maximum number of consecutive failed loop iterations before the loop
    stops with exit code 4. A successful `keep` or valid `discard` resets the
    consecutive-failure count. Failed retries wait 5 seconds, doubling up to
    a 60 second cap. Valid range: 1..1000. Default: 5.

    Example:
        pwsh -File .\scripts\launch.ps1 -NoGui -RunLoop `
            -MaxConsecutiveIterationFailures 3

.EXAMPLE
    pwsh -File .\scripts\launch.ps1
    # Preflight only. Verifies uv, ollama, ai-powered, the model, and the
    # repo layout, then prints next-step hints. Does not train, does not
    # schedule anything.

.EXAMPLE
    pwsh -File .\scripts\launch.ps1 -RunNow
    # Run a single `uv run train.py` experiment right now using the
    # defaults (qwen2.5-coder:latest against http://127.0.0.1:11434).

.EXAMPLE
    pwsh -File .\scripts\launch.ps1 -RegisterTask
    # Register the Autoresearch-Train scheduled task to fire daily at
    # 03:00 local time with the default idle-only launcher policy.

.EXAMPLE
    pwsh -File .\scripts\launch.ps1 -RegisterTask -RunNow
    # Schedule the daily task AND run one training experiment immediately.

.EXAMPLE
    pwsh -File .\scripts\launch.ps1 -RegisterTask `
         -ScheduleFrequency Hourly -ScheduleTime ':30'
    # Run every hour at HH:30 local.

.EXAMPLE
    pwsh -File .\scripts\launch.ps1 -RegisterTask `
         -ScheduleFrequency Weekly -ScheduleTime 'Wednesday' `
         -SchedulerPolicy Unattended
    # Run weekly on Wednesdays at 03:00 local without requiring an active
    # desktop session.

.EXAMPLE
    pwsh -File .\scripts\launch.ps1 -RunNow `
         -Model 'qwen2.5-coder:7b' `
         -OllamaHost 'http://192.168.1.10:11434' `
         -LogDir 'D:\logs\autoresearch'
    # Run once against a remote Ollama instance with a smaller model and
    # a custom log directory.

.EXAMPLE
    pwsh -File .\scripts\launch.ps1 -Update
    # Upgrade uv, Ollama, and ai-powered, and re-pull the default model.
    # Does not train and does not modify the scheduled task.

.EXAMPLE
    pwsh -File .\scripts\launch.ps1 -Unregister
    # Remove the Autoresearch-Train scheduled task and exit.

.NOTES
    Exit codes:
      0  Success (preflight OK, or workload exited 0, or task registered).
      Non-zero  Either preflight failed or `uv run train.py` exited non-zero;
                in -RunNow mode the script propagates the workload's exit code;
                in -TaskSupervisor mode the script propagates the hidden
                child exit code. A loop returns 4 when its consecutive
                iteration-failure threshold is reached or a finite loop ends
                without a completed experiment. Git verification failures
                return 1; uncontained process failures return 3.

    Logs:
      Aggregate JSONL: <LogDir>\autoresearch.jsonl
      Per-run JSONL:   <LogDir>\autoresearch-run-<UTC-stamp>.jsonl
      Per-run files are pruned with a hybrid age/count policy that always
      keeps the newest success and newest failure when present.

    Scheduled task:
      Name:        Autoresearch-Train
      Action:      pwsh.exe when available, otherwise powershell.exe
                   -NoProfile -ExecutionPolicy Bypass -File launch.ps1
                   -NoGui -TaskSupervisor ...
                   The supervisor launches the hidden `-RunLoop` child and
                   writes `%HOMEDRIVE%\myTech.Today\logs\autoresearch-task-launch.json`
                   using the same selected PowerShell executable.
                   with the child PID, redacted command line, and exit code
                   before exiting with the child's status so Task Scheduler
                   sees the real result.
      Workload:    The hidden child drives the autoresearch loop from
                   program.md: it requires a clean source checkout, edits and
                   trains in temporary experiment worktrees, stages only
                   train.py, parses val_bpb/peak_vram_mb, and appends a row to
                   results.tsv. Improved commits stay on the experiment
                   branch; a discard rewinds only that branch. The source
                   checkout is not committed or reset. The loop continues until
                   -MaxLoopMinutes elapses (default 0 = forever) or the
                   process is killed. It also stops with exit code 4 after
                   -MaxConsecutiveIterationFailures consecutive failed
                   iterations (default 5). Failed retries use 5, 10, 20, 40,
                   then 60 second delays, capped at 60 seconds.
      Policy:      Interactive, IdleOnly, or Unattended
                   - Interactive = current user, logged-on session only.
                   - IdleOnly = current user, launcher waits up to 1 hour for
                     5 minutes of idle time and logs the skip reason if the
                     window expires.
                   - Unattended = current user, S4U logon, no active desktop
                     session required.
      Principal:   current user, highest run level, with the selected
                   logon mode reflected in the task XML.
      Settings:    StartWhenAvailable, AllowStartIfOnBatteries,
                   DontStopIfGoingOnBatteries, RestartCount=3,
                   RestartInterval=5m, MultipleInstances=IgnoreNew
      Idle policy: The launcher logs explicit skip reasons when IdleOnly is
                   selected and the computer never reaches the configured
                   idle window.

    Requirements:
      Windows PowerShell 5.1 or PowerShell 7+, internet access for the
      first preflight (to install missing tools and pull the model).
#>
param(
    [ValidateSet('ollama', 'openai', 'anthropic', 'azure')]
    [string]$Provider = 'ollama',
    [string]$Model = 'qwen2.5-coder:latest',
    [string]$OllamaHost = 'http://127.0.0.1:11434',
    [string]$ApiKey,
    [string]$AzureEndpoint,
    [string]$AzureDeployment,
    [string]$RepoRoot,
    [string]$LogDir = "$env:HOMEDRIVE\myTech.Today\logs",
    [Alias('LogRetention')]
    [ValidateRange(0, 2147483647)]
    [int]$LogRetentionCount = 25,
    [ValidateRange(0, 36500)]
    [int]$LogRetentionDays = 14,
    [string]$ScheduleTime,
    [ValidateSet('Hourly', 'Daily', 'Weekly')]
    [string]$ScheduleFrequency = 'Daily',
    [ValidateSet('Interactive', 'IdleOnly', 'Unattended')]
    [string]$SchedulerPolicy = 'IdleOnly',
    [switch]$RegisterTask,
    [switch]$RunNow,
    [switch]$RunLoop,
    [ValidateRange(0, 2147483647)]
    [int]$MaxLoopMinutes = 0,
    [ValidateRange(1, 1000)]
    [int]$MaxConsecutiveIterationFailures = 5,
    [int]$PerRunTimeoutMinutes = 10,
    [switch]$NoAiEdit,
    [switch]$Unregister,
    [switch]$Update,
    [switch]$NoBootstrap,
    [switch]$TaskSupervisor,
    [switch]$NoGui,
    [switch]$Debug
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ConfirmPreference = 'None'

$Script:TaskName = 'Autoresearch-Train'
$Script:TaskPath = '\myTech.Today\'
$Script:ScheduledTaskAuthor = 'myTech.Today (sales@mytech.today)'
$Script:InstallRoot = Join-Path $env:HOMEDRIVE 'myTech.Today'
$Script:CanonicalRepo = Join-Path $Script:InstallRoot 'autoresearch-win-rtx-scheduled'
$Script:CanonicalScript = Join-Path $Script:CanonicalRepo 'scripts\launch.ps1'
$Script:LegacyDefaultsPath = Join-Path (Split-Path -Parent $Script:CanonicalScript) 'launch.json'
$Script:DefaultsPath = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
    Join-Path $env:LOCALAPPDATA 'myTech.Today\autoresearch-win-rtx-scheduled\launch.json'
} else {
    $Script:LegacyDefaultsPath
}
$Script:RepoUrl = 'https://github.com/mytech-today-now/autoresearch-win-rtx-scheduled.git'
# scripts/bump-and-push.ps1 defines main as the release branch and pushes to origin/main.
$Script:BootstrapBranch = 'main'
$Script:AggregateLog = Join-Path $LogDir 'autoresearch.jsonl'
$Script:RunLogPath = $null
$Script:AutoresearchLoopLock = $null
$Script:TaskLaunchStatePath = Join-Path $LogDir 'autoresearch-task-launch.json'
$Script:LauncherAclStatus = @{}
$Script:LauncherAclFailure = $null
$Script:LogRetentionCount = $LogRetentionCount
$Script:LogRetentionDays = $LogRetentionDays
$Script:DebugEnabled = [bool]$Debug

function ConvertTo-ForwardArgs {
    param([System.Collections.IDictionary]$Bound)
    $out = @()
    foreach ($k in $Bound.Keys) {
        $v = $Bound[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) {
            if ($v.IsPresent) { $out += "-$k" }
        } elseif ($null -ne $v -and "$v" -ne '') {
            $out += "-$k"; $out += "$v"
        }
    }
    return ,$out
}

function ConvertTo-SingleQuotedLiteral {
    param([Parameter(Mandatory)][string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

function Format-CommandLineArgumentList {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $parts = foreach ($arg in $Arguments) {
        if ($arg -match '^-{1,2}[A-Za-z]') {
            $arg
        } else {
            ConvertTo-SingleQuotedLiteral $arg
        }
    }
    return ($parts -join ' ')
}

function Format-CommandLine {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $quotedFilePath = ConvertTo-SingleQuotedLiteral $FilePath
    $argText = Format-CommandLineArgumentList -Arguments $Arguments
    if ([string]::IsNullOrWhiteSpace($argText)) { return $quotedFilePath }
    return "$quotedFilePath $argText"
}

function Test-TruthyEnvValue {
    param([string]$Value)
    return (-not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^(?i:1|true|yes|on)$')
}

function Test-RunningFromCanonical {
    $self = $PSCommandPath
    if ([string]::IsNullOrEmpty($self)) { return $false }
    if (-not (Test-Path -LiteralPath $Script:CanonicalScript)) { return $false }
    $a = (Resolve-Path -LiteralPath $self).Path
    $b = (Resolve-Path -LiteralPath $Script:CanonicalScript).Path
    return ($a -ieq $b)
}

function Write-BootstrapMessage {
    param([Parameter(Mandatory)][string]$Message)
    Write-Output "[info] $Message"
}

function Invoke-Bootstrap {
    param([string[]]$ForwardArgs)
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            & winget install --id Git.Git -e --silent `
                --accept-package-agreements --accept-source-agreements | Out-Null
            $m = [Environment]::GetEnvironmentVariable('Path','Machine')
            $u = [Environment]::GetEnvironmentVariable('Path','User')
            $env:Path = "$m;$u;$env:Path"
        }
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            Write-Error 'git is required to bootstrap. Install Git for Windows and re-run.'
            exit 2
        }
    }
    if (-not (Test-Path -LiteralPath $Script:InstallRoot)) {
        New-Item -ItemType Directory -Path $Script:InstallRoot -Force | Out-Null
    }
    $canonicalRepoAlreadyExisted = Test-Path -LiteralPath $Script:CanonicalRepo
    if (-not $canonicalRepoAlreadyExisted) {
        & git clone $Script:RepoUrl $Script:CanonicalRepo
        if ($LASTEXITCODE -ne 0) { Write-Error 'git clone failed'; exit 3 }
    } else {
        $status = & git -C $Script:CanonicalRepo status --porcelain 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Unable to inspect canonical install at '$Script:CanonicalRepo' before bootstrap (git status --porcelain failed with exit $LASTEXITCODE)." -ErrorAction Continue
            exit 4
        }
        if (-not [string]::IsNullOrWhiteSpace($status)) {
            $dirtyEntries = @(
                $status -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )
            Write-Error "Refusing to bootstrap canonical install at '$Script:CanonicalRepo' because it has local changes. Commit, stash, or clean the tree before re-running." -ErrorAction Continue
            foreach ($entry in $dirtyEntries) {
                Write-BootstrapMessage "  $entry"
            }
            exit 4
        }
    }

    $expectedCanonicalRepo = [System.IO.Path]::GetFullPath($Script:CanonicalRepo).TrimEnd([char[]]@([char]92, [char]47))
    $topLevelOutput = & git -C $Script:CanonicalRepo rev-parse --show-toplevel 2>&1 | Out-String
    $topLevelExitCode = $LASTEXITCODE
    $observedTopLevel = $topLevelOutput.Trim()
    $normalizedTopLevel = $null
    if (-not [string]::IsNullOrWhiteSpace($observedTopLevel)) {
        try {
            $normalizedTopLevel = [System.IO.Path]::GetFullPath($observedTopLevel).TrimEnd([char[]]@([char]92, [char]47))
        } catch {
            $normalizedTopLevel = $null
        }
    }
    if ($topLevelExitCode -ne 0 -or $normalizedTopLevel -ine $expectedCanonicalRepo) {
        $displayTopLevel = if ([string]::IsNullOrWhiteSpace($observedTopLevel)) { '<empty>' } else { $observedTopLevel }
        Write-Error "Refusing to bootstrap canonical install at '$Script:CanonicalRepo' because its Git top-level does not match the expected canonical repository. Expected '$expectedCanonicalRepo'; observed '$displayTopLevel' (git exit $topLevelExitCode)." -ErrorAction Continue
        exit 4
    }

    $branchOutput = & git -C $Script:CanonicalRepo rev-parse --abbrev-ref HEAD 2>&1 | Out-String
    $branchExitCode = $LASTEXITCODE
    $observedBranch = $branchOutput.Trim()
    if ($branchExitCode -ne 0 -or $observedBranch -cne $Script:BootstrapBranch) {
        $displayBranch = if ([string]::IsNullOrWhiteSpace($observedBranch)) { '<empty>' } else { $observedBranch }
        Write-Error "Refusing to bootstrap canonical install at '$Script:CanonicalRepo' because its current branch does not match the approved release branch. Expected '$Script:BootstrapBranch'; observed '$displayBranch' (git exit $branchExitCode)." -ErrorAction Continue
        exit 4
    }

    $originOutput = & git -C $Script:CanonicalRepo remote get-url --all origin 2>&1 | Out-String
    $originExitCode = $LASTEXITCODE
    $origins = @(
        $originOutput -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($originExitCode -ne 0 -or $origins.Count -ne 1 -or $origins[0] -cne $Script:RepoUrl) {
        $observedOrigins = if ($origins.Count -eq 0) { '<none>' } else { $origins -join ', ' }
        Write-Error "Refusing to bootstrap canonical install at '$Script:CanonicalRepo' because its origin could not be verified. Expected exactly one origin '$Script:RepoUrl'; observed $($origins.Count): $observedOrigins (git exit $originExitCode)." -ErrorAction Continue
        exit 4
    }

    if ($canonicalRepoAlreadyExisted) {
        & git -C $Script:CanonicalRepo pull --ff-only origin $Script:BootstrapBranch | Out-Null
        $pullExitCode = $LASTEXITCODE
        if ($pullExitCode -ne 0) { Write-Error "git pull --ff-only failed for '$Script:CanonicalRepo' (exit $pullExitCode)" -ErrorAction Continue; exit 3 }
    }
    $pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $pwshCmd) { $pwshCmd = Get-Command powershell.exe -ErrorAction Stop }
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $Script:CanonicalScript) + $ForwardArgs
    $p = Start-Process -FilePath $pwshCmd.Source -ArgumentList $argList -NoNewWindow -PassThru -Wait
    exit $p.ExitCode
}

if (-not (Test-TruthyEnvValue $env:AUTORESEARCH_DOT_SOURCE_ONLY)) {
    if (-not (Test-RunningFromCanonical)) {
        if ($NoBootstrap) {
            Write-BootstrapMessage "-NoBootstrap was supplied; skipping canonical bootstrap and relaunch for target '$Script:CanonicalRepo'."
        } else {
            Invoke-Bootstrap -ForwardArgs (ConvertTo-ForwardArgs $PSBoundParameters)
        }
    }
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    if ($PSCommandPath) {
        $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
    } else {
        $RepoRoot = $Script:CanonicalRepo
    }
}
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')

function New-Dir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Test-WindowsHost {
    return [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

function Get-LauncherAclPrincipals {
    if (-not (Test-WindowsHost)) {
        throw 'Windows ACLs are only available on Windows hosts.'
    }

    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $principals = @(
        $currentUser
        [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')     # LocalSystem
        [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')  # Built-in Administrators
    )

    $seen = @{}
    return @($principals | Where-Object {
        if ($seen.ContainsKey($_.Value)) { return $false }
        $seen[$_.Value] = $true
        return $true
    })
}

function ConvertTo-LauncherSidValue {
    param([Parameter(Mandatory)]$IdentityReference)
    if ($IdentityReference -is [System.Security.Principal.SecurityIdentifier]) {
        return $IdentityReference.Value
    }
    try {
        return $IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch {
        return [string]$IdentityReference
    }
}

function Test-LauncherDirectoryAcl {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $result = [ordered]@{
        Path              = $Path
        IsHardened        = $false
        Status            = 'Degraded'
        Owner             = $null
        ExpectedOwner    = $null
        MissingPrincipals = @()
        UnexpectedRules   = @()
        InheritanceLocked = $false
        FailureOperation  = $null
        Reason            = $null
    }

    if (-not (Test-WindowsHost)) {
        $result.FailureOperation = 'Windows ACL verification'
        $result.Reason = 'Windows ACL verification is unavailable on this host.'
        return [pscustomobject]$result
    }

    $operation = 'read directory ACL'
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $operation = 'compare directory ACL with launcher policy'
        $principals = @(Get-LauncherAclPrincipals)
        $allowedSids = @($principals | ForEach-Object { $_.Value })
        $result.ExpectedOwner = $principals[0].Value
        $result.Owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value

        $readRight = [int][System.Security.AccessControl.FileSystemRights]::Read
        $missing = New-Object System.Collections.Generic.List[string]
        foreach ($principal in $principals) {
            $rules = @($acl.Access | Where-Object {
                $sid = ConvertTo-LauncherSidValue -IdentityReference $_.IdentityReference
                $hasRead = (([int]$_.FileSystemRights -band $readRight) -eq $readRight)
                $sid -eq $principal.Value -and
                    $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
                    $hasRead
            })
            $denyRules = @($acl.Access | Where-Object {
                (ConvertTo-LauncherSidValue -IdentityReference $_.IdentityReference) -eq $principal.Value -and
                    $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny
            })
            if ($rules.Count -eq 0 -or $denyRules.Count -gt 0) {
                $missing.Add($principal.Value) | Out-Null
            }
        }

        $unexpected = @($acl.Access | Where-Object {
            $sid = ConvertTo-LauncherSidValue -IdentityReference $_.IdentityReference
            $sid -notin $allowedSids
        } | ForEach-Object {
            '{0}:{1}:{2}' -f (ConvertTo-LauncherSidValue -IdentityReference $_.IdentityReference),
                $_.AccessControlType, $_.FileSystemRights
        })

        $result.MissingPrincipals = @($missing)
        $result.UnexpectedRules = @($unexpected)
        $result.InheritanceLocked = [bool]$acl.AreAccessRulesProtected
        $ownerMatches = $result.Owner -eq $result.ExpectedOwner
        $result.IsHardened = $ownerMatches -and
            $result.InheritanceLocked -and
            $result.MissingPrincipals.Count -eq 0 -and
            $result.UnexpectedRules.Count -eq 0

        if ($result.IsHardened) {
            $result.Status = 'Verified'
        } else {
            $result.FailureOperation = 'ACL policy verification'
            $result.Reason = 'The owner, protected inheritance, or explicit allow rules did not match the launcher ACL policy.'
        }
    } catch {
        $result.FailureOperation = $operation
        $result.Reason = $_.Exception.Message
    }

    return [pscustomobject]$result
}

function Set-LauncherDirectoryAcl {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Purpose
    )

    $operation = 'Windows ACL verification'
    try {
        if (-not (Test-WindowsHost)) {
            throw 'Windows ACL hardening is unavailable on this host.'
        }
        $operation = 'create required storage directory'
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            New-Dir -Path $Path
        }

        $operation = 'read directory ACL before repair'
        $principals = @(Get-LauncherAclPrincipals)
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $operation = 'prepare restrictive directory ACL'
        $acl.SetOwner($principals[0])
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($existingRule in @($acl.Access)) {
            [void]$acl.RemoveAccessRule($existingRule)
        }

        $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
        foreach ($principal in $principals) {
            $rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
                $principal,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                $inheritance,
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow
            )
            $acl.AddAccessRule($rule)
        }

        $operation = 'Set-Acl'
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        $operation = 'ACL readback verification'
        $verification = Test-LauncherDirectoryAcl -Path $Path
        if (-not $verification.IsHardened) {
            $readbackOperation = if ($verification.FailureOperation) {
                $verification.FailureOperation
            } else {
                'ACL policy verification'
            }
            throw "ACL readback failed during $readbackOperation`: $($verification.Reason)"
        }
        $verification.Status = 'Repaired'
        $verification.FailureOperation = $null
        return $verification
    } catch {
        $reason = $_.Exception.Message
        $failureOperation = $operation
        $repairStep = if ($failureOperation -eq 'Windows ACL verification') {
            'Run the launcher on Windows so the required ACL can be verified.'
        } elseif ($failureOperation -eq 'Set-Acl') {
            "Run the launcher as the account that owns '$Path' with permission to change that directory ACL, then rerun so the launcher can apply and verify its restrictive ACL."
        } elseif ($failureOperation -eq 'ACL readback verification') {
            "Inspect '$Path', set its owner to the current user, disable inheritance, and remove access for principals outside the current user, Administrators, and SYSTEM; then rerun so the launcher can verify the repaired ACL."
        } else {
            "Restore the owning account's ability to read and change the ACL on '$Path', then rerun so the launcher can apply and verify its restrictive ACL."
        }
        $warning = "Refusing launcher storage for $Purpose '$Path': operation '$failureOperation' failed: $reason Repair step: $repairStep Existing files are preserved."
        Write-Warning $warning
        return [pscustomobject]@{
            Path             = $Path
            IsHardened       = $false
            Status           = 'Refused'
            FailureOperation = $failureOperation
            Reason           = $reason
            RepairStep       = $repairStep
            Warning          = $warning
        }
    }
}

function Ensure-LauncherDirectoryAcl {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Purpose
    )

    if ($null -eq (Get-Variable -Scope Script -Name LauncherAclStatus -ErrorAction SilentlyContinue)) {
        $Script:LauncherAclStatus = @{}
    }
    $priorFailure = Get-Variable -Scope Script -Name LauncherAclFailure -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $priorFailure) {
        throw $priorFailure
    }
    try {
        $key = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    } catch {
        $key = $Path
    }
    $verification = Test-LauncherDirectoryAcl -Path $Path
    if ($verification.IsHardened) {
        if ($Script:LauncherAclStatus.ContainsKey($key) -and
            $Script:LauncherAclStatus[$key].Status -eq 'Repaired') {
            $verification.Status = 'Repaired'
        }
        $Script:LauncherAclStatus[$key] = $verification
        return $verification
    }

    $result = Set-LauncherDirectoryAcl -Path $Path -Purpose $Purpose
    if (-not $result.IsHardened) {
        $message = $result.Warning
        $failure = [System.InvalidOperationException]::new($message)
        $failure.Data['LauncherAclStatus'] = 'Refused'
        $failure.Data['Path'] = $Path
        $failure.Data['Purpose'] = $Purpose
        $failure.Data['FailureOperation'] = $result.FailureOperation
        $Script:LauncherAclFailure = $failure
        throw $failure
    }

    $Script:LauncherAclStatus[$key] = $result
    return $result
}

function Initialize-LauncherStorage {
    $Script:LauncherAclFailure = $null
    New-Dir -Path $LogDir
    $statePath = Get-TaskLaunchStatePath
    $stateDirectory = Split-Path -Parent $statePath
    if ([string]::IsNullOrWhiteSpace($stateDirectory)) {
        $stateDirectory = $LogDir
    }
    New-Dir -Path $stateDirectory

    # Logs include host-local paths and run metadata; task state includes process
    # details and redacted command lines; per-user defaults include provider
    # endpoints, deployment names, log paths, and schedule choices. Require a
    # restrictive readback for each storage directory before allowing writes.
    # The legacy beside-launcher launch.json is import-only: verify its file
    # ACL before reading it, and never change ACLs on its application directory.
    $requiredDirectories = @(
        [pscustomobject]@{ Path = $LogDir; Purpose = 'launcher log directory' },
        [pscustomobject]@{ Path = $stateDirectory; Purpose = 'task launch state directory' }
    )
    if (-not [string]::IsNullOrWhiteSpace($Script:DefaultsPath) -and
        -not [string]::IsNullOrWhiteSpace($Script:LegacyDefaultsPath) -and
        -not [string]::Equals(
            [System.IO.Path]::GetFullPath($Script:DefaultsPath),
            [System.IO.Path]::GetFullPath($Script:LegacyDefaultsPath),
            [System.StringComparison]::OrdinalIgnoreCase)) {
        $defaultsDirectory = Split-Path -Parent $Script:DefaultsPath
        if (-not [string]::IsNullOrWhiteSpace($defaultsDirectory)) {
            New-Dir -Path $defaultsDirectory
            $requiredDirectories += [pscustomobject]@{
                Path = $defaultsDirectory
                Purpose = 'per-user launcher configuration directory'
            }
        }
    }

    $checkedDirectories = @{}
    foreach ($directory in $requiredDirectories) {
        $directoryKey = [System.IO.Path]::GetFullPath($directory.Path).TrimEnd('\', '/')
        if ($checkedDirectories.ContainsKey($directoryKey)) {
            continue
        }
        $checkedDirectories[$directoryKey] = $true
        Ensure-LauncherDirectoryAcl -Path $directory.Path -Purpose $directory.Purpose | Out-Null
    }
}

function Write-Json {
    param(
        [ValidateSet('info', 'warn', 'error', 'stdout', 'stderr', 'debug')][string]$Level,
        [string]$Message,
        [hashtable]$Extra = $null
    )
    $aclFailure = Get-Variable -Scope Script -Name LauncherAclFailure -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $aclFailure) {
        throw $aclFailure.Message
    }
    $record = [ordered]@{
        ts    = (Get-Date).ToUniversalTime().ToString('o')
        level = $Level
        msg   = $Message
    }
    if ($null -ne $Extra) {
        foreach ($k in $Extra.Keys) { $record[$k] = $Extra[$k] }
    }
    $line = $record | ConvertTo-Json -Compress -Depth 6
    $aggregateDirectory = Split-Path -Parent $Script:AggregateLog
    New-Dir -Path $aggregateDirectory
    Ensure-LauncherDirectoryAcl -Path $aggregateDirectory -Purpose 'launcher log root' | Out-Null
    if ($Script:RunLogPath) {
        $runLogDirectory = Split-Path -Parent $Script:RunLogPath
        if (-not [string]::IsNullOrWhiteSpace($runLogDirectory)) {
            New-Dir -Path $runLogDirectory
            $aggregateFullPath = [System.IO.Path]::GetFullPath($aggregateDirectory).TrimEnd('\', '/')
            $runLogFullPath = [System.IO.Path]::GetFullPath($runLogDirectory).TrimEnd('\', '/')
            if (-not [string]::Equals($aggregateFullPath, $runLogFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                Ensure-LauncherDirectoryAcl -Path $runLogDirectory -Purpose 'per-run launcher log directory' | Out-Null
            }
        }
    }
    Add-Content -LiteralPath $Script:AggregateLog -Value $line -Encoding UTF8
    if ($Script:RunLogPath) {
        Add-Content -LiteralPath $Script:RunLogPath -Value $line -Encoding UTF8
    }
    if ($Level -in @('info', 'warn', 'error')) {
        $color = switch ($Level) { 'info' { 'Gray' } 'warn' { 'Yellow' } 'error' { 'Red' } }
        Write-Host "[$Level] $Message" -ForegroundColor $color
    } elseif ($Level -eq 'debug' -and $Script:DebugEnabled) {
        Write-Host "[debug] $Message" -ForegroundColor DarkCyan
    }
}

function Write-DebugLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [hashtable]$Extra = $null
    )
    if (-not $Script:DebugEnabled) { return }
    try {
        Write-Json -Level debug -Message $Message -Extra $Extra
    } catch {
        # Never let debug logging derail the script.
    }
}

function Get-CurrentProcessCommandLine {
    if (-not (Test-WindowsHost)) { return $null }
    try {
        $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop
        return $process.CommandLine
    } catch {
        return $null
    }
}

function Get-RedactedTaskLaunchCommandLine {
    param([AllowNull()][string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $CommandLine }

    $redacted = $CommandLine
    foreach ($parameterName in @('ApiKey', 'AzureEndpoint', 'AzureDeployment')) {
        $pattern = "(?i)(^|\s+)(-$([regex]::Escape($parameterName)))(\s+|=|:)(?:'[^']*'|""[^""]*""|\S+)"
        $redacted = [regex]::Replace($redacted, $pattern, '$1$2$3[REDACTED]')
    }
    return $redacted
}

function Get-RedactedTaskLaunchState {
    param([Parameter(Mandatory)][hashtable]$State)

    $redactedState = [ordered]@{}
    foreach ($key in $State.Keys) {
        $value = $State[$key]
        if (($value -is [string]) -and ($key -match '(?i)Command(Line)?$')) {
            $value = Get-RedactedTaskLaunchCommandLine -CommandLine $value
        }
        $redactedState[$key] = $value
    }
    return $redactedState
}

function Get-TaskLaunchStatePath {
    if (-not [string]::IsNullOrWhiteSpace($Script:TaskLaunchStatePath)) {
        return $Script:TaskLaunchStatePath
    }
    $logRoot = $LogDir
    if ([string]::IsNullOrWhiteSpace($logRoot)) {
        $logRoot = Join-Path (Join-Path $env:TEMP 'myTech.Today') 'logs'
    }
    return Join-Path $logRoot 'autoresearch-task-launch.json'
}

function Write-TaskLaunchState {
    param([Parameter(Mandatory)][hashtable]$State)
    try {
        $statePath = Get-TaskLaunchStatePath
        $stateDirectory = Split-Path -Parent $statePath
        New-Dir -Path $stateDirectory
        Ensure-LauncherDirectoryAcl -Path $stateDirectory -Purpose 'task launch state directory' | Out-Null
        $redactedState = Get-RedactedTaskLaunchState -State $State
        ($redactedState | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $statePath -Encoding UTF8
    } catch {
        $stateWriteError = $_
        $message = "Task launch state write failed at '$(Get-TaskLaunchStatePath)': $($stateWriteError.Exception.Message)"
        $aclFailure = Get-Variable -Scope Script -Name LauncherAclFailure -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $aclFailure -or $stateWriteError.Exception.Data['LauncherAclStatus'] -eq 'Refused') {
            Write-Warning $message
        } else {
            try {
                Write-Json -Level warn -Message $message -Extra @{
                    statePath = (Get-TaskLaunchStatePath)
                }
            } catch {
                Write-Warning $message
            }
        }
        throw $stateWriteError.Exception
    }
}

function Test-CommandOnPath {
    param([string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $combined = @($machine, $user, $env:Path) -join ';'
    $segments = $combined -split ';' | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    $env:Path = ($segments -join ';')
}

function Invoke-Winget {
    param([string[]]$Arguments)
    if (-not (Test-CommandOnPath 'winget')) { return $false }
    & winget @Arguments | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Install-Tool {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$WingetId,
        [string]$PipxPackage,
        [string]$PipPackage,
        [string]$NpmPackage
    )
    if (Test-CommandOnPath $Name) {
        $resolved = (Get-Command $Name -ErrorAction SilentlyContinue).Source
        Write-DebugLog "Install-Tool: '$Name' already on PATH at '$resolved'"
        return
    }
    Write-Json -Level info -Message "$Name not on PATH; attempting install"
    Write-DebugLog "Install-Tool: trying providers for '$Name'" -Extra @{
        winget = $WingetId; pipx = $PipxPackage; pip = $PipPackage; npm = $NpmPackage
    }
    $ok = $false
    if ($WingetId) {
        $ok = Invoke-Winget @('install', '--id', $WingetId, '--source', 'winget',
            '--accept-package-agreements', '--accept-source-agreements',
            '--silent', '--disable-interactivity')
        Write-DebugLog "Install-Tool: winget install '$WingetId' ok=$ok exit=$LASTEXITCODE"
    }
    if (-not $ok -and $PipxPackage -and (Test-CommandOnPath 'pipx')) {
        & pipx install $PipxPackage | Out-Null
        $ok = ($LASTEXITCODE -eq 0)
        Write-DebugLog "Install-Tool: pipx install '$PipxPackage' ok=$ok exit=$LASTEXITCODE"
    }
    if (-not $ok -and $PipPackage -and (Test-CommandOnPath 'pip')) {
        & pip install --user $PipPackage | Out-Null
        $ok = ($LASTEXITCODE -eq 0)
        Write-DebugLog "Install-Tool: pip install '$PipPackage' ok=$ok exit=$LASTEXITCODE"
    }
    if (-not $ok -and $NpmPackage -and (Test-CommandOnPath 'npm')) {
        & npm install -g $NpmPackage | Out-Null
        $ok = ($LASTEXITCODE -eq 0)
        Write-DebugLog "Install-Tool: npm install -g '$NpmPackage' ok=$ok exit=$LASTEXITCODE"
    }
    Update-SessionPath
    if (-not (Test-CommandOnPath $Name)) {
        throw "$Name is required but could not be installed automatically. Install $Name manually and re-run."
    }
    $resolved = (Get-Command $Name -ErrorAction SilentlyContinue).Source
    Write-DebugLog "Install-Tool: '$Name' now resolvable at '$resolved'"
}

function Test-OllamaListening {
    try {
        Invoke-RestMethod -Uri ("$OllamaHost/api/tags") -Method Get -TimeoutSec 2 | Out-Null
        Write-DebugLog "Test-OllamaListening: reachable at $OllamaHost"
        return $true
    } catch {
        Write-DebugLog "Test-OllamaListening: not reachable at $OllamaHost ($($_.Exception.Message))"
        return $false
    }
}


function Start-OllamaServer {
    if (Test-OllamaListening) { return }
    Write-Json -Level info -Message "Starting ollama serve detached at $OllamaHost"
    $ollamaCmd = Get-Command ollama -ErrorAction Stop
    $hostPort = $OllamaHost -replace '^https?://', ''
    [Environment]::SetEnvironmentVariable('OLLAMA_HOST', $hostPort, 'Process')
    Write-DebugLog "Start-OllamaServer: launching '$($ollamaCmd.Source) serve' (OLLAMA_HOST=$hostPort)"
    Start-Process -FilePath $ollamaCmd.Source -ArgumentList 'serve' -WindowStyle Hidden | Out-Null
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if (Test-OllamaListening) {
            Write-DebugLog "Start-OllamaServer: ready at $OllamaHost"
            return
        }
        Start-Sleep -Seconds 2
    }
    throw "ollama did not become ready at $OllamaHost within 60 seconds. Run 'ollama serve' manually to diagnose."
}

function Test-OllamaModelPresent {
    try {
        $tags = Invoke-RestMethod -Uri ("$OllamaHost/api/tags") -Method Get -TimeoutSec 5
        if ($null -eq $tags -or -not (Get-Member -InputObject $tags -Name 'models' -MemberType NoteProperty)) {
            Write-DebugLog "Test-OllamaModelPresent: no 'models' in /api/tags response"
            return $false
        }
        $present = [bool]($tags.models | Where-Object { $_.name -eq $Model })
        Write-DebugLog "Test-OllamaModelPresent: model '$Model' present=$present (catalog size=$($tags.models.Count))"
        return $present
    } catch {
        Write-DebugLog "Test-OllamaModelPresent: error querying /api/tags ($($_.Exception.Message))"
        return $false
    }
}

function Sync-OllamaModel {
    if (Test-OllamaModelPresent) { return }
    Write-Json -Level info -Message "Pulling ollama model $Model"
    & ollama pull $Model
    if ($LASTEXITCODE -ne 0) {
        throw "ollama pull $Model failed (exit $LASTEXITCODE)"
    }
    Write-DebugLog "Sync-OllamaModel: pulled '$Model' (exit $LASTEXITCODE)"
}

function Assert-RepoLayout {
    Write-DebugLog "Assert-RepoLayout: RepoRoot=$RepoRoot"
    if (-not (Test-Path -LiteralPath $RepoRoot)) {
        throw "Repo root not found: $RepoRoot"
    }
    $trainPy = Join-Path $RepoRoot 'train.py'
    if (-not (Test-Path -LiteralPath $trainPy)) {
        throw "train.py not found at $trainPy"
    }
    $venv = Join-Path $RepoRoot '.venv'
    Write-DebugLog "Assert-RepoLayout: train.py=$trainPy venv=$venv venvExists=$([bool](Test-Path -LiteralPath $venv))"
    if (-not (Test-Path -LiteralPath $venv)) {
        Write-Json -Level info -Message "Project virtualenv missing; running 'uv sync'"
        Push-Location $RepoRoot
        try {
            & uv sync
            if ($LASTEXITCODE -ne 0) {
                throw "uv sync failed (exit $LASTEXITCODE)"
            }
            Write-DebugLog "Assert-RepoLayout: 'uv sync' completed exit=$LASTEXITCODE"
        } finally {
            Pop-Location
        }
    }
}

function Invoke-Preflight {
    Write-DebugLog "Invoke-Preflight: begin (Provider=$Provider Model=$Model LogDir=$LogDir)"
    Initialize-LauncherStorage
    Write-DebugLog "Invoke-Preflight: ensuring 'uv' present"
    Install-Tool -Name 'uv' -WingetId 'astral-sh.uv' -PipxPackage 'uv' -PipPackage 'uv'
    Write-DebugLog "Invoke-Preflight: ensuring 'ai-powered' present"
    Install-Tool -Name 'ai-powered' -NpmPackage 'ai-powered'
    Write-DebugLog "Invoke-Preflight: asserting repo layout"
    Assert-RepoLayout
    if ($Provider -eq 'ollama') {
        Write-DebugLog "Invoke-Preflight: ensuring 'ollama' present"
        Install-Tool -Name 'ollama' -WingetId 'Ollama.Ollama'
        Write-DebugLog "Invoke-Preflight: starting/verifying ollama server"
        Start-OllamaServer
        Write-DebugLog "Invoke-Preflight: ensuring model '$Model' is present"
        Sync-OllamaModel
    }
    Write-DebugLog "Invoke-Preflight: complete"
}

function Get-VersionToken {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Source
    )
    $match = [regex]::Match($Text, '(?<!\d)(?<version>\d+(?:\.\d+){1,3})(?:-[0-9A-Za-z.-]+)?')
    if (-not $match.Success) {
        throw "Unable to determine $Source version from output: $Text"
    }
    return $match.Groups['version'].Value
}

function ConvertTo-VersionObject {
    param([Parameter(Mandatory)][string]$Version)
    try {
        return [version]$Version
    } catch {
        throw "Invalid semantic version '$Version'."
    }
}

function Get-ToolVersion {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-CommandOnPath $Name)) {
        throw "$Name is required but could not be found on PATH."
    }
    $cmd = Get-Command $Name -ErrorAction Stop
    $output = & $cmd.Source --version 2>&1 | Out-String
    return Get-VersionToken -Text $output.Trim() -Source $Name
}

function Get-CompatibleVersionFromList {
    param(
        [Parameter(Mandatory)][version]$CurrentVersion,
        [Parameter(Mandatory)][string[]]$Candidates
    )
    $compatible = foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $versionText = $null
        try {
            $versionText = Get-VersionToken -Text $candidate.Trim() -Source 'candidate'
        } catch {
            continue
        }
        $version = ConvertTo-VersionObject -Version $versionText
        if ($version.Major -eq $CurrentVersion.Major -and $version.Minor -eq $CurrentVersion.Minor) {
            [pscustomobject]@{
                Text  = $version.ToString()
                Value = $version
            }
        }
    }
    if (-not $compatible) { return $null }
    return ($compatible | Sort-Object Value -Descending | Select-Object -First 1).Text
}

function Get-UvReleaseVersions {
    $headers = @{ 'User-Agent' = 'autoresearch-win-rtx-scheduled' }
    $releases = Invoke-RestMethod -Uri 'https://api.github.com/repos/astral-sh/uv/releases?per_page=100' -Headers $headers
    $versions = @()
    foreach ($release in $releases) {
        if ($release.draft -or $release.prerelease) { continue }
        if ([string]::IsNullOrWhiteSpace($release.tag_name)) { continue }
        $versions += $release.tag_name
    }
    return $versions
}

function Get-UvCompatibleTargetVersion {
    $current = ConvertTo-VersionObject -Version (Get-ToolVersion -Name 'uv')
    $target = Get-CompatibleVersionFromList -CurrentVersion $current -Candidates (Get-UvReleaseVersions)
    if ($null -eq $target) { return $current.ToString() }
    return $target
}

function Get-WingetPackageVersions {
    $output = & winget show --id Ollama.Ollama --versions --accept-source-agreements 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "winget show --id Ollama.Ollama --versions failed (exit $LASTEXITCODE)"
    }
    $versions = @()
    foreach ($line in ($output -split "\r?\n")) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^\d+(?:\.\d+){1,3}$') {
            $versions += $trimmed
        }
    }
    return $versions
}

function Get-OllamaCompatibleTargetVersion {
    $current = ConvertTo-VersionObject -Version (Get-ToolVersion -Name 'ollama')
    $target = Get-CompatibleVersionFromList -CurrentVersion $current -Candidates (Get-WingetPackageVersions)
    if ($null -eq $target) { return $current.ToString() }
    return $target
}

function Get-NpmGlobalPackageVersion {
    param([Parameter(Mandatory)][string]$PackageName)
    if (-not (Test-CommandOnPath 'npm')) {
        throw 'npm is required but could not be found on PATH.'
    }
    $json = & npm list -g $PackageName --depth=0 --json 2>$null | Out-String
    if ([string]::IsNullOrWhiteSpace($json)) {
        throw "Unable to determine installed npm package version for '$PackageName'."
    }
    $parsed = $json | ConvertFrom-Json
    $dependencies = $parsed.dependencies
    if ($null -eq $dependencies) {
        throw "Unable to determine installed npm package version for '$PackageName'."
    }
    $entry = $dependencies.PSObject.Properties[$PackageName]
    if ($null -eq $entry -or $null -eq $entry.Value -or [string]::IsNullOrWhiteSpace($entry.Value.version)) {
        throw "Unable to determine installed npm package version for '$PackageName'."
    }
    return $entry.Value.version
}

function Get-PinnedAiPoweredVersion {
    $lockPath = Join-Path $RepoRoot 'package-lock.json'
    if (-not (Test-Path -LiteralPath $lockPath)) {
        throw "package-lock.json not found at $lockPath"
    }
    $text = Get-Content -LiteralPath $lockPath -Raw
    $match = [regex]::Match($text, '"node_modules/ai-powered"\s*:\s*\{\s*"version"\s*:\s*"(?<version>[^"]+)"', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) {
        throw "Unable to determine pinned ai-powered version from $lockPath"
    }
    return $match.Groups['version'].Value
}

function Invoke-UvSelfUpdate {
    param([Parameter(Mandatory)][string]$TargetVersion)
    Write-DebugLog "Invoke-UvSelfUpdate: target=$TargetVersion"
    & uv self update $TargetVersion
    if ($LASTEXITCODE -ne 0) {
        throw "uv self update $TargetVersion failed (exit $LASTEXITCODE)"
    }
}

function Test-UvSmoke {
    param([Parameter(Mandatory)][string]$ExpectedVersion)
    $actual = Get-ToolVersion -Name 'uv'
    if ($actual -ne $ExpectedVersion) {
        throw "uv smoke validation found version $actual, expected $ExpectedVersion"
    }
    & uv run --help 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "uv run --help failed (exit $LASTEXITCODE)"
    }
    return $actual
}

function Invoke-OllamaUpgrade {
    param([Parameter(Mandatory)][string]$TargetVersion)
    Write-DebugLog "Invoke-OllamaUpgrade: target=$TargetVersion"
    $ok = Invoke-Winget @('upgrade', '--id', 'Ollama.Ollama', '--version', $TargetVersion,
        '--source', 'winget',
        '--silent', '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity')
    if (-not $ok) {
        throw "winget upgrade --id Ollama.Ollama --version $TargetVersion failed"
    }
}

function Test-OllamaSmoke {
    param([Parameter(Mandatory)][string]$ExpectedVersion)
    $actual = Get-ToolVersion -Name 'ollama'
    if ($actual -ne $ExpectedVersion) {
        throw "ollama smoke validation found version $actual, expected $ExpectedVersion"
    }
    Start-OllamaServer
    return $actual
}

function Invoke-AiPoweredInstall {
    param([Parameter(Mandatory)][string]$TargetVersion)
    Write-DebugLog "Invoke-AiPoweredInstall: target=$TargetVersion"
    & npm install -g "ai-powered@$TargetVersion" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "npm install -g ai-powered@$TargetVersion failed (exit $LASTEXITCODE)"
    }
}

function Test-AiPoweredSmoke {
    param([Parameter(Mandatory)][string]$ExpectedVersion)
    $actual = Get-NpmGlobalPackageVersion -PackageName 'ai-powered'
    if ($actual -ne $ExpectedVersion) {
        throw "ai-powered smoke validation found version $actual, expected $ExpectedVersion"
    }
    & ai-powered text --mock --quiet 'launcher update smoke' 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "ai-powered text --mock smoke failed (exit $LASTEXITCODE)"
    }
    return $actual
}

function Invoke-CompatibilityCheckedUpdateStep {
    param(
        [Parameter(Mandatory)][string]$ToolName,
        [Parameter(Mandatory)][string]$CurrentVersion,
        [Parameter(Mandatory)][string]$TargetVersion,
        [Parameter(Mandatory)][scriptblock]$InstallAction,
        [Parameter(Mandatory)][scriptblock]$SmokeAction,
        [Parameter(Mandatory)][scriptblock]$RollbackAction
    )

    $currentInfo = ConvertTo-VersionObject -Version $CurrentVersion
    $changed = ($CurrentVersion -ne $TargetVersion)
    $actionText = if ($changed) { "updating to $TargetVersion" } else { "already at compatible version $TargetVersion" }
    Write-Json -Level info -Message "$ToolName $actionText" -Extra @{
        tool = $ToolName
        before = $CurrentVersion
        target = $TargetVersion
        compatibilityLine = "$($currentInfo.Major).$($currentInfo.Minor).x"
    }

    try {
        if ($changed) {
            & $InstallAction $TargetVersion $CurrentVersion
            Update-SessionPath
        }
        $afterVersion = & $SmokeAction $TargetVersion $CurrentVersion
        if ([string]::IsNullOrWhiteSpace($afterVersion)) {
            $afterVersion = $TargetVersion
        }
        if ($afterVersion -ne $TargetVersion) {
            throw "$ToolName smoke validation reported version $afterVersion, expected $TargetVersion"
        }
        $result = [pscustomobject]@{
            tool = $ToolName
            before = $CurrentVersion
            target = $TargetVersion
            after = $afterVersion
            updated = $changed
            rolledBack = $false
        }
        Write-Json -Level info -Message "$ToolName update step validated" -Extra @{
            tool = $ToolName
            before = $CurrentVersion
            target = $TargetVersion
            after = $afterVersion
            updated = $changed
            rolledBack = $false
        }
        return $result
    } catch {
        if ($changed) {
            Write-Json -Level warn -Message "$ToolName update failed; rolling back to $CurrentVersion" -Extra @{
                tool = $ToolName
                before = $CurrentVersion
                target = $TargetVersion
                error = $_.Exception.Message
            }
            try {
                & $RollbackAction $CurrentVersion $TargetVersion
                Update-SessionPath
                $rolledBackVersion = & $SmokeAction $CurrentVersion $CurrentVersion
                if ([string]::IsNullOrWhiteSpace($rolledBackVersion)) {
                    $rolledBackVersion = $CurrentVersion
                }
                if ($rolledBackVersion -ne $CurrentVersion) {
                    throw "$ToolName rollback smoke validation reported version $rolledBackVersion, expected $CurrentVersion"
                }
                Write-Json -Level warn -Message "$ToolName rolled back to $CurrentVersion after failed update" -Extra @{
                    tool = $ToolName
                    before = $CurrentVersion
                    target = $TargetVersion
                    after = $rolledBackVersion
                    rolledBack = $true
                }
            } catch {
                throw "$ToolName update to $TargetVersion failed and rollback to $CurrentVersion was not clean: $($_.Exception.Message)"
            }
        }
        throw
    }
}

function Invoke-UvUpdate {
    $current = Get-ToolVersion -Name 'uv'
    $target = Get-UvCompatibleTargetVersion
    return Invoke-CompatibilityCheckedUpdateStep -ToolName 'uv' -CurrentVersion $current -TargetVersion $target `
        -InstallAction {
            param([string]$TargetVersion, [string]$CurrentVersion)
            Invoke-UvSelfUpdate -TargetVersion $TargetVersion
        } `
        -SmokeAction {
            param([string]$TargetVersion, [string]$CurrentVersion)
            Test-UvSmoke -ExpectedVersion $TargetVersion
        } `
        -RollbackAction {
            param([string]$TargetVersion, [string]$CurrentVersion)
            Invoke-UvSelfUpdate -TargetVersion $CurrentVersion
        }
}

function Invoke-OllamaUpdate {
    $current = Get-ToolVersion -Name 'ollama'
    $target = Get-OllamaCompatibleTargetVersion
    return Invoke-CompatibilityCheckedUpdateStep -ToolName 'ollama' -CurrentVersion $current -TargetVersion $target `
        -InstallAction {
            param([string]$TargetVersion, [string]$CurrentVersion)
            Invoke-OllamaUpgrade -TargetVersion $TargetVersion
        } `
        -SmokeAction {
            param([string]$TargetVersion, [string]$CurrentVersion)
            Test-OllamaSmoke -ExpectedVersion $TargetVersion
        } `
        -RollbackAction {
            param([string]$TargetVersion, [string]$CurrentVersion)
            Invoke-OllamaUpgrade -TargetVersion $CurrentVersion
        }
}

function Invoke-AiPoweredUpdate {
    $current = Get-NpmGlobalPackageVersion -PackageName 'ai-powered'
    $target = Get-PinnedAiPoweredVersion
    return Invoke-CompatibilityCheckedUpdateStep -ToolName 'ai-powered' -CurrentVersion $current -TargetVersion $target `
        -InstallAction {
            param([string]$TargetVersion, [string]$CurrentVersion)
            Invoke-AiPoweredInstall -TargetVersion $TargetVersion
        } `
        -SmokeAction {
            param([string]$TargetVersion, [string]$CurrentVersion)
            Test-AiPoweredSmoke -ExpectedVersion $TargetVersion
        } `
        -RollbackAction {
            param([string]$TargetVersion, [string]$CurrentVersion)
            Invoke-AiPoweredInstall -TargetVersion $CurrentVersion
        }
}

function Invoke-Update {
    $results = @()

    Write-Json -Level info -Message 'Updating uv on its current compatibility line'
    $results += Invoke-UvUpdate

    if ($Provider -eq 'ollama') {
        Write-Json -Level info -Message 'Updating Ollama on its current compatibility line'
        $results += Invoke-OllamaUpdate
    } else {
        $results += [pscustomobject]@{
            tool = 'ollama'
            before = $null
            target = $null
            after = $null
            updated = $false
            rolledBack = $false
            skipped = $true
            reason = "Provider '$Provider' does not use Ollama"
        }
        Write-Json -Level info -Message "Skipping Ollama update because provider '$Provider' does not use Ollama" -Extra @{
            tool = 'ollama'
            provider = $Provider
        }
    }

    Write-Json -Level info -Message 'Updating ai-powered to the pinned package-lock version'
    $results += Invoke-AiPoweredUpdate

    if ($Provider -eq 'ollama') {
        Start-OllamaServer
        Write-Json -Level info -Message "Re-pulling model $Model"
        Sync-OllamaModel
    }

    $summary = ($results | ForEach-Object {
        if ($_.PSObject.Properties.Match('skipped').Count -gt 0 -and $_.skipped) {
            "ollama skipped ($($_.reason))"
        } elseif ($_.updated) {
            "$($_.tool) $($_.before) -> $($_.after)"
        } else {
            "$($_.tool) left at $($_.after)"
        }
    }) -join '; '
    Write-Json -Level info -Message "Update summary: $summary" -Extra @{
        summary = $summary
        steps = $results
    }
    return [pscustomobject]@{ Summary = $summary; Steps = $results }
}

function Add-RunLogReason {
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][string]$Property,
        [Parameter(Mandatory)][string]$Reason
    )
    $current = @($Entry.$Property)
    if ($current -notcontains $Reason) {
        $Entry.$Property = @($current + $Reason)
    }
}

function Get-RunLogMetadata {
    param([Parameter(Mandatory)][System.IO.FileInfo]$FileInfo)
    $exitCode = $null
    try {
        foreach ($line in Get-Content -LiteralPath $FileInfo.FullName -Encoding UTF8 -ErrorAction Stop) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $record = $line | ConvertFrom-Json -ErrorAction Stop
            } catch {
                continue
            }
            if ($record.PSObject.Properties['msg'] -and $record.msg -eq 'Workload finished' -and
                $record.PSObject.Properties['exitCode']) {
                $exitCode = [int]$record.exitCode
            }
        }
    } catch {
        # Missing or partial logs should be treated as failures so the
        # diagnostic evidence stays available for triage.
    }
    $outcome = if ($null -eq $exitCode -or $exitCode -ne 0) { 'failure' } else { 'success' }
    return [pscustomobject]@{
        Name             = $FileInfo.Name
        FullName         = $FileInfo.FullName
        LastWriteTimeUtc = $FileInfo.LastWriteTimeUtc
        ExitCode         = $exitCode
        Outcome          = $outcome
    }
}

function Get-RunLogRetentionPlan {
    param(
        [string]$LogDir = $Script:LogDir,
        [int]$LogRetentionCount = $Script:LogRetentionCount,
        [int]$LogRetentionDays = $Script:LogRetentionDays
    )
    $cutoffUtc = (Get-Date).ToUniversalTime().AddDays(-$LogRetentionDays)
    $files = @()
    if (Test-Path -LiteralPath $LogDir) {
        $files = Get-ChildItem -LiteralPath $LogDir -Filter 'autoresearch-run-*.jsonl' -File -ErrorAction SilentlyContinue |
            Sort-Object `
                @{ Expression = 'LastWriteTimeUtc'; Descending = $true }, `
                @{ Expression = 'Name'; Descending = $true }
    }

    $entries = foreach ($file in @($files)) {
        $meta = Get-RunLogMetadata -FileInfo $file
        [pscustomobject]@{
            Name             = $meta.Name
            Path             = $meta.FullName
            LastWriteTimeUtc = $meta.LastWriteTimeUtc
            ExitCode         = $meta.ExitCode
            Outcome          = $meta.Outcome
            KeepReasons      = @()
            DeleteReasons    = @()
        }
    }

    if (-not $entries) {
        return [pscustomobject]@{
            LogDir         = $LogDir
            CutoffUtc      = $cutoffUtc
            RetentionCount = $LogRetentionCount
            RetentionDays  = $LogRetentionDays
            Entries        = @()
            Kept           = @()
            Pruned         = @()
            LatestSuccess  = $null
            LatestFailure  = $null
        }
    }

    $recentEntries = @($entries | Where-Object { $_.LastWriteTimeUtc -ge $cutoffUtc })
    $olderEntries = @($entries | Where-Object { $_.LastWriteTimeUtc -lt $cutoffUtc })
    $olderKept = @($olderEntries | Select-Object -First $LogRetentionCount)
    $latestSuccess = $entries | Where-Object { $_.Outcome -eq 'success' } | Select-Object -First 1
    $latestFailure = $entries | Where-Object { $_.Outcome -eq 'failure' } | Select-Object -First 1

    foreach ($entry in $recentEntries) {
        Add-RunLogReason -Entry $entry -Property 'KeepReasons' -Reason 'within-age-window'
    }
    foreach ($entry in $olderKept) {
        Add-RunLogReason -Entry $entry -Property 'KeepReasons' -Reason 'within-old-log-cap'
    }
    if ($latestSuccess) {
        Add-RunLogReason -Entry $latestSuccess -Property 'KeepReasons' -Reason 'latest-success'
    }
    if ($latestFailure) {
        Add-RunLogReason -Entry $latestFailure -Property 'KeepReasons' -Reason 'latest-failure'
    }

    foreach ($entry in $entries) {
        if (@($entry.KeepReasons).Count -eq 0) {
            Add-RunLogReason -Entry $entry -Property 'DeleteReasons' -Reason 'older-than-age-window'
            Add-RunLogReason -Entry $entry -Property 'DeleteReasons' -Reason 'beyond-old-log-cap'
        }
    }

    return [pscustomobject]@{
        LogDir         = $LogDir
        CutoffUtc      = $cutoffUtc
        RetentionCount = $LogRetentionCount
        RetentionDays  = $LogRetentionDays
        Entries        = @($entries)
        Kept           = @($entries | Where-Object { @($_.KeepReasons).Count -gt 0 })
        Pruned         = @($entries | Where-Object { @($_.KeepReasons).Count -eq 0 })
        LatestSuccess  = $latestSuccess
        LatestFailure  = $latestFailure
    }
}

function Limit-RunLogs {
    param(
        [string]$LogDir = $Script:LogDir,
        [int]$LogRetentionCount = $Script:LogRetentionCount,
        [int]$LogRetentionDays = $Script:LogRetentionDays
    )
    $plan = Get-RunLogRetentionPlan -LogDir $LogDir -LogRetentionCount $LogRetentionCount -LogRetentionDays $LogRetentionDays
    if (-not $plan.Pruned -or $plan.Pruned.Count -eq 0) { return $plan }

    # Capture the pruning plan before deleting anything. This preserves the
    # postmortem record even if a delete attempt removes the only per-run copy
    # of an incident's evidence. A write failure must stop pruning.
    $plannedDeletedSummary = @($plan.Pruned | ForEach-Object {
        [pscustomobject]@{
            name    = $_.Name
            reasons = @($_.DeleteReasons)
        }
    })
    $plannedCount = @($plan.Pruned).Count
    $plannedSummary = [pscustomobject]@{
        phase              = 'planned'
        eligibleCount      = $plannedCount
        plannedDeleteCount = $plannedCount
        deletedCount       = 0
        failedCount        = 0
        retentionCount     = $LogRetentionCount
        retentionDays      = $LogRetentionDays
        cutoffUtc          = $plan.CutoffUtc.ToString('o')
        latestSuccess      = if ($plan.LatestSuccess) { $plan.LatestSuccess.Name } else { $null }
        latestFailure      = if ($plan.LatestFailure) { $plan.LatestFailure.Name } else { $null }
        planned            = $plannedDeletedSummary
        deleted            = @()
        failed             = @()
    }
    $plannedSummaryMessage = "Run log pruning reviewed $($plan.Entries.Count) file(s); scheduled $plannedCount for deletion."
    if ($plan.LatestSuccess -or $plan.LatestFailure) {
        $anchorBits = @()
        if ($plan.LatestSuccess) { $anchorBits += "latest success=$($plan.LatestSuccess.Name)" }
        if ($plan.LatestFailure) { $anchorBits += "latest failure=$($plan.LatestFailure.Name)" }
        $plannedSummaryMessage += " Anchors kept: $($anchorBits -join '; ')."
    }
    try {
        Write-Json -Level info -Message $plannedSummaryMessage -Extra @{
            pruning = $plannedSummary
        }
    } catch {
        throw "Run log pruning plan could not be recorded before deletion: $($_.Exception.Message)"
    }

    $deleted = New-Object System.Collections.Generic.List[object]
    $failed = New-Object System.Collections.Generic.List[object]

    foreach ($entry in $plan.Pruned) {
        try {
            Remove-Item -LiteralPath $entry.Path -Force -ErrorAction Stop
            $deleted.Add($entry) | Out-Null
        } catch {
            $failed.Add([pscustomobject]@{
                Name    = $entry.Name
                Path    = $entry.Path
                Reasons = @($entry.DeleteReasons)
                Error   = $_.Exception.Message
            }) | Out-Null
        }
    }

    $deletedSummary = @()
    foreach ($item in $deleted) {
        $deletedSummary += [pscustomobject]@{
            name    = $item.Name
            reasons = @($item.DeleteReasons)
        }
    }

    $failedSummary = @()
    foreach ($item in $failed) {
        $failedSummary += $item
    }

    $summary = [pscustomobject]@{
        phase          = 'completed'
        eligibleCount  = $plan.Pruned.Count
        plannedDeleteCount = $plannedCount
        deletedCount   = $deleted.Count
        failedCount    = $failed.Count
        retentionCount = $LogRetentionCount
        retentionDays  = $LogRetentionDays
        cutoffUtc      = $plan.CutoffUtc.ToString('o')
        latestSuccess  = if ($plan.LatestSuccess) { $plan.LatestSuccess.Name } else { $null }
        latestFailure  = if ($plan.LatestFailure) { $plan.LatestFailure.Name } else { $null }
        planned        = $plannedDeletedSummary
        deleted        = $deletedSummary
        failed         = $failedSummary
    }

    $summaryLevel = if ($failed.Count -gt 0) { 'warn' } else { 'info' }
    $summaryMessage = "Run log pruning reviewed $($plan.Entries.Count) file(s); deleted $($deleted.Count) and failed to delete $($failed.Count)."
    if ($plan.LatestSuccess -or $plan.LatestFailure) {
        $anchorBits = @()
        if ($plan.LatestSuccess) { $anchorBits += "latest success=$($plan.LatestSuccess.Name)" }
        if ($plan.LatestFailure) { $anchorBits += "latest failure=$($plan.LatestFailure.Name)" }
        $summaryMessage += " Anchors kept: $($anchorBits -join '; ')."
    }

    try {
        Write-Json -Level $summaryLevel -Message $summaryMessage -Extra @{
            pruning = $summary
        }
    } catch {
        Write-Host "[$summaryLevel] $summaryMessage"
    }

    return [pscustomobject]@{
        Plan    = $plan
        Deleted = $deletedSummary
        Failed  = $failedSummary
        Summary = $summary
    }
}

function Get-ProviderApiKeyEnvironmentName {
    param([Parameter(Mandatory)][string]$ProviderName)

    switch ($ProviderName) {
        'openai'    { return 'OPENAI_API_KEY' }
        'anthropic' { return 'ANTHROPIC_API_KEY' }
        'azure'     { return 'AZURE_OPENAI_API_KEY' }
        default     { return $null }
    }
}

function Clear-ProviderApiKeyEnvironment {
    $apiKeyNames = @('OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'AZURE_OPENAI_API_KEY')
    foreach ($name in $apiKeyNames) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }

    foreach ($name in $apiKeyNames) {
        if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name, 'Process'))) {
            throw 'Provider API-key environment cleanup failed; refusing to launch a child process.'
        }
    }
}

function Set-WorkloadEnvironment {
    $apiKeyName = Get-ProviderApiKeyEnvironmentName -ProviderName $Provider
    $configuredApiKey = $null
    if ($apiKeyName) {
        if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
            $configuredApiKey = $ApiKey
        } else {
            $configuredApiKey = [Environment]::GetEnvironmentVariable($apiKeyName, 'Process')
        }
    }
    $script:ProviderApiKeyForAi = $configuredApiKey
    Clear-ProviderApiKeyEnvironment

    [Environment]::SetEnvironmentVariable('OLLAMA_HOST', $OllamaHost, 'Process')
    [Environment]::SetEnvironmentVariable('AI_POWERED_MODEL', $Model, 'Process')
    [Environment]::SetEnvironmentVariable('AI_MODEL', $Model, 'Process')
    $apProvider = switch ($Provider) { 'ollama' { 'custom' } default { $Provider } }
    [Environment]::SetEnvironmentVariable('AI_PROVIDER', $apProvider, 'Process')
    if ($Provider -eq 'azure') {
        if ($AzureEndpoint) { [Environment]::SetEnvironmentVariable('AZURE_OPENAI_ENDPOINT', $AzureEndpoint, 'Process') }
        if ($AzureDeployment) { [Environment]::SetEnvironmentVariable('AZURE_OPENAI_DEPLOYMENT', $AzureDeployment, 'Process') }
    }
}

function Invoke-CheckpointRetention {
    param([Parameter(Mandatory)][string]$RepositoryRootPath)

    $trainPath = Join-Path $RepositoryRootPath 'train.py'
    if (-not (Test-Path -LiteralPath $trainPath -PathType Leaf)) {
        Write-Json -Level warn -Message "Checkpoint retention skipped because train.py was not found at '$trainPath'."
        return 1
    }

    $retentionExitCode = 1
    Push-Location $RepositoryRootPath
    try {
        & uv run train.py --cleanup-checkpoints 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                Write-Json -Level stderr -Message ("Checkpoint retention: " + $_.ToString())
            } else {
                Write-Json -Level info -Message ("Checkpoint retention: " + $_.ToString())
            }
        }
        $retentionExitCode = $LASTEXITCODE
        if ($null -eq $retentionExitCode) { $retentionExitCode = 1 }
    } catch {
        Write-Json -Level warn -Message "Checkpoint retention could not run: $($_.Exception.Message)"
        $retentionExitCode = 1
    } finally {
        Pop-Location
    }

    if ($retentionExitCode -ne 0) {
        Write-Json -Level warn -Message "Checkpoint retention finished with exit code $retentionExitCode; unremoved artifacts were retained."
    }
    return $retentionExitCode
}

function Invoke-Workload {
    Set-WorkloadEnvironment
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $Script:RunLogPath = Join-Path $LogDir "autoresearch-run-$stamp.jsonl"
    New-Item -ItemType File -Path $Script:RunLogPath -Force | Out-Null

    Write-Json -Level info -Message 'Starting workload' -Extra @{
        repoRoot   = $RepoRoot
        model      = $Model
        ollamaHost = $OllamaHost
        schedulerPolicy = $SchedulerPolicy
        policySummary = (Get-SchedulerPolicyInfo -Policy $SchedulerPolicy).Summary
        runLog     = $Script:RunLogPath
    }

    # Verify ai-powered is callable (mediator binding) before launching uv.
    $aiVersion = $null
    try {
        $aiVersion = (& ai-powered --version 2>&1 | Out-String).Trim()
    } catch {
        $aiVersion = "unavailable: $($_.Exception.Message)"
    }
    Write-Json -Level info -Message 'ai-powered mediator ready' -Extra @{ version = $aiVersion }

    Push-Location $RepoRoot
    $exitCode = 1
    try {
        Clear-ProviderApiKeyEnvironment
        & uv run train.py 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) {
                Write-Json -Level stderr -Message $_.ToString()
            } else {
                Write-Json -Level stdout -Message ($_.ToString())
            }
        }
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    [void](Invoke-CheckpointRetention -RepositoryRootPath $RepoRoot)
    Write-Json -Level info -Message 'Workload finished' -Extra @{ exitCode = $exitCode }
    Limit-RunLogs
    return $exitCode
}

# --------------------------------------------------------------------------
# Autoresearch experiment loop (driven by program.md). Each iteration runs in
# a temporary worktree attached to a dedicated experiment branch. The source
# checkout is never staged, committed, or reset, and only train.py is staged
# inside the experiment worktree.
# --------------------------------------------------------------------------

function Initialize-ResultsTsv {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Set-Content -LiteralPath $Path -Encoding UTF8 `
            -Value "commit`tval_bpb`tmemory_gb`tstatus`tdescription"
        Write-Json -Level info -Message "Initialized results.tsv at $Path"
    }
}

function ConvertFrom-InvariantMetric {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$MetricName
    )

    $parsedValue = 0.0
    $numberStyle = [System.Globalization.NumberStyles]::Float
    $invariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
    if (-not [double]::TryParse($Value, $numberStyle, $invariantCulture, [ref]$parsedValue) -or
        [double]::IsNaN($parsedValue) -or [double]::IsInfinity($parsedValue)) {
        throw "Invalid $MetricName metric '$Value'. Expected a finite dot-decimal number."
    }
    return $parsedValue
}

function Get-CurrentBestValBpb {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    $expectedHeader = "commit`tval_bpb`tmemory_gb`tstatus`tdescription"
    if ($lines.Count -eq 0 -or $lines[0] -cne $expectedHeader) {
        throw "Invalid results.tsv header in '$Path'. Expected the five-column commit, val_bpb, memory_gb, status, description header."
    }

    $best = $null
    for ($index = 1; $index -lt $lines.Count; $index++) {
        $lineNumber = $index + 1
        $columns = $lines[$index].Split([char]9)
        if ($columns.Count -ne 5) {
            throw "Invalid results.tsv row $lineNumber in '$Path': expected 5 columns, found $($columns.Count)."
        }
        if ($columns[3] -cnotin @('keep', 'discard', 'crash')) {
            throw "Invalid results.tsv status on row $lineNumber in '$Path': '$($columns[3])'."
        }

        $valBpb = ConvertFrom-InvariantMetric -Value $columns[1] -MetricName "results.tsv val_bpb on row $lineNumber"
        $memoryGb = ConvertFrom-InvariantMetric -Value $columns[2] -MetricName "results.tsv memory_gb on row $lineNumber"
        if ($memoryGb -lt 0) {
            throw "Invalid results.tsv memory_gb on row $lineNumber in '$Path': memory must not be negative."
        }
        if ($valBpb -lt 0) {
            throw "Invalid results.tsv val_bpb on row $lineNumber in '$Path': the value must not be negative."
        }
        if ($columns[3] -in @('keep', 'discard') -and $valBpb -le 0) {
            throw "Invalid results.tsv val_bpb on row $lineNumber in '$Path': scored rows must have a positive value."
        }

        if ($columns[3] -ceq 'keep') {
            if ($null -eq $best -or $valBpb -lt $best) { $best = $valBpb }
        }
    }
    return $best
}

function Add-ResultsTsvRow {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Commit,
        [Parameter(Mandatory)][double]$ValBpb,
        [Parameter(Mandatory)][double]$MemoryGb,
        [Parameter(Mandatory)][ValidateSet('keep','discard','crash')][string]$Status,
        [Parameter(Mandatory)][string]$Description
    )

    if ([double]::IsNaN($ValBpb) -or [double]::IsInfinity($ValBpb)) {
        throw "Cannot write a non-finite val_bpb metric for results.tsv status '$Status'."
    }
    if ([double]::IsNaN($MemoryGb) -or [double]::IsInfinity($MemoryGb) -or $MemoryGb -lt 0) {
        throw 'Cannot write an invalid memory_gb metric to results.tsv.'
    }
    if ($ValBpb -lt 0) {
        throw 'Cannot write a negative val_bpb metric to results.tsv.'
    }
    if ($Status -in @('keep', 'discard') -and $ValBpb -le 0) {
        throw "Cannot write a non-positive val_bpb metric for results.tsv status '$Status'."
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Initialize-ResultsTsv -Path $Path
    }
    [void](Get-CurrentBestValBpb -Path $Path)

    $desc = ($Description -replace "[`t`r`n]", ' ').Trim()
    $invariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
    $valBpbText = $ValBpb.ToString('F6', $invariantCulture)
    $memoryGbText = $MemoryGb.ToString('F1', $invariantCulture)
    $row  = "{0}`t{1}`t{2}`t{3}`t{4}" -f `
        $Commit, $valBpbText, $memoryGbText, $Status, $desc
    Add-Content -LiteralPath $Path -Value $row -Encoding UTF8
}

function Read-RunLogMetrics {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Run log '$Path' does not exist; metrics cannot be read."
    }

    $valBpb = $null
    $vramMb = $null
    $hasValBpb = $false
    $hasVramMb = $false
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ($line.StartsWith('val_bpb')) {
            if ($hasValBpb) { throw "Run log '$Path' contains more than one val_bpb metric." }
            if ($line -notmatch '^val_bpb:\s*(.*?)\s*$') {
                throw "Run log '$Path' contains a malformed val_bpb metric line: '$line'."
            }
            $valBpb = ConvertFrom-InvariantMetric -Value $Matches[1] -MetricName 'run log val_bpb'
            if ($valBpb -le 0) { throw "Run log '$Path' contains a non-positive val_bpb metric." }
            $hasValBpb = $true
        } elseif ($line.StartsWith('peak_vram_mb')) {
            if ($hasVramMb) { throw "Run log '$Path' contains more than one peak_vram_mb metric." }
            if ($line -notmatch '^peak_vram_mb:\s*(.*?)\s*$') {
                throw "Run log '$Path' contains a malformed peak_vram_mb metric line: '$line'."
            }
            $vramMb = ConvertFrom-InvariantMetric -Value $Matches[1] -MetricName 'run log peak_vram_mb'
            if ($vramMb -lt 0) { throw "Run log '$Path' contains a negative peak_vram_mb metric." }
            $hasVramMb = $true
        }
    }

    if (-not $hasValBpb) { throw "Run log '$Path' is missing the val_bpb metric." }
    if (-not $hasVramMb) { throw "Run log '$Path' is missing the peak_vram_mb metric." }
    return @{ ValBpb = $valBpb; PeakVramMb = $vramMb }
}

function Invoke-Git {
    param([Parameter(Mandatory)][string[]]$GitArgs, [string]$Cwd = $RepoRoot)
    $out = & git -C $Cwd @GitArgs 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out.TrimEnd([char[]]@("`r","`n")) }
}

function Invoke-AutoresearchGit {
    param(
        [Parameter(Mandatory)][string[]]$GitArgs,
        [Parameter(Mandatory)][string]$Cwd
    )

    $result = Invoke-Git -GitArgs $GitArgs -Cwd $Cwd
    if ($result.ExitCode -ne 0) {
        $command = if ($GitArgs -contains 'commit') {
            'git commit --allow-empty -m <description>'
        } else {
            'git ' + ($GitArgs -join ' ')
        }
        throw "Git command '$command' failed in '$Cwd' with exit code $($result.ExitCode)."
    }
    return $result.Output
}

function Assert-AutoresearchSourceCheckoutClean {
    param([Parameter(Mandatory)][string]$RepoRootPath)

    $status = Invoke-AutoresearchGit -GitArgs @('status','--porcelain','--untracked-files=all') -Cwd $RepoRootPath
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        $entries = @($status -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        throw "Refusing to start the autoresearch loop because the source checkout is dirty. Commit or move these changes first:`n$($entries -join "`n")"
    }
}

function New-AutoresearchExperimentBranch {
    param([Parameter(Mandatory)][string]$RepoRootPath)

    $sourceRoot = Invoke-AutoresearchGit -GitArgs @('rev-parse','--show-toplevel') -Cwd $RepoRootPath
    $baseCommit = Invoke-AutoresearchGit -GitArgs @('rev-parse','HEAD') -Cwd $sourceRoot
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $branch = "autoresearch/experiment-$stamp-$([guid]::NewGuid().ToString('N'))"
    [void](Invoke-AutoresearchGit -GitArgs @('branch',$branch,$baseCommit) -Cwd $sourceRoot)

    return [pscustomobject]@{
        Name       = $branch
        BaseCommit = $baseCommit
    }
}

function Invoke-AiPoweredEdit {
    param(
        [Parameter(Mandatory)][string]$RepoRootPath,
        [int]$ResultsTailRows = 20,
        [string]$ResultsPath
    )
    $programPath = Join-Path $RepoRootPath 'program.md'
    $trainPath   = Join-Path $RepoRootPath 'train.py'
    if ([string]::IsNullOrWhiteSpace($ResultsPath)) {
        $ResultsPath = Join-Path $RepoRootPath 'results.tsv'
    }
    if (-not (Test-Path -LiteralPath $programPath)) { Write-Json -Level warn -Message 'program.md missing; skipping AI edit'; return $null }
    if (-not (Test-Path -LiteralPath $trainPath))   { Write-Json -Level warn -Message 'train.py missing; skipping AI edit';   return $null }
    $program  = Get-Content -LiteralPath $programPath -Raw -Encoding UTF8
    $train    = Get-Content -LiteralPath $trainPath   -Raw -Encoding UTF8
    $results  = if (Test-Path -LiteralPath $resultsPath) {
        ((Get-Content -LiteralPath $resultsPath -Encoding UTF8) | Select-Object -Last $ResultsTailRows) -join "`n"
    } else { '' }
    $system = 'You are an autonomous ML research agent. Reply with exactly one short one-line description starting with DESCRIPTION:, then one fenced python code block containing the complete new contents of train.py. No other text.'
    $prompt = @"
PROGRAM:
$program

RECENT RESULTS (tail of results.tsv):
$results

CURRENT train.py:
``````python
$train
``````

Propose ONE small experimental change to train.py and return the complete new file.
"@
    $tmpPrompt = $null
    $tmpSystemPrompt = $null
    $tmpCliOutput = $null
    $tmpCliScript = $null
    $exitCode = $null
    $raw = $null
    try {
        $apiKeyName = Get-ProviderApiKeyEnvironmentName -ProviderName $Provider
        $configuredApiKey = Get-Variable -Scope Script -Name ProviderApiKeyForAi -ErrorAction SilentlyContinue
        $providerApiKey = $null
        if ($null -ne $configuredApiKey -and -not [string]::IsNullOrWhiteSpace($configuredApiKey.Value)) {
            $providerApiKey = $configuredApiKey.Value
        } elseif ($apiKeyName -and -not [string]::IsNullOrWhiteSpace($ApiKey)) {
            $providerApiKey = $ApiKey
        } elseif ($apiKeyName) {
            $providerApiKey = [Environment]::GetEnvironmentVariable($apiKeyName, 'Process')
        }

        # Expose only the selected provider key while the AI CLI is running.
        Clear-ProviderApiKeyEnvironment
        if ($apiKeyName -and -not [string]::IsNullOrWhiteSpace($providerApiKey)) {
            [Environment]::SetEnvironmentVariable($apiKeyName, $providerApiKey, 'Process')
        }

        $tmpPrompt = [System.IO.Path]::GetTempFileName()
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tmpPrompt, $prompt, $utf8)
        if ($PSVersionTable.PSEdition -eq 'Desktop') {
            # Windows PowerShell 5.1 uses the caller's native-pipeline encoding
            # inside functions, even when OutputEncoding is changed locally.
            # Run the pipeline at script scope, where UTF-8 is honored.
            $tmpSystemPrompt = [System.IO.Path]::GetTempFileName()
            $tmpCliOutput = [System.IO.Path]::GetTempFileName()
            $tmpCliScript = "$tmpPrompt.ps1"
            if (Test-Path -LiteralPath $tmpCliScript) {
                throw 'Could not create the temporary ai-powered invocation script.'
            }
            [System.IO.File]::WriteAllText($tmpSystemPrompt, $system, $utf8)
            $cliScript = @'
param(
    [Parameter(Mandatory)][string]$PromptPath,
    [Parameter(Mandatory)][string]$SystemPromptPath,
    [Parameter(Mandatory)][string]$OutputPath
)

$utf8 = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $utf8
$promptInput = [System.IO.File]::ReadAllText($PromptPath, $utf8)
$systemPrompt = [System.IO.File]::ReadAllText($SystemPromptPath, $utf8)
$raw = $promptInput | & ai-powered text --quiet --system $systemPrompt 2>&1 | Out-String
$exitCode = $LASTEXITCODE
[System.IO.File]::WriteAllText($OutputPath, $raw, $utf8)
exit $exitCode
'@
            [System.IO.File]::WriteAllText($tmpCliScript, $cliScript, $utf8)
            $shellPath = Join-Path $PSHOME 'powershell.exe'
            $childArguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $tmpCliScript + '"' +
                ' -PromptPath "' + $tmpPrompt + '"' +
                ' -SystemPromptPath "' + $tmpSystemPrompt + '"' +
                ' -OutputPath "' + $tmpCliOutput + '"'
            $cliProcess = Start-Process -FilePath $shellPath -ArgumentList $childArguments -WorkingDirectory (Get-Location).Path -PassThru -Wait -NoNewWindow -ErrorAction Stop
            $exitCode = $cliProcess.ExitCode
            $raw = [System.IO.File]::ReadAllText($tmpCliOutput, $utf8)
        } else {
            $promptInput = [System.IO.File]::ReadAllText($tmpPrompt, $utf8)
            $OutputEncoding = $utf8
            $raw = $promptInput | & ai-powered text --quiet --system $system 2>&1 | Out-String
            $exitCode = $LASTEXITCODE
        }
    } catch {
        Write-Json -Level warn -Message 'ai-powered text invocation failed; skipping AI edit'
        return $null
    } finally {
        try {
            Clear-ProviderApiKeyEnvironment
        } finally {
            foreach ($temporaryPath in @($tmpPrompt, $tmpSystemPrompt, $tmpCliOutput, $tmpCliScript)) {
                if (-not [string]::IsNullOrWhiteSpace($temporaryPath)) {
                    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
    if ($exitCode -ne 0) {
        Write-Json -Level warn -Message 'ai-powered text failed; skipping AI edit' -Extra @{ exit = $exitCode }
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-Json -Level warn -Message 'ai-powered text returned no output; skipping AI edit'
        return $null
    }
    $description = 'autoresearch iteration'
    if ($raw -match '(?im)^DESCRIPTION:\s*(.+)$') { $description = $Matches[1].Trim() }
    if ($raw -notmatch '(?s)```python\s*(.+?)```') {
        Write-Json -Level warn -Message 'ai-powered response did not contain a python code fence; skipping edit'
        return @{ NewContent = $null; Description = $description }
    }
    return @{ NewContent = $Matches[1].TrimEnd("`r","`n"); Description = $description }
}

function Assert-AutoresearchGeneratedCodeReviewAvailable {
    if ($SchedulerPolicy -ne 'Interactive') {
        throw "AI-generated train.py is blocked for scheduler policy '$SchedulerPolicy' because no isolation boundary prevents access to user files and network resources. Use -NoAiEdit or run with Interactive policy and review each generated file."
    }
    if ([Console]::IsInputRedirected) {
        throw 'AI-generated train.py is blocked because an interactive review prompt is unavailable. Use -NoAiEdit or run from an interactive console.'
    }
}

function Confirm-AutoresearchGeneratedCode {
    param([Parameter(Mandatory)][string]$TrainPath)

    Assert-AutoresearchGeneratedCodeReviewAvailable
    Write-Warning 'This model-generated code runs as your account and can access your files and network.'
    Write-Host "Review the complete model-generated training file before execution: $TrainPath"
    $approval = Read-Host 'After reviewing it, type RUN REVIEWED TRAIN.PY to execute this code'
    return ($approval -ceq 'RUN REVIEWED TRAIN.PY')
}

function Get-AutoresearchProcessTreeIds {
    param([Parameter(Mandatory)][int]$RootProcessId)

    if (-not ('Autoresearch.ProcessTreeNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Autoresearch {
    public sealed class ProcessTreeEntry {
        public int ProcessId { get; private set; }
        public int ParentProcessId { get; private set; }

        public ProcessTreeEntry(int processId, int parentProcessId) {
            ProcessId = processId;
            ParentProcessId = parentProcessId;
        }
    }

    public static class ProcessTreeNative {
        private const uint TH32CS_SNAPPROCESS = 0x00000002;
        private const int ERROR_NO_MORE_FILES = 18;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct PROCESSENTRY32W {
            public uint dwSize;
            public uint cntUsage;
            public uint th32ProcessID;
            public UIntPtr th32DefaultHeapID;
            public uint th32ModuleID;
            public uint cntThreads;
            public uint th32ParentProcessID;
            public int pcPriClassBase;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
            public string szExeFile;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);

        [DllImport("kernel32.dll", EntryPoint = "Process32FirstW", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern bool Process32First(IntPtr snapshot, ref PROCESSENTRY32W entry);

        [DllImport("kernel32.dll", EntryPoint = "Process32NextW", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
        private static extern bool Process32Next(IntPtr snapshot, ref PROCESSENTRY32W entry);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        public static ProcessTreeEntry[] GetProcesses() {
            IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
            if (snapshot == new IntPtr(-1)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            try {
                var entries = new List<ProcessTreeEntry>();
                var entry = new PROCESSENTRY32W();
                entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
                if (!Process32First(snapshot, ref entry)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }

                do {
                    entries.Add(new ProcessTreeEntry(
                        unchecked((int)entry.th32ProcessID),
                        unchecked((int)entry.th32ParentProcessID)
                    ));
                    entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32W));
                } while (Process32Next(snapshot, ref entry));

                int error = Marshal.GetLastWin32Error();
                if (error != ERROR_NO_MORE_FILES) {
                    throw new Win32Exception(error);
                }
                return entries.ToArray();
            } finally {
                CloseHandle(snapshot);
            }
        }
    }
}
'@ -Language CSharp -ErrorAction Stop
    }

    $processes = @([Autoresearch.ProcessTreeNative]::GetProcesses())
    $childrenByParent = @{}
    foreach ($process in $processes) {
        $parentId = [int]$process.ParentProcessId
        if (-not $childrenByParent.ContainsKey($parentId)) {
            $childrenByParent[$parentId] = New-Object 'System.Collections.Generic.List[int]'
        }
        $childrenByParent[$parentId].Add([int]$process.ProcessId)
    }

    $descendantIds = New-Object 'System.Collections.Generic.HashSet[int]'
    $pendingIds = New-Object 'System.Collections.Generic.List[int]'
    $pendingIds.Add($RootProcessId)
    for ($index = 0; $index -lt $pendingIds.Count; $index++) {
        $parentId = $pendingIds[$index]
        if (-not $childrenByParent.ContainsKey($parentId)) { continue }
        foreach ($childId in $childrenByParent[$parentId]) {
            if ($childId -ne $RootProcessId -and $descendantIds.Add($childId)) {
                $pendingIds.Add($childId)
            }
        }
    }

    return @($descendantIds | Sort-Object)
}

function Stop-AutoresearchProcessTree {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [ValidateRange(1, 120)][int]$WaitTimeoutSeconds = 15
    )

    $rootProcessId = $Process.Id
    $observedProcesses = @{}
    $verificationAvailable = $true
    $taskkillExitCode = $null
    $initialDescendantIds = @()

    try {
        $initialDescendantIds = @(Get-AutoresearchProcessTreeIds -RootProcessId $rootProcessId)
    } catch {
        $verificationAvailable = $false
    }

    foreach ($processId in $initialDescendantIds) {
        try {
            $descendant = [System.Diagnostics.Process]::GetProcessById([int]$processId)
            if ($descendant.HasExited) {
                $descendant.Dispose()
            } else {
                $observedProcesses[[int]$processId] = $descendant
            }
        } catch {
            # A process that exited between the process snapshot and OpenProcess
            # no longer needs termination. Descendants are tracked separately.
        }
    }

    try {
        $taskkillPath = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        if (-not $Process.HasExited -and (Test-Path -LiteralPath $taskkillPath -PathType Leaf)) {
            try {
                & $taskkillPath /PID $rootProcessId /T /F 2>&1 | Out-Null
                $taskkillExitCode = $LASTEXITCODE
            } catch {
                $taskkillExitCode = -1
            }
        }

        $deadline = [DateTime]::UtcNow.AddSeconds($WaitTimeoutSeconds)
        $lastTreeIds = @()
        do {
            try {
                $lastTreeIds = @(Get-AutoresearchProcessTreeIds -RootProcessId $rootProcessId)
            } catch {
                $verificationAvailable = $false
                $lastTreeIds = @()
            }

            foreach ($processId in $lastTreeIds) {
                if ($observedProcesses.ContainsKey([int]$processId)) { continue }
                try {
                    $descendant = [System.Diagnostics.Process]::GetProcessById([int]$processId)
                    if ($descendant.HasExited) {
                        $descendant.Dispose()
                    } else {
                        $observedProcesses[[int]$processId] = $descendant
                    }
                } catch {
                    # A process that exited between the process snapshot and OpenProcess
                    # no longer needs termination. A still-listed PID remains in
                    # lastTreeIds and will keep verification from succeeding.
                }
            }

            if (-not $Process.HasExited) {
                try { $Process.Kill() } catch { }
            }
            foreach ($descendant in @($observedProcesses.Values)) {
                try {
                    if (-not $descendant.HasExited) { $descendant.Kill() }
                } catch { }
            }

            $remainingProcessIds = New-Object 'System.Collections.Generic.List[int]'
            try {
                if (-not $Process.HasExited) { $remainingProcessIds.Add($rootProcessId) }
            } catch {
                $verificationAvailable = $false
                $remainingProcessIds.Add($rootProcessId)
            }
            foreach ($processId in @($observedProcesses.Keys)) {
                try {
                    if (-not $observedProcesses[[int]$processId].HasExited) {
                        $remainingProcessIds.Add([int]$processId)
                    }
                } catch {
                    $verificationAvailable = $false
                    $remainingProcessIds.Add([int]$processId)
                }
            }
            foreach ($processId in $lastTreeIds) {
                if (-not $observedProcesses.ContainsKey([int]$processId) -and
                    -not $remainingProcessIds.Contains([int]$processId)) {
                    $remainingProcessIds.Add([int]$processId)
                }
            }

            if ($Process.HasExited -and $remainingProcessIds.Count -eq 0 -and
                $lastTreeIds.Count -eq 0 -and $verificationAvailable) {
                [void]$Process.WaitForExit()
                return [pscustomobject]@{
                    Succeeded            = $true
                    RootProcessId        = $rootProcessId
                    RemainingProcessIds  = @()
                    VerificationAvailable = $true
                    TaskkillExitCode     = $taskkillExitCode
                }
            }

            if ([DateTime]::UtcNow -ge $deadline) { break }
            Start-Sleep -Milliseconds 100
        } while ($true)

        $remaining = @($remainingProcessIds | Sort-Object -Unique)
        if ($remaining.Count -eq 0) { $remaining = @($rootProcessId) }
        return [pscustomobject]@{
            Succeeded             = $false
            RootProcessId         = $rootProcessId
            RemainingProcessIds   = $remaining
            VerificationAvailable = $verificationAvailable
            TaskkillExitCode      = $taskkillExitCode
        }
    } finally {
        foreach ($descendant in @($observedProcesses.Values)) {
            try { $descendant.Dispose() } catch { }
        }
    }
}

function Invoke-AutoresearchIteration {
    param(
        [Parameter(Mandatory)][string]$RepoRootPath,
        [Parameter(Mandatory)][string]$ResultsPath,
        [int]$PerRunTimeoutMin = 10,
        [switch]$SkipAiEdit,
        [switch]$BaselineRun,
        [string]$ExperimentBranch
    )

    $usesAiEdit = -not $SkipAiEdit -and -not $BaselineRun
    if ($usesAiEdit) {
        Assert-AutoresearchGeneratedCodeReviewAvailable
    }

    $sourceRoot = [System.IO.Path]::GetFullPath(
        (Invoke-AutoresearchGit -GitArgs @('rev-parse','--show-toplevel') -Cwd $RepoRootPath)
    )
    if ([string]::IsNullOrWhiteSpace($ExperimentBranch)) {
        $experiment = New-AutoresearchExperimentBranch -RepoRootPath $sourceRoot
        $ExperimentBranch = $experiment.Name
    } else {
        $branchCheck = Invoke-Git -GitArgs @('check-ref-format','--branch',$ExperimentBranch) -Cwd $sourceRoot
        if ($branchCheck.ExitCode -ne 0) {
            throw "Invalid autoresearch experiment branch '$ExperimentBranch'."
        }
    }

    $branchRef = "refs/heads/$ExperimentBranch"
    $branchExists = Invoke-Git -GitArgs @('show-ref','--quiet','--verify',$branchRef) -Cwd $sourceRoot
    if ($branchExists.ExitCode -ne 0) {
        throw "Autoresearch experiment branch '$ExperimentBranch' does not exist."
    }
    $startCommit = Invoke-AutoresearchGit -GitArgs @('rev-parse','--verify',$branchRef) -Cwd $sourceRoot
    $worktreesRoot = Join-Path $sourceRoot 'worktrees'
    $createdWorktreesRoot = -not (Test-Path -LiteralPath $worktreesRoot -PathType Container)
    if ($createdWorktreesRoot) {
        New-Item -ItemType Directory -Path $worktreesRoot -Force | Out-Null
    }
    $worktreePath = Join-Path $worktreesRoot ("iteration-" + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $worktreePath) {
        throw "Refusing to reuse existing autoresearch worktree path '$worktreePath'."
    }

    $description = if ($BaselineRun) { 'baseline' } else { 'autoresearch iteration' }
    $appliedEdit = $false
    $worktreeAdded = $false
    $worktreeRemoved = $false
    $iterCommit = $null
    $shortSha = '0000000'
    $status = 'crash'
    $keepCommit = $false
    $preserveWorktreeOnGitFailure = $false
    $preserveWorktreeForReview = $false
    $preserveWorktreeForUncontainedProcess = $false
    $cleanupError = $null

    try {
        [void](Invoke-AutoresearchGit -GitArgs @('worktree','add',$worktreePath,$ExperimentBranch) -Cwd $sourceRoot)
        $worktreeAdded = $true

        # Edit step (skipped on the baseline run or when -NoAiEdit is set).
        if (-not $SkipAiEdit -and -not $BaselineRun) {
            $edit = Invoke-AiPoweredEdit -RepoRootPath $worktreePath -ResultsPath $ResultsPath
            if ($null -ne $edit) {
                if ($edit.Description) { $description = $edit.Description }
                if ($edit.NewContent) {
                    Set-Content -LiteralPath (Join-Path $worktreePath 'train.py') `
                        -Value $edit.NewContent -Encoding UTF8 -NoNewline
                    $appliedEdit = $true
                    Write-Json -Level info -Message 'Applied AI-proposed edit to train.py' -Extra @{ description = $description; experimentBranch = $ExperimentBranch }
                    try {
                        if (-not (Confirm-AutoresearchGeneratedCode -TrainPath (Join-Path $worktreePath 'train.py'))) {
                            throw 'Review was not approved.'
                        }
                    } catch {
                        $preserveWorktreeForReview = $true
                        throw [System.InvalidOperationException]::new(
                            "Model-generated training code was not approved; training did not run. Candidate worktree retained for review at '$worktreePath'.",
                            $_.Exception
                        )
                    }
                }
            }
            if (-not $appliedEdit) {
                Write-Json -Level info -Message 'No edit applied this iteration' -Extra @{ description = $description; experimentBranch = $ExperimentBranch }
            }
        }

        # Each worktree has its own index. Stage only train.py and fail closed
        # unless the branch advances to a commit containing the exact bytes
        # that will be passed to uv.
        try {
            [void](Invoke-AutoresearchGit -GitArgs @('add','--','train.py') -Cwd $worktreePath)
            [void](Invoke-AutoresearchGit -GitArgs @('-c','user.name=autoresearch','-c','user.email=autoresearch@local',
                'commit','--allow-empty','-m',("autoresearch: " + $description)) -Cwd $worktreePath)
            $iterCommit = Invoke-AutoresearchGit -GitArgs @('rev-parse','HEAD') -Cwd $worktreePath
            if ($iterCommit -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') {
                throw "Git command 'git rev-parse HEAD' did not return a full commit ID."
            }
            if ($iterCommit -ceq $startCommit) {
                throw "Git command 'git commit' succeeded without advancing HEAD from '$startCommit'."
            }

            $branchCommit = Invoke-AutoresearchGit -GitArgs @('rev-parse',$branchRef) -Cwd $sourceRoot
            if ($branchCommit -cne $iterCommit) {
                throw "Git command 'git commit' did not leave the experiment branch at the expected commit."
            }
            $parentCommit = Invoke-AutoresearchGit -GitArgs @('rev-parse',('{0}^' -f $iterCommit)) -Cwd $sourceRoot
            if ($parentCommit -cne $startCommit) {
                throw "Git command 'git commit' did not advance directly from the iteration starting commit."
            }

            $committedTrainBlob = Invoke-AutoresearchGit `
                -GitArgs @('rev-parse',('{0}:train.py' -f $iterCommit)) -Cwd $sourceRoot
            $worktreeTrainBlob = Invoke-AutoresearchGit `
                -GitArgs @('hash-object','--path=train.py','--','train.py') -Cwd $worktreePath
            if ($committedTrainBlob -cne $worktreeTrainBlob) {
                throw "Git command 'git commit' does not contain the exact train.py bytes that would run."
            }
        } catch {
            $preserveWorktreeOnGitFailure = $true
            $failure = [System.InvalidOperationException]::new(
                "$($_.Exception.Message) The edited worktree was retained for review at '$worktreePath'.",
                $_.Exception
            )
            $failure.Data['AutoresearchGitVerificationFailure'] = $true
            throw $failure
        }
        $shortSha = $iterCommit.Substring(0, 7)

        # Run training inside the same isolated worktree as the edit.
        $runLog = Join-Path $worktreePath 'run.log'
        $errFile = Join-Path $worktreePath 'run.err.log'
        $checkpointRoot = Join-Path $sourceRoot 'artifacts\checkpoints'
        $trainingArguments = 'run train.py --checkpoint-root "' + $checkpointRoot + '"'
        Write-Json -Level info -Message 'Iteration: starting uv run train.py' -Extra @{ commit = $shortSha; timeoutMin = $PerRunTimeoutMin; experimentBranch = $ExperimentBranch }
        Clear-ProviderApiKeyEnvironment
        $proc = Start-Process -FilePath 'uv' -ArgumentList $trainingArguments `
            -WorkingDirectory $worktreePath -NoNewWindow -PassThru `
            -RedirectStandardOutput $runLog -RedirectStandardError $errFile
        $killed = $false
        $exitCode = $null
        if (-not $proc.WaitForExit([int]($PerRunTimeoutMin * 60 * 1000))) {
            try {
                $termination = Stop-AutoresearchProcessTree -Process $proc
            } catch {
                $termination = [pscustomobject]@{
                    Succeeded = $false
                    RemainingProcessIds = @($proc.Id)
                }
            }
            if (-not $termination.Succeeded) {
                $remainingProcessIds = @($termination.RemainingProcessIds)
                if ($remainingProcessIds.Count -eq 0) { $remainingProcessIds = @($proc.Id) }
                $pidList = ($remainingProcessIds -join ', ')
                $diagnostic = "Timeout cleanup could not verify or terminate the training process tree. Remaining or unverified PID(s): $pidList. The worktree is retained and the autoresearch loop will stop."
                $preserveWorktreeForUncontainedProcess = $true
                $status = 'uncontained-process'
                try {
                    Write-Json -Level error -Message $diagnostic -Extra @{
                        status = $status
                        processIds = $remainingProcessIds
                    }
                    Write-Warning $diagnostic
                } catch {
                    $failure = [System.InvalidOperationException]::new($diagnostic, $_.Exception)
                    $failure.Data['AutoresearchUncontainedProcess'] = $true
                    throw $failure
                }
                return @{
                    Commit = $shortSha; ValBpb = 0.0; MemoryGb = 0.0; Status = $status
                    Description = $description; ExperimentBranch = $ExperimentBranch
                    WorktreePath = $worktreePath; ExitCode = $null
                    RemainingProcessIds = $remainingProcessIds
                }
            }
            $killed = $true
            $exitCode = $proc.ExitCode
            Write-Json -Level warn -Message 'Iteration exceeded per-run timeout; killed' -Extra @{ commit = $shortSha; experimentBranch = $ExperimentBranch }
        } else {
            $exitCode = $proc.ExitCode
        }
        [void](Invoke-CheckpointRetention -RepositoryRootPath $sourceRoot)
        # Merge stderr file into run.log so downstream parsing is unified.
        if (Test-Path -LiteralPath $errFile) {
            Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue | Add-Content -LiteralPath $runLog -Encoding UTF8
            Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
        }
        $metrics = Read-RunLogMetrics -Path $runLog
        $valBpb  = $metrics.ValBpb
        $memGb   = if ($metrics.PeakVramMb -gt 0) { $metrics.PeakVramMb / 1024.0 } else { 0.0 }

        # Decide outcome.
        if (-not $killed -and $exitCode -eq 0 -and $valBpb -gt 0) {
            $best = Get-CurrentBestValBpb -Path $ResultsPath
            if ($BaselineRun -or $null -eq $best -or $valBpb -lt $best) {
                $status = 'keep'
            } else {
                $status = 'discard'
            }
        }

        Add-ResultsTsvRow -Path $ResultsPath -Commit $shortSha `
            -ValBpb $valBpb -MemoryGb $memGb -Status $status -Description $description
        $keepCommit = ($status -eq 'keep')

        Write-Json -Level info -Message 'Iteration finished' -Extra @{
            commit = $shortSha; exitCode = $exitCode; valBpb = $valBpb; memoryGb = $memGb; status = $status
            description = $description; experimentBranch = $ExperimentBranch
        }
    }
    finally {
        if ($worktreeAdded -and -not $preserveWorktreeOnGitFailure -and -not $preserveWorktreeForReview -and -not $preserveWorktreeForUncontainedProcess) {
            $removeResult = Invoke-Git -GitArgs @('worktree','remove','--force',$worktreePath) -Cwd $sourceRoot
            if ($removeResult.ExitCode -eq 0) {
                $worktreeRemoved = $true
            } else {
                $cleanupError = "Unable to remove isolated autoresearch worktree '$worktreePath': $($removeResult.Output)"
            }
        }

        if ($worktreeRemoved -and -not $keepCommit -and -not $preserveWorktreeOnGitFailure -and -not $preserveWorktreeForReview -and -not $preserveWorktreeForUncontainedProcess) {
            $rewindResult = Invoke-Git -GitArgs @('branch','--force',$ExperimentBranch,$startCommit) -Cwd $sourceRoot
            if ($rewindResult.ExitCode -ne 0) {
                $cleanupError = "Unable to discard the isolated experiment branch '$ExperimentBranch': $($rewindResult.Output)"
            }
        }

        if ($createdWorktreesRoot -and (Test-Path -LiteralPath $worktreesRoot -PathType Container)) {
            $remaining = @(Get-ChildItem -LiteralPath $worktreesRoot -Force -ErrorAction SilentlyContinue)
            if ($remaining.Count -eq 0) {
                Remove-Item -LiteralPath $worktreesRoot -Force -ErrorAction SilentlyContinue
            }
        }

        if ($cleanupError) { throw $cleanupError }
    }

    return @{ Commit = $shortSha; ExitCode = $exitCode; ValBpb = $valBpb; MemoryGb = $memGb; Status = $status; Description = $description; ExperimentBranch = $ExperimentBranch; WorktreePath = $worktreePath }
}

function Get-AutoresearchLoopLockIdentity {
    param([Parameter(Mandatory)][string]$RepoRootPath)

    $rootResult = Invoke-Git -GitArgs @('rev-parse','--show-toplevel') -Cwd $RepoRootPath
    if ($rootResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($rootResult.Output)) {
        throw "Unable to resolve the repository root for the autoresearch loop lock (git rev-parse exited $($rootResult.ExitCode))."
    }

    $repositoryRoot = [System.IO.Path]::GetFullPath($rootResult.Output.Trim())
    $normalizedRoot = $repositoryRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $rootBytes = [System.Text.Encoding]::UTF8.GetBytes($normalizedRoot.ToUpperInvariant())
        $hashBytes = $sha256.ComputeHash($rootBytes)
        $rootHash = [System.BitConverter]::ToString($hashBytes).Replace('-', '')
    } finally {
        $sha256.Dispose()
    }

    return [pscustomobject]@{
        RepositoryRoot = $repositoryRoot
        MutexName      = "Global\myTech.Today.AutoresearchLoop.$rootHash"
        OwnerPath      = Join-Path ([System.IO.Path]::GetTempPath()) "myTech.Today-AutoresearchLoop-$rootHash.owner.json"
    }
}

function Read-AutoresearchLoopLockOwner {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [System.IO.File]::Exists($Path)) { return $null }
    $stream = $null
    $reader = $null
    try {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
        $json = $reader.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($json)) { return $null }
        $owner = $json | ConvertFrom-Json -ErrorAction Stop
        $ownerProcessId = 0
        if ([int]::TryParse([string]$owner.ProcessId, [ref]$ownerProcessId) -and $ownerProcessId -gt 0 -and
            -not [string]::IsNullOrWhiteSpace([string]$owner.ProcessStartTimeUtc)) {
            return $owner
        }
    } catch {
        return $null
    } finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        } elseif ($null -ne $stream) {
            $stream.Dispose()
        }
    }
    return $null
}

function Format-AutoresearchLoopLockBusyMessage {
    param([Parameter()][psobject]$Owner)

    if ($null -ne $Owner) {
        $startTime = [string]$Owner.ProcessStartTimeUtc
        if ($Owner.ProcessStartTimeUtc -is [DateTime]) {
            $startTime = $Owner.ProcessStartTimeUtc.ToUniversalTime().ToString('o')
        }
        return "Autoresearch loop busy: the repository lock is held (last recorded PID $($Owner.ProcessId), started $startTime). This invocation exited before touching repository, results, or logs."
    }
    return 'Autoresearch loop busy: another process holds the repository lock. This invocation exited before touching repository, results, or logs.'
}

function Enter-AutoresearchLoopLock {
    param([Parameter(Mandatory)][string]$RepoRootPath)

    $identity = Get-AutoresearchLoopLockIdentity -RepoRootPath $RepoRootPath
    $mutex = [System.Threading.Mutex]::new($false, $identity.MutexName)
    $acquired = $false
    $abandoned = $false
    try {
        $acquired = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        # Windows grants ownership when it reports abandonment. This kernel
        # state, not a PID check or timeout, is the stale-owner authority.
        $acquired = $true
        $abandoned = $true
    } catch {
        $mutex.Dispose()
        throw
    }

    if (-not $acquired) {
        try {
            $owner = Read-AutoresearchLoopLockOwner -Path $identity.OwnerPath
            return [pscustomobject]@{
                Acquired                 = $false
                Mutex                    = $null
                MutexName                = $identity.MutexName
                OwnerPath                = $identity.OwnerPath
                Owner                    = $owner
                PreviousOwner            = $null
                RecoveredStaleOwner      = $false
                RepositoryRoot           = $identity.RepositoryRoot
            }
        } finally {
            $mutex.Dispose()
        }
    }

    $previousOwner = Read-AutoresearchLoopLockOwner -Path $identity.OwnerPath
    $recoveredStaleOwner = $abandoned
    if (-not $recoveredStaleOwner -and $null -ne $previousOwner) {
        # Once WaitOne has granted this mutex, the prior record can describe a
        # dead process even when Windows has already removed the old mutex
        # object. PID plus process start time detects that stale record; it is
        # never used to take a lock from a process that still owns the mutex.
        $previousStartTimeTicks = [long]0
        $hasPreviousStartTime = [long]::TryParse(
            [string]$previousOwner.ProcessStartTimeUtcTicks,
            [ref]$previousStartTimeTicks
        )
        $previousProcess = Get-Process -Id ([int]$previousOwner.ProcessId) -ErrorAction SilentlyContinue
        if ($null -eq $previousProcess -or -not $hasPreviousStartTime) {
            $recoveredStaleOwner = $true
        } else {
            try {
                if ($previousProcess.StartTime.ToUniversalTime().Ticks -ne $previousStartTimeTicks) {
                    $recoveredStaleOwner = $true
                }
            } catch {
                $recoveredStaleOwner = $true
            }
        }
    }
    $temporaryPath = "$($identity.OwnerPath).$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $process = Get-Process -Id $PID -ErrorAction Stop
        $processStartTimeUtc = $process.StartTime.ToUniversalTime()
        $owner = [pscustomobject]@{
            ProcessId            = [int]$PID
            ProcessStartTimeUtc  = $processStartTimeUtc.ToString('o')
            ProcessStartTimeUtcTicks = [long]$processStartTimeUtc.Ticks
            RepositoryRoot       = $identity.RepositoryRoot
        }
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($temporaryPath, ($owner | ConvertTo-Json -Compress), $utf8)
        if ([System.IO.File]::Exists($identity.OwnerPath)) {
            [System.IO.File]::Delete($identity.OwnerPath)
        }
        # The mutex is the lock. A busy observer may briefly see no diagnostic
        # owner record between these operations and will still fail closed.
        [System.IO.File]::Move($temporaryPath, $identity.OwnerPath)
        return [pscustomobject]@{
            Acquired                 = $true
            Mutex                    = $mutex
            MutexName                = $identity.MutexName
            OwnerPath                = $identity.OwnerPath
            Owner                    = $owner
            PreviousOwner            = $previousOwner
            RecoveredStaleOwner      = $recoveredStaleOwner
            RepositoryRoot           = $identity.RepositoryRoot
        }
    } catch {
        try {
            if ([System.IO.File]::Exists($temporaryPath)) {
                [System.IO.File]::Delete($temporaryPath)
            }
        } catch { }
        try {
            $mutex.ReleaseMutex()
        } finally {
            $mutex.Dispose()
        }
        throw
    }
}

function Exit-AutoresearchLoopLock {
    param([Parameter(Mandatory)][psobject]$Lock)

    if (-not $Lock.Acquired -or $null -eq $Lock.Mutex) { return }
    try {
        $recordedOwner = Read-AutoresearchLoopLockOwner -Path $Lock.OwnerPath
        $recordedStartTimeTicks = [long]0
        $hasRecordedStartTime = $null -ne $recordedOwner -and [long]::TryParse(
            [string]$recordedOwner.ProcessStartTimeUtcTicks,
            [ref]$recordedStartTimeTicks
        )
        if ($hasRecordedStartTime -and
            $recordedOwner.ProcessId -eq $Lock.Owner.ProcessId -and
            $recordedStartTimeTicks -eq $Lock.Owner.ProcessStartTimeUtcTicks) {
            [System.IO.File]::Delete($Lock.OwnerPath)
        }
    } catch {
        # The metadata is diagnostic; the named mutex alone controls access.
    } finally {
        try {
            $Lock.Mutex.ReleaseMutex()
        } finally {
            $Lock.Mutex.Dispose()
        }
    }
}

function Get-AutoresearchLoopTime {
    return [DateTime]::UtcNow
}

function Get-AutoresearchLoopBackoffDelayMilliseconds {
    param([Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ConsecutiveFailureCount)

    $exponent = [Math]::Min(($ConsecutiveFailureCount - 1), 4)
    $delay = [Math]::Min(60000.0, (5000.0 * [Math]::Pow(2.0, $exponent)))
    return [int]$delay
}

function Start-AutoresearchLoopSleep {
    param([Parameter(Mandatory)][ValidateRange(1, 60000)][int]$Milliseconds)

    Start-Sleep -Milliseconds $Milliseconds
}

function Wait-AutoresearchLoopBackoff {
    param(
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ConsecutiveFailureCount,
        [Parameter(Mandatory)][DateTime]$Deadline
    )

    $delayMilliseconds = Get-AutoresearchLoopBackoffDelayMilliseconds -ConsecutiveFailureCount $ConsecutiveFailureCount
    if ($Deadline -ne [DateTime]::MaxValue) {
        $remainingMilliseconds = ($Deadline - (Get-AutoresearchLoopTime)).TotalMilliseconds
        if ($remainingMilliseconds -le 0) { return 0 }
        $delayMilliseconds = [int][Math]::Min($delayMilliseconds, [Math]::Ceiling($remainingMilliseconds))
    }

    if ($delayMilliseconds -gt 0) {
        Start-AutoresearchLoopSleep -Milliseconds $delayMilliseconds
    }
    return $delayMilliseconds
}

function Write-AutoresearchLoopTerminalSummary {
    param(
        [Parameter(Mandatory)][string]$TerminalStatus,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][int]$AttemptedIterations,
        [Parameter(Mandatory)][int]$SuccessfulIterations,
        [Parameter(Mandatory)][int]$FailedIterations,
        [Parameter(Mandatory)][int]$ConsecutiveFailureCount,
        [Parameter(Mandatory)][int]$FailureThreshold,
        [AllowEmptyString()][string]$ExperimentBranch
    )

    $level = if ($ExitCode -eq 0) { 'info' } else { 'error' }
    Write-Json -Level $level -Message "Autoresearch loop finished with status '$TerminalStatus'." -Extra @{
        status                    = $TerminalStatus
        exitCode                  = $ExitCode
        attemptedIterations       = $AttemptedIterations
        successfulIterations      = $SuccessfulIterations
        failedIterations          = $FailedIterations
        consecutiveFailures       = $ConsecutiveFailureCount
        consecutiveFailureLimit   = $FailureThreshold
        experimentBranch          = $ExperimentBranch
    }
}

function Invoke-AutoresearchLoopCore {
    Assert-AutoresearchSourceCheckoutClean -RepoRootPath $RepoRoot
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $Script:RunLogPath = Join-Path $LogDir "autoresearch-loop-$stamp.jsonl"
    New-Item -ItemType File -Path $Script:RunLogPath -Force | Out-Null

    if (-not $NoAiEdit) {
        Assert-AutoresearchGeneratedCodeReviewAvailable
    }

    if (-not (Invoke-IdlePolicyGate -Policy $SchedulerPolicy -IdleMinutes 5 -WaitTimeoutMinutes 60)) {
        Write-AutoresearchLoopTerminalSummary -TerminalStatus 'idle-policy-skipped' -ExitCode 0 `
            -AttemptedIterations 0 -SuccessfulIterations 0 -FailedIterations 0 -ConsecutiveFailureCount 0 `
            -FailureThreshold $MaxConsecutiveIterationFailures -ExperimentBranch ''
        Limit-RunLogs
        return 0
    }

    # Experiments then advance only this retained branch, never the user's
    # source branch or index.
    $experiment = New-AutoresearchExperimentBranch -RepoRootPath $RepoRoot
    $experimentBranch = $experiment.Name

    Set-WorkloadEnvironment

    $resultsPath = Join-Path $RepoRoot 'results.tsv'
    Initialize-ResultsTsv -Path $resultsPath

    $loopStartedAt = Get-AutoresearchLoopTime
    $deadline = if ($MaxLoopMinutes -gt 0) { $loopStartedAt.AddMinutes($MaxLoopMinutes) } else { [DateTime]::MaxValue }
    Write-Json -Level info -Message 'Starting autoresearch loop' -Extra @{
        repoRoot                         = $RepoRoot
        runLog                           = $Script:RunLogPath
        resultsTsv                       = $resultsPath
        maxLoopMinutes                   = $MaxLoopMinutes
        maxConsecutiveIterationFailures  = $MaxConsecutiveIterationFailures
        retryBackoffBaseMilliseconds     = 5000
        retryBackoffMaximumMilliseconds  = 60000
        perRunTimeoutMinutes             = $PerRunTimeoutMinutes
        noAiEdit                         = [bool]$NoAiEdit
        experimentBranch                 = $experimentBranch
        schedulerPolicy                  = $SchedulerPolicy
        policySummary                    = (Get-SchedulerPolicyInfo -Policy $SchedulerPolicy).Summary
        deadline                         = if ($deadline -eq [DateTime]::MaxValue) { 'none' } else { $deadline.ToString('o') }
    }

    # Baseline iteration first if results.tsv is empty (only the header row).
    $hasBaseline = $false
    if (Test-Path -LiteralPath $resultsPath) {
        $rowCount = @(
            Get-Content -LiteralPath $resultsPath -Encoding UTF8 |
                Where-Object { $_ -and $_ -notmatch '^commit\t' }
        ).Count
        $hasBaseline = ($rowCount -gt 0)
    }
    $baselinePending = -not $hasBaseline
    $attemptedIterations = 0
    $successfulIterations = 0
    $failedIterations = 0
    $consecutiveFailures = 0

    while ($baselinePending -or ((Get-AutoresearchLoopTime) -lt $deadline)) {
        $isBaselineRun = $baselinePending
        $baselinePending = $false
        $attemptedIterations++
        $iterationNumber = $attemptedIterations
        $iterationResult = $null
        $iterationErrorRecord = $null
        $iterationStatus = 'missing-result'
        $fatalExitCode = 0

        if ($isBaselineRun) {
            Write-Json -Level info -Message 'No baseline row in results.tsv; running baseline iteration' -Extra @{
                iteration = $iterationNumber
            }
        } else {
            Write-Json -Level info -Message "Autoresearch iteration #$iterationNumber starting"
        }

        try {
            if ($isBaselineRun) {
                $iterationResult = Invoke-AutoresearchIteration -RepoRootPath $RepoRoot -ResultsPath $resultsPath `
                    -PerRunTimeoutMin $PerRunTimeoutMinutes -BaselineRun -ExperimentBranch $experimentBranch
            } else {
                $iterationResult = Invoke-AutoresearchIteration -RepoRootPath $RepoRoot -ResultsPath $resultsPath `
                    -PerRunTimeoutMin $PerRunTimeoutMinutes -SkipAiEdit:$NoAiEdit -ExperimentBranch $experimentBranch
            }
        } catch {
            $iterationErrorRecord = $_
            $iterationException = $_.Exception
            $failureMessage = $iterationException.Message
            Write-Json -Level error -Message "Iteration #$iterationNumber raised: $failureMessage" -Extra @{
                baseline = [bool]$isBaselineRun
            }
            if ($iterationException.Data.Contains('AutoresearchGitVerificationFailure')) {
                $fatalExitCode = 1
                $iterationStatus = 'git-verification-failure'
            } elseif ($iterationException.Data.Contains('AutoresearchUncontainedProcess')) {
                $fatalExitCode = 3
                $iterationStatus = 'uncontained-process'
            }
        }

        if ($iterationResult -is [System.Collections.IDictionary]) {
            if ($iterationResult.Contains('Status') -and
                -not [string]::IsNullOrWhiteSpace([string]$iterationResult['Status'])) {
                $iterationStatus = [string]$iterationResult['Status']
            }
        } elseif ($null -ne $iterationResult) {
            $statusProperty = $iterationResult.PSObject.Properties['Status']
            if ($null -ne $statusProperty -and -not [string]::IsNullOrWhiteSpace([string]$statusProperty.Value)) {
                $iterationStatus = [string]$statusProperty.Value
            }
        }
        if ($iterationStatus -ceq 'uncontained-process') {
            $fatalExitCode = 3
        }

        if ($null -eq $iterationErrorRecord -and $iterationStatus -in @('keep', 'discard')) {
            $successfulIterations++
            $consecutiveFailures = 0
        } else {
            $failedIterations++
            $consecutiveFailures++
        }

        $outcomeLevel = if ($null -eq $iterationErrorRecord -and $iterationStatus -in @('keep', 'discard')) { 'info' } else { 'warn' }
        Write-Json -Level $outcomeLevel -Message "Iteration #$iterationNumber recorded as '$iterationStatus'." -Extra @{
            baseline             = [bool]$isBaselineRun
            attemptedIterations  = $attemptedIterations
            successfulIterations = $successfulIterations
            failedIterations     = $failedIterations
            consecutiveFailures  = $consecutiveFailures
            failureLimit         = $MaxConsecutiveIterationFailures
        }

        if ($fatalExitCode -ne 0) {
            $terminalStatus = if ($fatalExitCode -eq 1) { 'git-verification-failure' } else { 'uncontained-process' }
            Write-AutoresearchLoopTerminalSummary -TerminalStatus $terminalStatus -ExitCode $fatalExitCode `
                -AttemptedIterations $attemptedIterations -SuccessfulIterations $successfulIterations `
                -FailedIterations $failedIterations -ConsecutiveFailureCount $consecutiveFailures `
                -FailureThreshold $MaxConsecutiveIterationFailures -ExperimentBranch $experimentBranch
            Limit-RunLogs
            return $fatalExitCode
        }

        if ($consecutiveFailures -ge $MaxConsecutiveIterationFailures) {
            Write-Json -Level error -Message 'Consecutive iteration-failure limit reached; stopping autoresearch loop.' -Extra @{
                consecutiveFailures      = $consecutiveFailures
                consecutiveFailureLimit  = $MaxConsecutiveIterationFailures
            }
            Write-AutoresearchLoopTerminalSummary -TerminalStatus 'failure-threshold' -ExitCode 4 `
                -AttemptedIterations $attemptedIterations -SuccessfulIterations $successfulIterations `
                -FailedIterations $failedIterations -ConsecutiveFailureCount $consecutiveFailures `
                -FailureThreshold $MaxConsecutiveIterationFailures -ExperimentBranch $experimentBranch
            Limit-RunLogs
            return 4
        }

        if ($iterationStatus -cne 'keep' -and $iterationStatus -cne 'discard') {
            $backoffMilliseconds = Wait-AutoresearchLoopBackoff -ConsecutiveFailureCount $consecutiveFailures -Deadline $deadline
            Write-Json -Level warn -Message 'Waiting before retrying a failed autoresearch iteration.' -Extra @{
                delayMilliseconds     = $backoffMilliseconds
                consecutiveFailures   = $consecutiveFailures
                failureLimit          = $MaxConsecutiveIterationFailures
                attemptedIterations   = $attemptedIterations
            }
        }
    }

    Write-Json -Level info -Message 'Autoresearch loop deadline reached; exiting' -Extra @{
        attemptedIterations  = $attemptedIterations
        successfulIterations = $successfulIterations
        failedIterations     = $failedIterations
        experimentBranch     = $experimentBranch
    }
    if ($successfulIterations -eq 0) {
        Write-AutoresearchLoopTerminalSummary -TerminalStatus 'deadline-no-success' -ExitCode 4 `
            -AttemptedIterations $attemptedIterations -SuccessfulIterations $successfulIterations `
            -FailedIterations $failedIterations -ConsecutiveFailureCount $consecutiveFailures `
            -FailureThreshold $MaxConsecutiveIterationFailures -ExperimentBranch $experimentBranch
        Limit-RunLogs
        return 4
    }

    Write-AutoresearchLoopTerminalSummary -TerminalStatus 'deadline-complete' -ExitCode 0 `
        -AttemptedIterations $attemptedIterations -SuccessfulIterations $successfulIterations `
        -FailedIterations $failedIterations -ConsecutiveFailureCount $consecutiveFailures `
        -FailureThreshold $MaxConsecutiveIterationFailures -ExperimentBranch $experimentBranch
    Limit-RunLogs
    return 0
}

function Invoke-AutoresearchLoop {
    $existingLockVariable = Get-Variable -Scope Script -Name AutoresearchLoopLock -ErrorAction SilentlyContinue
    $lock = if ($null -ne $existingLockVariable) { $existingLockVariable.Value } else { $null }
    $ownsLock = $false
    if ($null -eq $lock -or -not $lock.Acquired) {
        $lock = Enter-AutoresearchLoopLock -RepoRootPath $RepoRoot
        if (-not $lock.Acquired) {
            Write-Host (Format-AutoresearchLoopLockBusyMessage -Owner $lock.Owner) -ForegroundColor Yellow
            return 2
        }
        $ownsLock = $true
    }

    try {
        if ($lock.RecoveredStaleOwner) {
            $recoveryDetails = @{ staleOwnerRecovered = $true }
            if ($null -ne $lock.PreviousOwner) {
                $recoveryDetails.staleOwnerProcessId = $lock.PreviousOwner.ProcessId
                $recoveryDetails.staleOwnerStartTimeUtc = $lock.PreviousOwner.ProcessStartTimeUtc
            }
            Write-Json -Level warn -Message 'Recovered a stale autoresearch repository lock owner' -Extra $recoveryDetails
        }
        return Invoke-AutoresearchLoopCore
    } finally {
        if ($ownsLock) {
            Exit-AutoresearchLoopLock -Lock $lock
        }
    }
}

function Get-PwshExePath {
    $commandNames = @('pwsh.exe', 'pwsh')
    if (Test-WindowsHost) {
        $commandNames += @('powershell.exe', 'powershell')
    }

    foreach ($commandName in $commandNames) {
        $candidates = @(Get-Command -Name $commandName -CommandType Application -ErrorAction SilentlyContinue)
        foreach ($candidate in $candidates) {
            $candidatePath = $candidate.Source
            if ([string]::IsNullOrWhiteSpace($candidatePath)) {
                $candidatePath = $candidate.Definition
            }
            if (-not [string]::IsNullOrWhiteSpace($candidatePath) -and
                (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
                return $candidatePath
            }
        }
    }

    $message = 'No compatible PowerShell executable was found. Install PowerShell 7 (pwsh.exe) or use Windows PowerShell 5.1 (powershell.exe), ' +
        'and ensure the executable is available on PATH before registering the task.'
    throw $message
}

function Get-ScheduleTimeOptions {
    param([Parameter(Mandatory)][string]$Frequency)
    switch ($Frequency) {
        'Hourly' { return ,@(':00',':10',':20',':30',':40',':50') }
        'Weekly' { return ,@('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday') }
        default  {
            $list = New-Object System.Collections.Generic.List[string]
            for ($h = 0; $h -lt 24; $h++) {
                foreach ($m in 0,15,30,45) { $list.Add(('{0:D2}:{1:D2}' -f $h, $m)) }
            }
            return ,$list.ToArray()
        }
    }
}

function Get-ScheduleTimeDefault {
    param([Parameter(Mandatory)][string]$Frequency)
    switch ($Frequency) {
        'Hourly' { return ':00' }
        'Weekly' { return 'Sunday' }
        default  { return '18:00' }
    }
}

function Test-ScheduleTime {
    param(
        [Parameter(Mandatory)][string]$Frequency,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    $allowed = Get-ScheduleTimeOptions -Frequency $Frequency
    if ($allowed -notcontains $Value) {
        throw "ScheduleTime '$Value' is not valid for ScheduleFrequency '$Frequency'. Expected one of: $($allowed -join ', ')."
    }
}

function Get-TaskTrigger {
    Test-ScheduleTime -Frequency $ScheduleFrequency -Value $ScheduleTime
    switch ($ScheduleFrequency) {
        'Hourly' {
            $minute = [int]($ScheduleTime.TrimStart(':'))
            $startAt = ([DateTime]::Today).AddMinutes($minute)
            return New-ScheduledTaskTrigger -Once -At $startAt -RepetitionInterval (New-TimeSpan -Hours 1)
        }
        'Daily' {
            $startAt = ([DateTime]::Today).Add([TimeSpan]::Parse($ScheduleTime))
            return New-ScheduledTaskTrigger -Daily -At $startAt
        }
        'Weekly' {
            $startAt = ([DateTime]::Today).AddHours(3)
            return New-ScheduledTaskTrigger -Weekly -DaysOfWeek $ScheduleTime -At $startAt
        }
    }
}

function Get-SchedulerPolicyInfo {
    param([Parameter(Mandatory)][string]$Policy)
    switch ($Policy) {
        'Interactive' {
            return [pscustomobject]@{
                Name                  = 'Interactive'
                DisplayName           = 'Interactive'
                Summary               = 'Runs only while the current user is logged on. No idle wait window is applied.'
                LogonType             = 3
                LogonTypeName         = 'InteractiveToken'
                RequiresDesktopSession = $true
                UsesIdleGate          = $false
                IdleDuration          = $null
                IdleWaitTimeout       = $null
            }
        }
        'IdleOnly' {
            return [pscustomobject]@{
                Name                  = 'IdleOnly'
                DisplayName           = 'Idle-only interactive'
                Summary               = 'Runs while the current user is logged on and the launcher waits for 5 minutes of idle time before starting. If the wait window expires, the launcher logs why the run was skipped.'
                LogonType             = 3
                LogonTypeName         = 'InteractiveToken'
                RequiresDesktopSession = $true
                UsesIdleGate          = $true
                IdleDuration          = 'PT5M'
                IdleWaitTimeout       = 'PT1H'
            }
        }
        'Unattended' {
            return [pscustomobject]@{
                Name                  = 'Unattended'
                DisplayName           = 'Unattended'
                Summary               = 'Runs without an active desktop session by using S4U logon. No idle wait window is applied.'
                LogonType             = 2
                LogonTypeName         = 'S4U'
                RequiresDesktopSession = $false
                UsesIdleGate          = $false
                IdleDuration          = $null
                IdleWaitTimeout       = $null
            }
        }
    }
}

function Get-ScheduleTriggerSpec {
    param(
        [Parameter(Mandatory)][string]$Frequency,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    Test-ScheduleTime -Frequency $Frequency -Value $Value
    switch ($Frequency) {
        'Hourly' {
            $minute = [int]($Value.TrimStart(':'))
            return [pscustomobject]@{
                Kind          = 'Hourly'
                StartBoundary = ([DateTime]::Today).AddMinutes($minute)
                Repetition    = 'PT1H'
            }
        }
        'Daily' {
            return [pscustomobject]@{
                Kind          = 'Daily'
                StartBoundary = ([DateTime]::Today).Add([TimeSpan]::Parse($Value))
                DaysInterval  = 1
            }
        }
        'Weekly' {
            return [pscustomobject]@{
                Kind          = 'Weekly'
                StartBoundary = ([DateTime]::Today).AddHours(3)
                DaysOfWeek    = ConvertTo-WeekdayMask -DayName $Value
                WeeksInterval = 1
            }
        }
    }
}

function ConvertTo-WeekdayMask {
    param([Parameter(Mandatory)][string]$DayName)
    switch ($DayName) {
        'Sunday'    { return 1 }
        'Monday'    { return 2 }
        'Tuesday'   { return 4 }
        'Wednesday' { return 8 }
        'Thursday'  { return 16 }
        'Friday'    { return 32 }
        'Saturday'  { return 64 }
        default {
            throw "Unsupported weekday '$DayName'."
        }
    }
}

function Get-TaskLauncherPlan {
    $powerShellPath = Get-PwshExePath
    $scriptPath = $Script:CanonicalScript
    $commonArgs = @(
        '-Provider', $Provider,
        '-Model', $Model,
        '-SchedulerPolicy', $SchedulerPolicy,
        '-MaxLoopMinutes', $MaxLoopMinutes,
        '-MaxConsecutiveIterationFailures', $MaxConsecutiveIterationFailures,
        '-PerRunTimeoutMinutes', $PerRunTimeoutMinutes
    )
    if ($Provider -eq 'ollama') {
        $commonArgs += @('-OllamaHost', $OllamaHost)
    }
    if ($NoAiEdit) {
        $commonArgs += '-NoAiEdit'
    }

    $childArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath,
                      '-NoGui', '-RunLoop') + $commonArgs
    $taskArgList  = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath,
                      '-NoGui', '-TaskSupervisor') + $commonArgs
    $childArgs = Format-CommandLineArgumentList -Arguments $childArgList
    $taskArgs  = Format-CommandLineArgumentList -Arguments $taskArgList

    return [pscustomobject]@{
        PowerShellPath         = $powerShellPath
        ScriptPath             = $scriptPath
        InnerArgList           = $childArgList
        TaskActionArgList      = $taskArgList
        TaskActionArguments    = $taskArgs
        TaskActionCommand      = Format-CommandLine -FilePath $powerShellPath -Arguments $taskArgList
        WorkloadArguments      = $childArgs
        WorkloadCommand        = Format-CommandLine -FilePath $powerShellPath -Arguments $childArgList
        TaskLaunchStatePath    = (Get-TaskLaunchStatePath)
    }
}

function Invoke-TaskLaunchSupervisor {
    $plan = Get-TaskLauncherPlan
    $parentCommandLine = Get-CurrentProcessCommandLine
    if ([string]::IsNullOrWhiteSpace($parentCommandLine)) {
        $parentCommandLine = $plan.TaskActionCommand
    }
    $parentCommandLine = Get-RedactedTaskLaunchCommandLine -CommandLine $parentCommandLine

    $state = [ordered]@{
        schemaVersion      = 1
        startedUtc         = (Get-Date).ToUniversalTime().ToString('o')
        status             = 'starting'
        parentPid          = $PID
        parentCommandLine  = $parentCommandLine
        childPid           = $null
        childCommandLine   = $plan.WorkloadCommand
        taskActionCommand  = $plan.TaskActionCommand
        childExitCode      = $null
        finishedUtc        = $null
        provider           = $Provider
        model              = $Model
        schedulerPolicy    = $SchedulerPolicy
        repoRoot           = $RepoRoot
        logDir             = $LogDir
        statePath          = $plan.TaskLaunchStatePath
    }
    Write-TaskLaunchState -State $state
    Write-Json -Level info -Message 'Task supervisor launching hidden run-loop child' -Extra @{
        parentPid         = $PID
        childCommand      = $plan.WorkloadCommand
        taskActionCommand = $plan.TaskActionCommand
        statePath         = $plan.TaskLaunchStatePath
        schedulerPolicy   = $SchedulerPolicy
    }

    try {
        $child = Start-Process -FilePath $plan.PowerShellPath -ArgumentList $plan.InnerArgList `
            -WorkingDirectory $RepoRoot -WindowStyle Hidden -PassThru -Wait
    } catch {
        $state.status = 'spawn-failed'
        $state.finishedUtc = (Get-Date).ToUniversalTime().ToString('o')
        $state.failure = $_.Exception.Message
        Write-TaskLaunchState -State $state
        Write-Json -Level error -Message "Task supervisor failed to start hidden child: $($_.Exception.Message)" -Extra @{
            statePath       = $plan.TaskLaunchStatePath
            childCommand    = $plan.WorkloadCommand
            taskActionCommand = $plan.TaskActionCommand
        }
        return 1
    }

    $state.childPid = $child.Id
    $state.status = 'running'
    $state.startedChildUtc = (Get-Date).ToUniversalTime().ToString('o')
    Write-TaskLaunchState -State $state
    Write-Json -Level info -Message 'Task supervisor child started' -Extra @{
        childPid        = $child.Id
        childCommand    = $plan.WorkloadCommand
        statePath       = $plan.TaskLaunchStatePath
    }

    $exitCode = 1
    try {
        try { $child.Refresh() } catch { }
        $exitCode = [int]$child.ExitCode
    } catch {
        $state.status = 'wait-failed'
        $state.finishedUtc = (Get-Date).ToUniversalTime().ToString('o')
        $state.failure = $_.Exception.Message
        Write-TaskLaunchState -State $state
        Write-Json -Level error -Message "Task supervisor could not read hidden child exit code: $($_.Exception.Message)" -Extra @{
            childPid      = $child.Id
            statePath     = $plan.TaskLaunchStatePath
            childCommand  = $plan.WorkloadCommand
        }
        return 1
    }

    $state.childExitCode = $exitCode
    $state.finishedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $state.status = if ($exitCode -eq 0) { 'succeeded' } else { 'failed' }
    Write-TaskLaunchState -State $state
    if ($exitCode -eq 0) {
        Write-Json -Level info -Message 'Task supervisor child exited successfully' -Extra @{
            childPid     = $child.Id
            exitCode     = $exitCode
            childCommand = $plan.WorkloadCommand
            statePath    = $plan.TaskLaunchStatePath
        }
    } else {
        Write-Json -Level error -Message 'Task supervisor child exited with failure' -Extra @{
            childPid     = $child.Id
            exitCode     = $exitCode
            childCommand = $plan.WorkloadCommand
            statePath    = $plan.TaskLaunchStatePath
        }
    }

    return $exitCode
}

function Get-ScheduledTaskDescription {
    param([Parameter(Mandatory)]$PolicyInfo)
    return "Autoresearch: uv run train.py via ai-powered. Policy: $($PolicyInfo.DisplayName). $($PolicyInfo.Summary)"
}

function Get-ComputerIdleState {
    param(
        [Parameter(DontShow)]
        [psobject]$TestNativeSample
    )

    if (-not (Test-WindowsHost) -and -not $PSBoundParameters.ContainsKey('TestNativeSample')) {
        return [pscustomobject]@{
            Available = $false
            IdleMs    = $null
            IdleMinutes = $null
            Reason    = 'Idle detection is only available on Windows.'
        }
    }

    try {
        if (-not ('Autoresearch.IdleNative' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace Autoresearch {
    public static class IdleNative {
        [StructLayout(LayoutKind.Sequential)]
        private struct LASTINPUTINFO {
            public uint cbSize;
            public uint dwTime;
        }

        public static uint LastInputInfoSize {
            get { return (uint)Marshal.SizeOf(typeof(LASTINPUTINFO)); }
        }

        [DllImport("user32.dll")]
        private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

        [DllImport("kernel32.dll")]
        private static extern uint GetTickCount();

        public static bool TryGetIdleMilliseconds(out uint idleMilliseconds, out string reason) {
            LASTINPUTINFO info = new LASTINPUTINFO();
            info.cbSize = LastInputInfoSize;

            if (!GetLastInputInfo(ref info)) {
                idleMilliseconds = 0;
                reason = "GetLastInputInfo returned false.";
                return false;
            }

            return TryComputeIdleMilliseconds(
                true,
                info.cbSize,
                info.dwTime,
                GetTickCount(),
                out idleMilliseconds,
                out reason
            );
        }

        public static bool TryComputeIdleMilliseconds(
            bool nativeCallSucceeded,
            uint structureSize,
            uint lastInputTime,
            uint currentTick,
            out uint idleMilliseconds,
            out string reason
        ) {
            idleMilliseconds = 0;

            if (!nativeCallSucceeded) {
                reason = "GetLastInputInfo returned false.";
                return false;
            }

            if (structureSize != LastInputInfoSize || lastInputTime == 0) {
                reason = "GetLastInputInfo returned invalid idle data.";
                return false;
            }

            // Unsigned subtraction handles GetTickCount rollover. A delta in
            // the upper half of the DWORD range is ambiguous with a future
            // timestamp, so fail closed instead of reporting a large idle time.
            uint elapsed = unchecked(currentTick - lastInputTime);
            if (elapsed > Int32.MaxValue) {
                reason = "GetLastInputInfo returned invalid idle data.";
                return false;
            }

            idleMilliseconds = elapsed;
            reason = null;
            return true;
        }
    }
}
"@ -Language CSharp
        }

        [uint32]$idleMs = 0
        [string]$reason = $null
        if ($PSBoundParameters.ContainsKey('TestNativeSample')) {
            $available = [Autoresearch.IdleNative]::TryComputeIdleMilliseconds(
                [bool]$TestNativeSample.Success,
                [uint32]$TestNativeSample.StructureSize,
                [uint32]$TestNativeSample.LastInputTime,
                [uint32]$TestNativeSample.CurrentTick,
                [ref]$idleMs,
                [ref]$reason
            )
        } else {
            $available = [Autoresearch.IdleNative]::TryGetIdleMilliseconds(
                [ref]$idleMs,
                [ref]$reason
            )
        }

        if (-not $available) {
            return [pscustomobject]@{
                Available   = $false
                IdleMs      = $null
                IdleMinutes = $null
                Reason      = $reason
            }
        }

        return [pscustomobject]@{
            Available  = $true
            IdleMs     = [int64]$idleMs
            IdleMinutes = [math]::Round(($idleMs / 60000), 2)
            Reason     = $null
        }
    } catch {
        return [pscustomobject]@{
            Available  = $false
            IdleMs     = $null
            IdleMinutes = $null
            Reason     = 'Windows idle detection failed.'
        }
    }
}

function Invoke-IdlePolicyGate {
    param(
        [Parameter(Mandatory)][string]$Policy,
        [int]$IdleMinutes = 5,
        [int]$WaitTimeoutMinutes = 60,
        [int]$PollIntervalSeconds = 30,
        [Parameter(DontShow)][scriptblock]$IdleStateProvider
    )

    if ($Policy -ne 'IdleOnly') {
        return $true
    }

    Write-Json -Level info -Message "Idle-only policy active; waiting up to $WaitTimeoutMinutes minute(s) for at least $IdleMinutes minute(s) of idle time." -Extra @{
        policy             = $Policy
        idleMinutes        = $IdleMinutes
        waitTimeoutMinutes = $WaitTimeoutMinutes
    }

    $deadline = (Get-Date).AddMinutes($WaitTimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        $state = if ($null -ne $IdleStateProvider) { & $IdleStateProvider } else { Get-ComputerIdleState }
        if (-not $state.Available) {
            Write-Json -Level info -Message "Idle-only policy skipped because Windows idle state could not be determined: $($state.Reason)" -Extra @{
                policy = $Policy
                reason = $state.Reason
            }
            return $false
        }
        if ($state.IdleMinutes -ge $IdleMinutes) {
            Write-Json -Level info -Message "Idle-only policy satisfied after observing $($state.IdleMinutes) minute(s) of idle time." -Extra @{
                policy        = $Policy
                idleMinutes   = $state.IdleMinutes
                requiredIdle  = $IdleMinutes
            }
            return $true
        }
        if ($WaitTimeoutMinutes -le 0) {
            break
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }

    $finalState = if ($null -ne $IdleStateProvider) { & $IdleStateProvider } else { Get-ComputerIdleState }
    if (-not $finalState.Available) {
        Write-Json -Level info -Message "Idle-only policy skipped after waiting $WaitTimeoutMinutes minute(s) because Windows idle state could not be determined: $($finalState.Reason)" -Extra @{
            policy             = $Policy
            reason             = $finalState.Reason
            requiredIdle       = $IdleMinutes
            waitTimeoutMinutes = $WaitTimeoutMinutes
        }
        return $false
    }

    $observed = $finalState.IdleMinutes
    Write-Json -Level info -Message "Idle-only policy skipped after waiting $WaitTimeoutMinutes minute(s); observed idle time was $observed minute(s), which did not reach the required $IdleMinutes minute(s)." -Extra @{
        policy            = $Policy
        observedIdle      = $observed
        requiredIdle      = $IdleMinutes
        waitTimeoutMinutes = $WaitTimeoutMinutes
    }
    return $false
}

function Get-TaskXml {
    param([AllowNull()][psobject]$Plan)

    $policy = Get-SchedulerPolicyInfo -Policy $SchedulerPolicy
    $schedule = Get-ScheduleTriggerSpec -Frequency $ScheduleFrequency -Value $ScheduleTime
    if ($null -eq $Plan) {
        $Plan = Get-TaskLauncherPlan
    }

    $service = New-Object -ComObject Schedule.Service
    $service.Connect()
    $task = $service.NewTask(0)

    $task.RegistrationInfo.Author = $Script:ScheduledTaskAuthor
    $task.RegistrationInfo.Description = Get-ScheduledTaskDescription -PolicyInfo $policy
    $task.Principal.UserId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $task.Principal.LogonType = $policy.LogonType
    $task.Principal.RunLevel = 1
    $task.Settings.StartWhenAvailable = $true
    $task.Settings.AllowDemandStart = $true
    $task.Settings.DisallowStartIfOnBatteries = $false
    $task.Settings.StopIfGoingOnBatteries = $false
    $task.Settings.RestartCount = 3
    $task.Settings.RestartInterval = 'PT5M'
    $task.Settings.RunOnlyIfIdle = [bool]$policy.UsesIdleGate
    if ($policy.UsesIdleGate) {
        $task.Settings.IdleSettings.IdleDuration = $policy.IdleDuration
        $task.Settings.IdleSettings.WaitTimeout = $policy.IdleWaitTimeout
    } else {
        $task.Settings.IdleSettings.IdleDuration = 'PT0M'
        $task.Settings.IdleSettings.WaitTimeout = 'PT0M'
    }

    switch ($schedule.Kind) {
        'Hourly' {
            $trigger = $task.Triggers.Create(1)
            $trigger.StartBoundary = $schedule.StartBoundary.ToString('s')
            $trigger.Repetition.Interval = $schedule.Repetition
        }
        'Daily' {
            $trigger = $task.Triggers.Create(2)
            $trigger.StartBoundary = $schedule.StartBoundary.ToString('s')
            $trigger.DaysInterval = $schedule.DaysInterval
        }
        'Weekly' {
            $trigger = $task.Triggers.Create(3)
            $trigger.StartBoundary = $schedule.StartBoundary.ToString('s')
            $trigger.WeeksInterval = $schedule.WeeksInterval
            $trigger.DaysOfWeek = $schedule.DaysOfWeek
        }
    }

    $action = $task.Actions.Create(0)
    $action.Path = $Plan.PowerShellPath
    $action.Arguments = $Plan.TaskActionArguments
    $action.WorkingDirectory = $RepoRoot

    return $task.XmlText
}

function Enable-TaskHistoryLog {
    try {
        $log = 'Microsoft-Windows-TaskScheduler/Operational'
        & wevtutil set-log $log /enabled:true 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Json -Level warn -Message 'Could not enable Task Scheduler history log (elevation required). Run elevated to enable.'
        }
    } catch {
        Write-Json -Level warn -Message "Task Scheduler history enable skipped: $($_.Exception.Message)"
    }
}

function Get-RegisteredLauncherTask {
    $t = Get-ScheduledTask -TaskPath $Script:TaskPath -TaskName $Script:TaskName -ErrorAction SilentlyContinue
    if (-not $t) { $t = Get-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue }
    return $t
}

function Register-LauncherTask {
    Initialize-LauncherStorage
    $plan = Get-TaskLauncherPlan
    $policy = Get-SchedulerPolicyInfo -Policy $SchedulerPolicy
    $existing = Get-RegisteredLauncherTask
    if ($existing) {
        Write-Json -Level info -Message "Existing task $($Script:TaskName) found; replacing"
        Unregister-ScheduledTask -TaskPath $existing.TaskPath -TaskName $existing.TaskName -Confirm:$false
    }
    Write-Json -Level info -Message "Registering scheduled task $($Script:TaskPath)$($Script:TaskName) with $($policy.DisplayName) policy" -Extra @{
        schedulerPolicy = $SchedulerPolicy
        powerShellPath  = $plan.PowerShellPath
        policySummary   = $policy.Summary
        logonType       = $policy.LogonTypeName
        requiresDesktop = $policy.RequiresDesktopSession
        idleGate        = $policy.UsesIdleGate
    }
    $xml = Get-TaskXml -Plan $plan

    Register-ScheduledTask -TaskName $Script:TaskName -TaskPath $Script:TaskPath `
        -Xml $xml | Out-Null
    Enable-TaskHistoryLog
    Write-Json -Level info -Message "Registered scheduled task $($Script:TaskPath)$($Script:TaskName)" -Extra @{
        schedule             = $ScheduleFrequency
        time                 = $ScheduleTime
        schedulerPolicy      = $SchedulerPolicy
        policySummary        = $policy.Summary
        logonType            = $policy.LogonTypeName
        requiresDesktop      = $policy.RequiresDesktopSession
        idleGate             = $policy.UsesIdleGate
        idleMinutes          = if ($policy.UsesIdleGate) { 5 } else { $null }
        idleWaitMinutes      = if ($policy.UsesIdleGate) { 60 } else { $null }
        ownProcess           = $true
        powerShellPath       = $plan.PowerShellPath
        launcherCommand      = $plan.TaskActionCommand
        workloadCommand      = $plan.WorkloadCommand
        taskLaunchState      = $plan.TaskLaunchStatePath
    }
}

function Unregister-LauncherTask {
    $existing = Get-RegisteredLauncherTask
    if ($existing) {
        Unregister-ScheduledTask -TaskPath $existing.TaskPath -TaskName $existing.TaskName -Confirm:$false
        Write-Json -Level info -Message "Unregistered scheduled task $($existing.TaskPath)$($existing.TaskName)"
    } else {
        Write-Json -Level info -Message "Scheduled task $($Script:TaskName) was not present"
    }
}

$Script:ProviderModels = @{
    ollama    = @('qwen2.5-coder:latest','qwen2.5-coder:7b','qwen2.5-coder:3b','llama3.1:8b','llama3.2:3b')
    openai    = @('gpt-4o','gpt-4o-mini','gpt-4-turbo','o1','o1-mini')
    anthropic = @('claude-3-5-sonnet-latest','claude-3-5-haiku-latest','claude-3-opus-latest')
    azure     = @('gpt-4o','gpt-4o-mini','gpt-4-turbo')
}

function Read-LaunchDefaults {
    if (-not [string]::IsNullOrWhiteSpace($Script:DefaultsPath) -and
        -not [string]::IsNullOrWhiteSpace($Script:LegacyDefaultsPath) -and
        -not [string]::Equals(
            [System.IO.Path]::GetFullPath($Script:DefaultsPath),
            [System.IO.Path]::GetFullPath($Script:LegacyDefaultsPath),
            [System.StringComparison]::OrdinalIgnoreCase)) {
        $defaultsDirectory = Split-Path -Parent $Script:DefaultsPath
        New-Dir -Path $defaultsDirectory
        Ensure-LauncherDirectoryAcl -Path $defaultsDirectory -Purpose 'per-user launcher configuration directory' | Out-Null
    }
    $paths = @($Script:DefaultsPath)
    if ($Script:LegacyDefaultsPath -and $Script:LegacyDefaultsPath -ne $Script:DefaultsPath) {
        $paths += $Script:LegacyDefaultsPath
    }
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $isLegacyPath = $Script:LegacyDefaultsPath -and [string]::Equals(
            [System.IO.Path]::GetFullPath($path),
            [System.IO.Path]::GetFullPath($Script:LegacyDefaultsPath),
            [System.StringComparison]::OrdinalIgnoreCase
        )
        if ($isLegacyPath) {
            $legacyAcl = Test-LauncherDirectoryAcl -Path $path
            if (-not $legacyAcl.IsHardened) {
                $repairStep = if ([string]::Equals(
                    [System.IO.Path]::GetFullPath($Script:DefaultsPath),
                    [System.IO.Path]::GetFullPath($Script:LegacyDefaultsPath),
                    [System.StringComparison]::OrdinalIgnoreCase)) {
                    'Set LOCALAPPDATA for this account and re-enter preferences through the launcher; leave the legacy file unchanged.'
                } else {
                    "Save preferences through the launcher to the protected per-user path '$Script:DefaultsPath'; leave the legacy file unchanged."
                }
                $failureOperation = if ($legacyAcl.FailureOperation) {
                    $legacyAcl.FailureOperation
                } else {
                    'ACL policy verification'
                }
                Write-Warning "Degraded: ignoring legacy launcher configuration '$path' because operation '$failureOperation' did not verify its restrictive ACL: $($legacyAcl.Reason) Repair step: $repairStep"
                continue
            }
        }
        try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { continue }
    }
    return $null
}

function Save-LaunchDefaults {
    param([System.Collections.IDictionary]$Values)
    $persistedKeys = @(
        'Provider', 'Model', 'OllamaHost', 'AzureEndpoint', 'AzureDeployment',
        'LogDir', 'ScheduleFrequency', 'ScheduleTime', 'SchedulerPolicy'
    )
    $persisted = [ordered]@{}
    foreach ($key in $persistedKeys) {
        if ($Values.Contains($key)) {
            $persisted[$key] = $Values[$key]
        }
    }
    if ([string]::IsNullOrWhiteSpace($Script:DefaultsPath)) {
        throw 'Per-user launcher configuration cannot be saved because its path is unavailable.'
    }
    if (-not [string]::IsNullOrWhiteSpace($Script:LegacyDefaultsPath) -and
        [string]::Equals(
            [System.IO.Path]::GetFullPath($Script:DefaultsPath),
            [System.IO.Path]::GetFullPath($Script:LegacyDefaultsPath),
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to write per-user launcher configuration beside the launcher at '$($Script:DefaultsPath)'. Set LOCALAPPDATA for this account, then rerun so the per-user configuration directory can be restricted."
    }
    $defaultsDirectory = Split-Path -Parent $Script:DefaultsPath
    New-Dir -Path $defaultsDirectory
    Ensure-LauncherDirectoryAcl -Path $defaultsDirectory -Purpose 'per-user launcher configuration directory' | Out-Null
    ($persisted | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $Script:DefaultsPath -Encoding UTF8
}

function Initialize-LaunchConfig {
    param([System.Collections.IDictionary]$Bound)
    if (-not [string]::IsNullOrWhiteSpace($Script:DefaultsPath) -and
        -not [string]::IsNullOrWhiteSpace($Script:LegacyDefaultsPath) -and
        -not [string]::Equals(
            [System.IO.Path]::GetFullPath($Script:DefaultsPath),
            [System.IO.Path]::GetFullPath($Script:LegacyDefaultsPath),
            [System.StringComparison]::OrdinalIgnoreCase)) {
        $defaultsDirectory = Split-Path -Parent $Script:DefaultsPath
        New-Dir -Path $defaultsDirectory
        Ensure-LauncherDirectoryAcl -Path $defaultsDirectory -Purpose 'per-user launcher configuration directory' | Out-Null
    }
    $hasDefaults = Test-Path -LiteralPath $Script:DefaultsPath
    if (-not $hasDefaults -and $Script:LegacyDefaultsPath -and $Script:LegacyDefaultsPath -ne $Script:DefaultsPath) {
        $hasDefaults = Test-Path -LiteralPath $Script:LegacyDefaultsPath
    }
    if ($hasDefaults) {
        $d = Read-LaunchDefaults
        if ($d) {
            foreach ($k in 'Provider','Model','OllamaHost','AzureEndpoint','AzureDeployment','LogDir','ScheduleFrequency','ScheduleTime','SchedulerPolicy') {
                if (-not $Bound.ContainsKey($k) -and $d.PSObject.Properties[$k] -and $d.$k) {
                    Set-Variable -Name $k -Value $d.$k -Scope 1
                }
            }
        }
    } else {
        Save-LaunchDefaults -Values @{
            Provider=$Provider; Model=$Model; OllamaHost=$OllamaHost
            AzureEndpoint=$AzureEndpoint; AzureDeployment=$AzureDeployment
            LogDir=$LogDir; ScheduleFrequency=$ScheduleFrequency; ScheduleTime=$ScheduleTime
            SchedulerPolicy=$SchedulerPolicy
        }
    }
}

function Invoke-GuiSafe {
    param(
        [Parameter(Mandatory)][string]$Context,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    try {
        & $Action
    } catch {
        $msg = "GUI error in $Context : $($_.Exception.Message)"
        try { Write-Json -Level error -Message $msg } catch {}
        Write-DebugLog $msg -Extra @{
            context    = $Context
            exception  = $_.Exception.GetType().FullName
            stackTrace = $_.ScriptStackTrace
        }
    }
}

function Show-LaunchGui {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    Write-DebugLog "Show-LaunchGui: begin"
    $d = Read-LaunchDefaults
    Write-DebugLog "Show-LaunchGui: defaults loaded" -Extra @{ hasDefaults = [bool]$d }
    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="autoresearch launcher" Width="640" Height="340" MinWidth="600" MinHeight="320"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResize" SizeToContent="Manual"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        KeyboardNavigation.TabNavigation="Cycle"
        KeyboardNavigation.DirectionalNavigation="Contained">
  <Grid Margin="10">
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <ScrollViewer Grid.Row="0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">
      <StackPanel>
        <GroupBox Header="Action" Padding="6" Margin="0,0,0,6">
          <StackPanel>
            <RadioButton x:Name="ActPreflight" TabIndex="0" Margin="0,0,0,2"><TextBlock Text="Preflight only" TextWrapping="Wrap"/></RadioButton>
            <RadioButton x:Name="ActRunNow" TabIndex="1" IsChecked="True" Margin="0,0,0,2"><TextBlock Text="Run training now" TextWrapping="Wrap"/></RadioButton>
            <RadioButton x:Name="ActRegister" TabIndex="2" Margin="0,0,0,2"><TextBlock Text="Register scheduled task" TextWrapping="Wrap"/></RadioButton>
            <RadioButton x:Name="ActRegisterRun" TabIndex="3" Margin="0,0,0,2"><TextBlock Text="Register task and run now" TextWrapping="Wrap"/></RadioButton>
            <RadioButton x:Name="ActUnregister" TabIndex="4" Margin="0,0,0,2"><TextBlock Text="Unregister scheduled task" TextWrapping="Wrap"/></RadioButton>
            <RadioButton x:Name="ActUpdate" TabIndex="5"><TextBlock Text="Update toolchain" TextWrapping="Wrap"/></RadioButton>
          </StackPanel>
        </GroupBox>
        <GroupBox Header="AI Provider" Padding="6" Margin="0,0,0,6">
          <StackPanel>
            <WrapPanel Margin="0,0,0,6">
              <RadioButton x:Name="PrvOllama" GroupName="prv" TabIndex="6" IsChecked="True" Margin="0,0,8,4"><TextBlock Text="Ollama (local)" TextWrapping="Wrap"/></RadioButton>
              <RadioButton x:Name="PrvOpenAI" GroupName="prv" TabIndex="7" Margin="0,0,8,4"><TextBlock Text="OpenAI" TextWrapping="Wrap"/></RadioButton>
              <RadioButton x:Name="PrvAnthropic" GroupName="prv" TabIndex="8" Margin="0,0,8,4"><TextBlock Text="Anthropic" TextWrapping="Wrap"/></RadioButton>
              <RadioButton x:Name="PrvAzure" GroupName="prv" TabIndex="9" Margin="0,0,8,4"><TextBlock Text="Azure OpenAI" TextWrapping="Wrap"/></RadioButton>
            </WrapPanel>
            <TextBlock x:Name="LblModel" Text="Model" TextWrapping="Wrap" Margin="0,0,0,2"/>
            <ComboBox x:Name="CbModel" TabIndex="10" HorizontalAlignment="Stretch" MinWidth="260" Margin="0,0,0,6" AutomationProperties.LabeledBy="{Binding ElementName=LblModel}" AutomationProperties.HelpText="Choose the model used by the selected provider."/>
            <TextBlock x:Name="LblHost" Text="Ollama host (Ollama only)" TextWrapping="Wrap" Margin="0,0,0,2"/>
            <ComboBox x:Name="CbHost" TabIndex="11" HorizontalAlignment="Stretch" MinWidth="260" IsEditable="True" Margin="0,0,0,6" AutomationProperties.LabeledBy="{Binding ElementName=LblHost}" AutomationProperties.HelpText="Enter the Ollama base URL when Ollama is selected.">
          <ComboBoxItem Content="http://127.0.0.1:11434" IsSelected="True"/>
          <ComboBoxItem Content="http://localhost:11434"/>
        </ComboBox>
            <TextBlock x:Name="LblApiKey" Text="API key (OpenAI / Anthropic / Azure)" TextWrapping="Wrap" Margin="0,0,0,2"/>
            <PasswordBox x:Name="PbApiKey" TabIndex="12" HorizontalAlignment="Stretch" MinWidth="260" Margin="0,0,0,6" AutomationProperties.LabeledBy="{Binding ElementName=LblApiKey}" AutomationProperties.HelpText="Enter the provider API key. It is used in memory only and is never persisted."/>
            <TextBlock x:Name="LblAzEp" Text="Azure endpoint" Visibility="Collapsed" TextWrapping="Wrap" Margin="0,0,0,2"/>
            <TextBox x:Name="TxtAzEp" TabIndex="13" HorizontalAlignment="Stretch" MinWidth="260" Visibility="Collapsed" Margin="0,0,0,6" AutomationProperties.LabeledBy="{Binding ElementName=LblAzEp}" AutomationProperties.HelpText="Enter the Azure OpenAI endpoint URL."/>
            <TextBlock x:Name="LblAzDp" Text="Azure deployment" Visibility="Collapsed" TextWrapping="Wrap" Margin="0,0,0,2"/>
            <TextBox x:Name="TxtAzDp" TabIndex="14" HorizontalAlignment="Stretch" MinWidth="260" Visibility="Collapsed" AutomationProperties.LabeledBy="{Binding ElementName=LblAzDp}" AutomationProperties.HelpText="Enter the Azure OpenAI deployment name."/>
          </StackPanel>
        </GroupBox>
        <GroupBox Header="Scheduler policy" Padding="6" Margin="0,0,0,6">
          <StackPanel>
            <RadioButton x:Name="PolInteractive" GroupName="policy" TabIndex="15" Margin="0,0,0,2"><TextBlock Text="Interactive - logged-on session only, no idle wait" TextWrapping="Wrap"/></RadioButton>
            <RadioButton x:Name="PolIdleOnly" GroupName="policy" TabIndex="16" IsChecked="True" Margin="0,0,0,2"><TextBlock Text="Idle-only - waits for 5 minutes of idle time, then logs a skip after 1 hour if needed" TextWrapping="Wrap"/></RadioButton>
            <RadioButton x:Name="PolUnattended" GroupName="policy" TabIndex="17" Margin="0,0,0,2"><TextBlock Text="Unattended - S4U logon, no active desktop required" TextWrapping="Wrap"/></RadioButton>
            <TextBlock x:Name="TxtPolicySummary" TextWrapping="Wrap" Margin="0,6,0,0" Foreground="DarkSlateGray"/>
          </StackPanel>
        </GroupBox>
        <GroupBox Header="Schedule" Padding="6" Margin="0,0,0,6">
          <StackPanel>
            <TextBlock x:Name="LblFreq" Text="Frequency" TextWrapping="Wrap" Margin="0,0,0,2"/>
            <ComboBox x:Name="CbFreq" TabIndex="18" HorizontalAlignment="Stretch" MinWidth="260" Margin="0,0,0,6" AutomationProperties.LabeledBy="{Binding ElementName=LblFreq}" AutomationProperties.HelpText="Choose how often the task runs. The time field below changes with this selection.">
              <ComboBoxItem Content="Hourly"/>
              <ComboBoxItem Content="Daily" IsSelected="True"/>
              <ComboBoxItem Content="Weekly"/>
            </ComboBox>
            <TextBlock x:Name="LblTime" Text="Time (HH:mm, local)" TextWrapping="Wrap" Margin="0,0,0,2"/>
            <ComboBox x:Name="CbTime" TabIndex="19" HorizontalAlignment="Stretch" MinWidth="260" Margin="0,0,0,6" AutomationProperties.LabeledBy="{Binding ElementName=LblTime}" AutomationProperties.HelpText="Choose the time, minute, or weekday value for the selected frequency."/>
            <CheckBox x:Name="ChkHistory" TabIndex="20" IsChecked="True" Margin="0,6,0,0" AutomationProperties.Name="Enable Task Scheduler history" AutomationProperties.HelpText="Requires elevation to turn on the Task Scheduler Operational log."><TextBlock Text="Enable Task Scheduler history (requires elevation)" TextWrapping="Wrap"/></CheckBox>
          </StackPanel>
        </GroupBox>
      </StackPanel>
    </ScrollViewer>
    <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="BtnDefaults" TabIndex="21" MinWidth="130" Margin="0,0,6,0" AutomationProperties.Name="Save as Defaults" AutomationProperties.HelpText="Save the current launcher selections without the API key."><TextBlock Text="Save as Defaults" TextWrapping="Wrap"/></Button>
      <Button x:Name="BtnCancel" TabIndex="22" MinWidth="90" Margin="0,0,6,0" IsCancel="True" AutomationProperties.Name="Cancel" AutomationProperties.HelpText="Close the launcher without saving changes."><TextBlock Text="Cancel" TextWrapping="Wrap"/></Button>
      <Button x:Name="BtnOK" TabIndex="23" MinWidth="90" IsDefault="True" AutomationProperties.Name="OK" AutomationProperties.HelpText="Start with the current selections."><TextBlock Text="OK" TextWrapping="Wrap"/></Button>
    </StackPanel>
  </Grid>
</Window>
"@
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $window.MaxWidth = [System.Windows.SystemParameters]::WorkArea.Width
    $window.MaxHeight = [System.Windows.SystemParameters]::WorkArea.Height
    Write-DebugLog "Show-LaunchGui: XAML loaded"
    $script:C = @{}
    foreach ($n in 'ActPreflight','ActRunNow','ActRegister','ActRegisterRun','ActUnregister','ActUpdate',
        'PrvOllama','PrvOpenAI','PrvAnthropic','PrvAzure','CbModel','CbHost','PbApiKey',
        'LblAzEp','TxtAzEp','LblAzDp','TxtAzDp','PolInteractive','PolIdleOnly','PolUnattended',
        'TxtPolicySummary','CbFreq','LblTime','CbTime','ChkHistory','BtnDefaults','BtnCancel','BtnOK') {
        $script:C[$n] = $window.FindName($n)
        if ($null -eq $script:C[$n]) {
            Write-DebugLog "Show-LaunchGui: FindName returned null for '$n'"
        }
    }

    # Apply Frequency -> Time dropdown rebuild. Defined as a script-scoped
    # function so it can be invoked both directly and from event handlers
    # without scope/marshaling surprises. Uses Items.Clear()/Items.Add()
    # because mixing ItemsSource with later Items.Add throws InvalidOperation
    # under WPF, and the previous null-then-rebind pattern intermittently
    # left CbTime stale on SelectionChanged.
    function script:Update-CbTimeForFrequency {
        $freqItem = $script:C.CbFreq.SelectedItem
        $freq = if ($null -ne $freqItem) {
            if ($freqItem -is [System.Windows.Controls.ComboBoxItem]) { [string]$freqItem.Content }
            else { [string]$freqItem }
        } else { 'Daily' }
        Write-DebugLog "Update-CbTimeForFrequency: freq='$freq' (selectedType=$(if ($null -ne $freqItem){$freqItem.GetType().Name}else{'<null>'}))"
        $opts = @(Get-ScheduleTimeOptions -Frequency $freq)
        Write-DebugLog "Update-CbTimeForFrequency: option count=$($opts.Count) first='$($opts[0])' last='$($opts[-1])'"
        $script:C.CbTime.SelectedIndex = -1
        $script:C.CbTime.Items.Clear()
        foreach ($o in $opts) { $null = $script:C.CbTime.Items.Add([string]$o) }
        $script:C.LblTime.Text = switch ($freq) {
            'Hourly' { 'Minute of hour' }
            'Weekly' { 'Day of week' }
            default  { 'Time of day (HH:mm, local)' }
        }
        $defVal = Get-ScheduleTimeDefault -Frequency $freq
        $idx = [array]::IndexOf($opts, $defVal)
        if ($idx -ge 0) { $script:C.CbTime.SelectedIndex = $idx }
        Write-DebugLog "Update-CbTimeForFrequency: applied label='$($script:C.LblTime.Text)' defaultVal='$defVal' selectedIndex=$($script:C.CbTime.SelectedIndex) itemsCount=$($script:C.CbTime.Items.Count)"
    }

    $script:C.CbFreq.add_SelectionChanged({
        Invoke-GuiSafe -Context 'CbFreq.SelectionChanged' -Action {
            Write-DebugLog "CbFreq.SelectionChanged fired"
            script:Update-CbTimeForFrequency
        }
    })

    function script:Update-ModelsForProvider {
        param([string]$Prv)
        Write-DebugLog "Update-ModelsForProvider: prv='$Prv'"
        $script:C.CbModel.Items.Clear()
        foreach ($m in $Script:ProviderModels[$Prv]) { $null = $script:C.CbModel.Items.Add($m) }
        $script:C.CbModel.SelectedIndex = 0
        $azVis = if ($Prv -eq 'azure') { 'Visible' } else { 'Collapsed' }
        foreach ($k in 'LblAzEp','TxtAzEp','LblAzDp','TxtAzDp') { $script:C[$k].Visibility = $azVis }
        $script:C.CbHost.IsEnabled = ($Prv -eq 'ollama')
    }

    $script:C.PrvOllama.Add_Checked({ Invoke-GuiSafe -Context 'PrvOllama.Checked' -Action { script:Update-ModelsForProvider 'ollama' } })
    $script:C.PrvOpenAI.Add_Checked({ Invoke-GuiSafe -Context 'PrvOpenAI.Checked' -Action { script:Update-ModelsForProvider 'openai' } })
    $script:C.PrvAnthropic.Add_Checked({ Invoke-GuiSafe -Context 'PrvAnthropic.Checked' -Action { script:Update-ModelsForProvider 'anthropic' } })
    $script:C.PrvAzure.Add_Checked({ Invoke-GuiSafe -Context 'PrvAzure.Checked' -Action { script:Update-ModelsForProvider 'azure' } })

    Invoke-GuiSafe -Context 'initial-populateModels' -Action { script:Update-ModelsForProvider 'ollama' }

    function script:Update-PolicySummary {
        $policy = if ($script:C.PolInteractive.IsChecked) { 'Interactive' }
        elseif ($script:C.PolUnattended.IsChecked) { 'Unattended' }
        else { 'IdleOnly' }
        $info = Get-SchedulerPolicyInfo -Policy $policy
        $script:C.TxtPolicySummary.Text = $info.Summary
        Write-DebugLog "Update-PolicySummary: policy='$policy' summary='$($info.Summary)'"
    }

    $script:C.PolInteractive.Add_Checked({ Invoke-GuiSafe -Context 'PolInteractive.Checked' -Action { script:Update-PolicySummary } })
    $script:C.PolIdleOnly.Add_Checked({ Invoke-GuiSafe -Context 'PolIdleOnly.Checked' -Action { script:Update-PolicySummary } })
    $script:C.PolUnattended.Add_Checked({ Invoke-GuiSafe -Context 'PolUnattended.Checked' -Action { script:Update-PolicySummary } })

    if ($d) {
        Invoke-GuiSafe -Context 'apply-defaults' -Action {
            switch ($d.Provider) {
                'openai'    { $script:C.PrvOpenAI.IsChecked = $true }
                'anthropic' { $script:C.PrvAnthropic.IsChecked = $true }
                'azure'     { $script:C.PrvAzure.IsChecked = $true }
                default     { $script:C.PrvOllama.IsChecked = $true }
            }
            if ($d.PSObject.Properties['Model']           -and $d.Model)           { $script:C.CbModel.SelectedItem = $d.Model }
            if ($d.PSObject.Properties['OllamaHost']      -and $d.OllamaHost)      { $script:C.CbHost.Text = $d.OllamaHost }
            if ($d.PSObject.Properties['ScheduleFrequency'] -and $d.ScheduleFrequency) {
                $match = $script:C.CbFreq.Items | Where-Object { $_.Content -eq $d.ScheduleFrequency } | Select-Object -First 1
                if ($match) { $script:C.CbFreq.SelectedItem = $match }
            }
            if ($d.PSObject.Properties['AzureEndpoint']   -and $d.AzureEndpoint)   { $script:C.TxtAzEp.Text = $d.AzureEndpoint }
            if ($d.PSObject.Properties['AzureDeployment'] -and $d.AzureDeployment) { $script:C.TxtAzDp.Text = $d.AzureDeployment }
            if ($d.PSObject.Properties['SchedulerPolicy'] -and $d.SchedulerPolicy) {
                switch ($d.SchedulerPolicy) {
                    'Interactive' { $script:C.PolInteractive.IsChecked = $true }
                    'Unattended'  { $script:C.PolUnattended.IsChecked = $true }
                    default       { $script:C.PolIdleOnly.IsChecked = $true }
                }
            }
            Write-DebugLog "apply-defaults: provider=$($d.Provider) freq=$($d.ScheduleFrequency) time=$($d.ScheduleTime)"
        }
    }

    # Force the Time dropdown to align with whatever frequency is now selected
    # (handles both the no-defaults path and any defaults that did not trigger
    # SelectionChanged because the selection did not actually change).
    Invoke-GuiSafe -Context 'initial-applyFreqItems' -Action { script:Update-CbTimeForFrequency }

    if ($d -and $d.PSObject.Properties['ScheduleTime'] -and $d.ScheduleTime) {
        Invoke-GuiSafe -Context 'apply-defaults-scheduleTime' -Action {
            $items = @($script:C.CbTime.Items)
            $idx = [array]::IndexOf($items, [string]$d.ScheduleTime)
            if ($idx -ge 0) { $script:C.CbTime.SelectedIndex = $idx }
            Write-DebugLog "apply-defaults-scheduleTime: target='$($d.ScheduleTime)' index=$idx"
        }
    }

    Invoke-GuiSafe -Context 'initial-policySummary' -Action { script:Update-PolicySummary }

    $Script:GuiResult = $null
    function script:Get-GuiSnapshot {
        $prv = if ($script:C.PrvOpenAI.IsChecked) { 'openai' }
               elseif ($script:C.PrvAnthropic.IsChecked) { 'anthropic' }
               elseif ($script:C.PrvAzure.IsChecked) { 'azure' }
               else { 'ollama' }
        $policy = if ($script:C.PolInteractive.IsChecked) { 'Interactive' }
                  elseif ($script:C.PolUnattended.IsChecked) { 'Unattended' }
                  else { 'IdleOnly' }
        $freqItem = $script:C.CbFreq.SelectedItem
        $freqStr = if ($null -ne $freqItem) {
            if ($freqItem -is [System.Windows.Controls.ComboBoxItem]) { [string]$freqItem.Content }
            else { [string]$freqItem }
        } else { 'Daily' }
        @{
            Provider          = $prv
            Model             = [string]$script:C.CbModel.SelectedItem
            OllamaHost        = [string]$script:C.CbHost.Text
            ApiKey            = $script:C.PbApiKey.Password
            AzureEndpoint     = $script:C.TxtAzEp.Text
            AzureDeployment   = $script:C.TxtAzDp.Text
            ScheduleFrequency = $freqStr
            ScheduleTime      = [string]$script:C.CbTime.SelectedItem
            SchedulerPolicy   = $policy
            EnableHistory     = [bool]$script:C.ChkHistory.IsChecked
            Action            = if ($script:C.ActPreflight.IsChecked) { 'Preflight' }
                                elseif ($script:C.ActRunNow.IsChecked) { 'RunNow' }
                                elseif ($script:C.ActRegister.IsChecked) { 'Register' }
                                elseif ($script:C.ActRegisterRun.IsChecked) { 'RegisterRun' }
                                elseif ($script:C.ActUnregister.IsChecked) { 'Unregister' }
                                else { 'Update' }
        }
    }

    $script:C.BtnDefaults.Add_Click({
        Invoke-GuiSafe -Context 'BtnDefaults.Click' -Action {
            $vals = script:Get-GuiSnapshot
            $persist = @{} + $vals
            $persist.Remove('ApiKey') | Out-Null
            Save-LaunchDefaults -Values $persist
            Write-DebugLog "BtnDefaults.Click: saved defaults"
        }
    })
    $script:C.BtnCancel.Add_Click({
        Invoke-GuiSafe -Context 'BtnCancel.Click' -Action {
            Write-DebugLog "BtnCancel.Click"
            $window.DialogResult = $false
            $window.Close()
        }
    })
    $script:C.BtnOK.Add_Click({
        Invoke-GuiSafe -Context 'BtnOK.Click' -Action {
            $Script:GuiResult = script:Get-GuiSnapshot
            Write-DebugLog "BtnOK.Click: snapshot collected" -Extra @{
                provider = $Script:GuiResult.Provider
                model    = $Script:GuiResult.Model
                freq     = $Script:GuiResult.ScheduleFrequency
                time     = $Script:GuiResult.ScheduleTime
                policy   = $Script:GuiResult.SchedulerPolicy
                action   = $Script:GuiResult.Action
            }
            $window.DialogResult = $true
            $window.Close()
        }
    })
    $window.Add_ContentRendered({
        Invoke-GuiSafe -Context 'Window.ContentRendered' -Action {
            # Put initial focus on the main action so keyboard users can start
            # interacting immediately without tabbing through the chrome.
            if ($script:C.ActRunNow) { $null = $script:C.ActRunNow.Focus() }
        }
    })
    Write-DebugLog "Show-LaunchGui: showing dialog"
    $ok = $window.ShowDialog()
    Write-DebugLog "Show-LaunchGui: dialog closed result=$ok"
    if (-not $ok) { return $null }
    return $Script:GuiResult
}

function Invoke-FromGui {
    param($Gui)
    $Script:Provider = $Gui.Provider
    $Script:Model = $Gui.Model
    if ($Gui.OllamaHost) { $Script:OllamaHost = $Gui.OllamaHost }
    $Script:ApiKey = $Gui.ApiKey
    $Script:AzureEndpoint = $Gui.AzureEndpoint
    $Script:AzureDeployment = $Gui.AzureDeployment
    $Script:ScheduleFrequency = $Gui.ScheduleFrequency
    $Script:ScheduleTime = $Gui.ScheduleTime
    $Script:SchedulerPolicy = $Gui.SchedulerPolicy
    # Mirror back to function-scope params consumed downstream.
    Set-Variable -Name Provider -Value $Gui.Provider -Scope 1
    Set-Variable -Name Model -Value $Gui.Model -Scope 1
    if ($Gui.OllamaHost) { Set-Variable -Name OllamaHost -Value $Gui.OllamaHost -Scope 1 }
    Set-Variable -Name ApiKey -Value $Gui.ApiKey -Scope 1
    Set-Variable -Name AzureEndpoint -Value $Gui.AzureEndpoint -Scope 1
    Set-Variable -Name AzureDeployment -Value $Gui.AzureDeployment -Scope 1
    Set-Variable -Name ScheduleFrequency -Value $Gui.ScheduleFrequency -Scope 1
    Set-Variable -Name ScheduleTime -Value $Gui.ScheduleTime -Scope 1
    Set-Variable -Name SchedulerPolicy -Value $Gui.SchedulerPolicy -Scope 1
}

if (Test-TruthyEnvValue $env:AUTORESEARCH_DOT_SOURCE_ONLY) {
    Write-BootstrapMessage "Import-only mode enabled via AUTORESEARCH_DOT_SOURCE_ONLY; skipping bootstrap and relaunch for target '$Script:CanonicalRepo'."
    return
}

try {
    if ($RunLoop) {
        try {
            $loopLock = Enter-AutoresearchLoopLock -RepoRootPath $RepoRoot
        } catch {
            [Console]::Error.WriteLine("Autoresearch loop could not acquire the repository lock: $($_.Exception.Message)")
            exit 1
        }
        if (-not $loopLock.Acquired) {
            Write-Host (Format-AutoresearchLoopLockBusyMessage -Owner $loopLock.Owner) -ForegroundColor Yellow
            exit 2
        }
        $Script:AutoresearchLoopLock = $loopLock
    }

    Initialize-LauncherStorage
    if ($Script:DebugEnabled) {
        Write-Json -Level info -Message "Debug logging enabled" -Extra @{
            aggregateLog = $Script:AggregateLog
            logDir       = $LogDir
            pwsh         = $PSVersionTable.PSVersion.ToString()
        }
        Write-DebugLog "Invocation parameters" -Extra @{
            Provider             = $Provider
            Model                = $Model
            OllamaHost           = $OllamaHost
            RepoRoot             = $RepoRoot
            LogDir               = $LogDir
            ScheduleFrequency    = $ScheduleFrequency
            ScheduleTime         = $ScheduleTime
            SchedulerPolicy      = $SchedulerPolicy
            RegisterTask         = [bool]$RegisterTask
            RunNow               = [bool]$RunNow
            RunLoop              = [bool]$RunLoop
            MaxLoopMinutes       = $MaxLoopMinutes
            MaxConsecutiveIterationFailures = $MaxConsecutiveIterationFailures
            PerRunTimeoutMinutes = $PerRunTimeoutMinutes
            NoAiEdit             = [bool]$NoAiEdit
            Unregister           = [bool]$Unregister
            Update               = [bool]$Update
            NoGui                = [bool]$NoGui
            BoundKeys            = @($PSBoundParameters.Keys)
        }
    }
    if ([string]::IsNullOrWhiteSpace($ScheduleTime)) {
        $ScheduleTime = Get-ScheduleTimeDefault -Frequency $ScheduleFrequency
    }
    Initialize-LaunchConfig -Bound $PSBoundParameters
    # Defaults may select a custom log directory, so protect the final path
    # after persisted configuration has been applied as well.
    Initialize-LauncherStorage
    $scheduleOpts = Get-ScheduleTimeOptions -Frequency $ScheduleFrequency
    if ($scheduleOpts -notcontains $ScheduleTime) {
        if ($PSBoundParameters.ContainsKey('ScheduleTime')) {
            Test-ScheduleTime -Frequency $ScheduleFrequency -Value $ScheduleTime
        } else {
            $ScheduleTime = Get-ScheduleTimeDefault -Frequency $ScheduleFrequency
        }
    }
    $actionGiven = ($RegisterTask -or $RunNow -or $RunLoop -or $Unregister -or $Update -or $TaskSupervisor)
    if ($TaskSupervisor -and ($RegisterTask -or $RunNow -or $RunLoop -or $Unregister -or $Update)) {
        throw '-TaskSupervisor cannot be combined with other action switches.'
    }
    if (-not $NoGui -and -not $actionGiven) {
        $gui = Show-LaunchGui
        if (-not $gui) { exit 0 }
        Invoke-FromGui -Gui $gui
        switch ($gui.Action) {
            'Preflight'   { }
            'RunNow'      { $RunNow = $true }
            'Register'    { $RegisterTask = $true }
            'RegisterRun' { $RegisterTask = $true; $RunNow = $true }
            'Unregister'  { $Unregister = $true }
            'Update'      { $Update = $true }
        }
    }
    if ($Unregister) {
        Unregister-LauncherTask
        exit 0
    }
    if ($TaskSupervisor) {
        $code = Invoke-TaskLaunchSupervisor
        exit ([int]$code)
    }
    Invoke-Preflight
    if ($Update) {
        Invoke-Update
    }
    if ($RegisterTask) {
        Register-LauncherTask
    }
    if ($RunNow) {
        $code = Invoke-Workload
        exit ([int]$code)
    }
    if ($RunLoop) {
        $code = Invoke-AutoresearchLoop
        exit ([int]$code)
    }
    if (-not ($RegisterTask -or $Update)) {
        $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $Script:CanonicalScript }
        $powerShellCommand = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' }
        Write-Json -Level info -Message 'Preflight OK. No action selected; nothing to do.'
        Write-Host ''
        Write-Host 'Preflight OK. Re-run with one of:' -ForegroundColor Cyan
        Write-Host "  $powerShellCommand -File `"$scriptPath`"                 # GUI launcher"
        Write-Host "  $powerShellCommand -File `"$scriptPath`" -NoGui -RunNow  # single training run via ai-powered"
        Write-Host "  $powerShellCommand -File `"$scriptPath`" -NoGui -RunLoop  # autoresearch experiment loop"
        Write-Host "  $powerShellCommand -File `"$scriptPath`" -NoGui -RunLoop -MaxLoopMinutes 120  # loop with 2-hour limit"
        Write-Host "  $powerShellCommand -File `"$scriptPath`" -NoGui -RegisterTask -ScheduleFrequency $ScheduleFrequency -ScheduleTime $ScheduleTime -SchedulerPolicy $SchedulerPolicy"
        Write-Host "  $powerShellCommand -File `"$scriptPath`" -NoGui -RegisterTask -SchedulerPolicy Unattended -ScheduleFrequency $ScheduleFrequency -ScheduleTime $ScheduleTime"
        Write-Host "  $powerShellCommand -File `"$scriptPath`" -NoGui -Unregister"
        Write-Host "  $powerShellCommand -File `"$scriptPath`" -NoGui -Update"
        Write-Host ''
    }
    exit 0
} catch {
    $errMessage = $_.Exception.Message
    try { Write-Json -Level error -Message $errMessage } catch {}
    Write-Error $errMessage
    exit 1
} finally {
    if ($null -ne $Script:AutoresearchLoopLock) {
        $loopLock = $Script:AutoresearchLoopLock
        $Script:AutoresearchLoopLock = $null
        Exit-AutoresearchLoopLock -Lock $loopLock
    }
}
