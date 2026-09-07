#Requires -Version 5.1
# Quick Start (remote one-liner). Either form installs this repo to
# %HOMEDRIVE%\myTech.Today\autoresearch-win-rtx-scheduled\ and runs launch.ps1
# from there, forwarding any CLI arguments verbatim.
#   PowerShell:
#     powershell -ExecutionPolicy Bypass -Command "iwr https://raw.githubusercontent.com/mytech-today-now/autoresearch-win-rtx-scheduled/refs/heads/main/scripts/launch.ps1 | iex"
#   CMD:
#     powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr 'https://raw.githubusercontent.com/mytech-today-now/autoresearch-win-rtx-scheduled/refs/heads/main/scripts/launch.ps1' | iex"
<#
.SYNOPSIS
    Runs `uv run train.py` via the `ai-powered` CLI against a selected AI
    provider, optionally executed by a Windows Scheduled Task. Self-installs
    to %HOMEDRIVE%\myTech.Today\autoresearch-win-rtx-scheduled\ when invoked
    from anywhere else (including via `iwr ... | iex`). Presents a WPF GUI
    by default; pass -NoGui for unattended/headless invocations. The GUI and
    CLI now expose an explicit scheduler policy so the task can be registered
    as interactive, idle-only, or unattended.

.DESCRIPTION
    Performs preflight checks (PATH, dependencies, Ollama daemon, model),
    streams stdout/stderr as JSON lines to a per-invocation log, and manages
    a Scheduled Task named Autoresearch-Train. Pure non-interactive workflow.
    Compatible with Windows PowerShell 5.1 and PowerShell 7+.

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
                      program.md (edit train.py via ai-powered, commit, run,
                      decide keep/discard, log to results.tsv, repeat) until
                      -MaxLoopMinutes elapses or the process is killed.
      -RegisterTask   Creates/replaces the `Autoresearch-Train` scheduled
                      task. Does NOT run training in this invocation. The
                      task's action drives -RunLoop, not a single -RunNow.
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
    Per-run files older than the newest 190 are pruned automatically.
    Default: "$env:HOMEDRIVE\myTech.Today\logs" (typically C:\myTech.Today\logs).

    Example:
        pwsh -File .\scripts\launch.ps1 -RunNow -LogDir 'D:\logs\autoresearch'

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

    Example (register an unattended overnight task):
        pwsh -File .\scripts\launch.ps1 -NoGui -RegisterTask `
             -SchedulerPolicy Unattended

.PARAMETER RegisterTask
    Switch. When set, creates (or replaces) a Windows scheduled task named
    `Autoresearch-Train` that re-invokes this script with `-RunLoop` on the
    configured trigger. The selected scheduler policy controls whether the
    task is interactive, idle-only, or unattended. An existing task with the
    same name is unregistered first.

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
      * `uv self update`
      * `winget upgrade --id Ollama.Ollama` (silent)
      * `npm install -g ai-powered@latest`
    Then restarts the Ollama daemon if needed and re-pulls -Model. Can be
    combined with -RegisterTask and/or -RunNow.

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
                in -RunNow mode the script propagates the workload's exit code.

    Logs:
      Aggregate JSONL: <LogDir>\autoresearch.jsonl
      Per-run JSONL:   <LogDir>\autoresearch-run-<UTC-stamp>.jsonl
      Per-run files are pruned to the newest 10 automatically.

    Scheduled task:
      Name:        Autoresearch-Train
      Action:      pwsh.exe -NoProfile -ExecutionPolicy Bypass
                            -EncodedCommand <base64-Start-Process>
                   The encoded command runs Start-Process to spawn launch.ps1
                   in its own detached process (-WindowStyle Hidden) with the
                   -RunLoop switch, so the task action exits immediately and
                   the experiment loop runs independently.
      Workload:    The detached process drives the autoresearch loop from
                   program.md: it edits train.py via `ai-powered text`, runs
                   `uv run train.py` per iteration (10-minute kill switch by
                   default), parses val_bpb/peak_vram_mb from run.log,
                   appends a row to results.tsv, and reverts the commit when
                   val_bpb did not improve. The loop continues until
                   -MaxLoopMinutes elapses (default 0 = forever) or the
                   process is killed.
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
    [string]$ScheduleTime,
    [ValidateSet('Hourly', 'Daily', 'Weekly')]
    [string]$ScheduleFrequency = 'Daily',
    [ValidateSet('Interactive', 'IdleOnly', 'Unattended')]
    [string]$SchedulerPolicy = 'IdleOnly',
    [switch]$RegisterTask,
    [switch]$RunNow,
    [switch]$RunLoop,
    [int]$MaxLoopMinutes = 0,
    [int]$PerRunTimeoutMinutes = 10,
    [switch]$NoAiEdit,
    [switch]$Unregister,
    [switch]$Update,
    [switch]$NoBootstrap,
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
$Script:DefaultsPath = Join-Path (Split-Path -Parent $Script:CanonicalScript) 'launch.json'
$Script:RepoUrl = 'https://github.com/mytech-today-now/autoresearch-win-rtx-scheduled.git'
$Script:AggregateLog = Join-Path $LogDir 'autoresearch.jsonl'
$Script:RunLogPath = $null
$Script:LogRetention = 10
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
    if (-not (Test-Path -LiteralPath $Script:CanonicalRepo)) {
        & git clone $Script:RepoUrl $Script:CanonicalRepo
        if ($LASTEXITCODE -ne 0) { Write-Error 'git clone failed'; exit 3 }
    } else {
        $status = & git -C $Script:CanonicalRepo status --porcelain 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Unable to inspect canonical install at '$Script:CanonicalRepo' before bootstrap (git status --porcelain failed with exit $LASTEXITCODE)."
            exit 4
        }
        if (-not [string]::IsNullOrWhiteSpace($status)) {
            Write-Error "Refusing to bootstrap canonical install at '$Script:CanonicalRepo' because it has local changes. Commit, stash, or clean the tree before re-running."
            exit 4
        }
        & git -C $Script:CanonicalRepo pull --ff-only | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Error "git pull --ff-only failed for '$Script:CanonicalRepo'"; exit 3 }
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

function Write-Json {
    param(
        [ValidateSet('info', 'warn', 'error', 'stdout', 'stderr', 'debug')][string]$Level,
        [string]$Message,
        [hashtable]$Extra = $null
    )
    $record = [ordered]@{
        ts    = (Get-Date).ToUniversalTime().ToString('o')
        level = $Level
        msg   = $Message
    }
    if ($null -ne $Extra) {
        foreach ($k in $Extra.Keys) { $record[$k] = $Extra[$k] }
    }
    $line = $record | ConvertTo-Json -Compress -Depth 6
    New-Dir (Split-Path -Parent $Script:AggregateLog)
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
    New-Dir $LogDir
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

function Invoke-Update {
    Write-Json -Level info -Message 'Upgrading uv via self update'
    if (Test-CommandOnPath 'uv') {
        & uv self update 2>&1 | Out-Null
    }
    if ($Provider -eq 'ollama') {
        Write-Json -Level info -Message 'Upgrading Ollama via winget'
        Invoke-Winget @('upgrade', '--id', 'Ollama.Ollama', '--silent',
            '--accept-package-agreements', '--accept-source-agreements',
            '--disable-interactivity') | Out-Null
    }
    Write-Json -Level info -Message 'Upgrading ai-powered via npm -g'
    if (Test-CommandOnPath 'npm') {
        & npm install -g ai-powered@latest | Out-Null
    }
    Update-SessionPath
    if ($Provider -eq 'ollama') {
        Start-OllamaServer
        Write-Json -Level info -Message "Re-pulling model $Model"
        & ollama pull $Model
        if ($LASTEXITCODE -ne 0) {
            throw "ollama pull $Model failed (exit $LASTEXITCODE)"
        }
    }
}

function Limit-RunLogs {
    if (-not (Test-Path -LiteralPath $LogDir)) { return }
    $files = Get-ChildItem -LiteralPath $LogDir -Filter 'autoresearch-run-*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending
    if (-not $files -or $files.Count -le $Script:LogRetention) { return }
    $files | Select-Object -Skip $Script:LogRetention | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Set-WorkloadEnvironment {
    [Environment]::SetEnvironmentVariable('OLLAMA_HOST', $OllamaHost, 'Process')
    [Environment]::SetEnvironmentVariable('AI_POWERED_MODEL', $Model, 'Process')
    [Environment]::SetEnvironmentVariable('AI_MODEL', $Model, 'Process')
    $apProvider = switch ($Provider) { 'ollama' { 'custom' } default { $Provider } }
    [Environment]::SetEnvironmentVariable('AI_PROVIDER', $apProvider, 'Process')
    if ($ApiKey) {
        switch ($Provider) {
            'openai'    { [Environment]::SetEnvironmentVariable('OPENAI_API_KEY', $ApiKey, 'Process') }
            'anthropic' { [Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', $ApiKey, 'Process') }
            'azure'     { [Environment]::SetEnvironmentVariable('AZURE_OPENAI_API_KEY', $ApiKey, 'Process') }
        }
    }
    if ($Provider -eq 'azure') {
        if ($AzureEndpoint) { [Environment]::SetEnvironmentVariable('AZURE_OPENAI_ENDPOINT', $AzureEndpoint, 'Process') }
        if ($AzureDeployment) { [Environment]::SetEnvironmentVariable('AZURE_OPENAI_DEPLOYMENT', $AzureDeployment, 'Process') }
    }
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
    Write-Json -Level info -Message 'Workload finished' -Extra @{ exitCode = $exitCode }
    Limit-RunLogs
    return $exitCode
}

# --------------------------------------------------------------------------
# Autoresearch experiment loop (driven by program.md). The deterministic
# bookkeeping lives here in PowerShell; the per-iteration code edit step is
# delegated to a single `ai-powered text` call. Because `ai-powered` is a
# text/image/audio client (not an agentic code editor), the edit step is
# best-effort: the model is asked to return a complete replacement train.py
# inside a fenced ```python block. If the response cannot be parsed, the
# iteration is recorded as 'crash' and the working tree is reset.
# --------------------------------------------------------------------------

function Initialize-ResultsTsv {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Set-Content -LiteralPath $Path -Encoding UTF8 `
            -Value "commit`tval_bpb`tmemory_gb`tstatus`tdescription"
        Write-Json -Level info -Message "Initialized results.tsv at $Path"
    }
}

function Get-CurrentBestValBpb {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $best = $null
    Get-Content -LiteralPath $Path -Encoding UTF8 | Select-Object -Skip 1 | ForEach-Object {
        $cols = $_ -split "`t"
        if ($cols.Count -ge 4 -and $cols[3] -eq 'keep') {
            $v = 0.0
            if ([double]::TryParse($cols[1], [ref]$v) -and $v -gt 0) {
                if ($null -eq $best -or $v -lt $best) { $best = $v }
            }
        }
    }
    return $best
}

function Add-ResultsTsvRow {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Commit,
        [double]$ValBpb,
        [double]$MemoryGb,
        [Parameter(Mandatory)][ValidateSet('keep','discard','crash')][string]$Status,
        [Parameter(Mandatory)][string]$Description
    )
    $desc = ($Description -replace "[`t`r`n]", ' ').Trim()
    $row  = "{0}`t{1}`t{2}`t{3}`t{4}" -f `
        $Commit, $ValBpb.ToString('F6'), $MemoryGb.ToString('F1'), $Status, $desc
    Add-Content -LiteralPath $Path -Value $row -Encoding UTF8
}

function Read-RunLogMetrics {
    param([Parameter(Mandatory)][string]$Path)
    $valBpb   = 0.0
    $vramMb   = 0.0
    if (-not (Test-Path -LiteralPath $Path)) { return @{ ValBpb = 0.0; PeakVramMb = 0.0 } }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ($line -match '^val_bpb:\s*([0-9.]+)')        { [void][double]::TryParse($Matches[1], [ref]$valBpb) }
        elseif ($line -match '^peak_vram_mb:\s*([0-9.]+)') { [void][double]::TryParse($Matches[1], [ref]$vramMb) }
    }
    return @{ ValBpb = $valBpb; PeakVramMb = $vramMb }
}

function Invoke-Git {
    param([Parameter(Mandatory)][string[]]$GitArgs, [string]$Cwd = $RepoRoot)
    $out = & git -C $Cwd @GitArgs 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out.Trim() }
}

function Invoke-AiPoweredEdit {
    param(
        [Parameter(Mandatory)][string]$RepoRootPath,
        [int]$ResultsTailRows = 20
    )
    $programPath = Join-Path $RepoRootPath 'program.md'
    $trainPath   = Join-Path $RepoRootPath 'train.py'
    $resultsPath = Join-Path $RepoRootPath 'results.tsv'
    if (-not (Test-Path -LiteralPath $programPath)) { Write-Json -Level warn -Message 'program.md missing; skipping AI edit'; return $null }
    if (-not (Test-Path -LiteralPath $trainPath))   { Write-Json -Level warn -Message 'train.py missing; skipping AI edit';   return $null }
    $program  = Get-Content -LiteralPath $programPath -Raw -Encoding UTF8
    $train    = Get-Content -LiteralPath $trainPath   -Raw -Encoding UTF8
    $results  = if (Test-Path -LiteralPath $resultsPath) {
        ((Get-Content -LiteralPath $resultsPath -Encoding UTF8) | Select-Object -Last $ResultsTailRows) -join "`n"
    } else { '' }
    $system = 'You are an autonomous ML research agent. Reply with EXACTLY one short one-line description prefixed by "DESCRIPTION: ", then a single fenced code block ```python containing the COMPLETE new contents of train.py. No other text.'
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
    $tmpPrompt = [System.IO.Path]::GetTempFileName()
    Set-Content -LiteralPath $tmpPrompt -Value $prompt -Encoding UTF8
    try {
        $raw = & ai-powered text --quiet --system $system (Get-Content -LiteralPath $tmpPrompt -Raw) 2>&1 | Out-String
    } finally {
        Remove-Item -LiteralPath $tmpPrompt -Force -ErrorAction SilentlyContinue
    }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        Write-Json -Level warn -Message 'ai-powered text returned no output' -Extra @{ exit = $LASTEXITCODE }
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

function Invoke-AutoresearchIteration {
    param(
        [Parameter(Mandatory)][string]$RepoRootPath,
        [Parameter(Mandatory)][string]$ResultsPath,
        [int]$PerRunTimeoutMin = 10,
        [switch]$SkipAiEdit,
        [switch]$BaselineRun
    )

    $startCommit = (Invoke-Git -GitArgs @('rev-parse','HEAD') -Cwd $RepoRootPath).Output
    $description = if ($BaselineRun) { 'baseline' } else { 'autoresearch iteration' }
    $appliedEdit = $false

    # Edit step (skipped on the baseline run or when -NoAiEdit is set).
    if (-not $SkipAiEdit -and -not $BaselineRun) {
        $edit = Invoke-AiPoweredEdit -RepoRootPath $RepoRootPath
        if ($null -ne $edit) {
            if ($edit.Description) { $description = $edit.Description }
            if ($edit.NewContent) {
                Set-Content -LiteralPath (Join-Path $RepoRootPath 'train.py') `
                    -Value $edit.NewContent -Encoding UTF8 -NoNewline
                $appliedEdit = $true
                Write-Json -Level info -Message 'Applied AI-proposed edit to train.py' -Extra @{ description = $description }
            }
        }
        if (-not $appliedEdit) {
            Write-Json -Level info -Message 'No edit applied this iteration' -Extra @{ description = $description }
        }
    }

    # Commit the (possibly edited) state so we can revert cleanly on discard.
    & git -C $RepoRootPath add -A 2>&1 | Out-Null
    & git -C $RepoRootPath -c 'user.name=autoresearch' -c 'user.email=autoresearch@local' `
        commit --allow-empty -m ("autoresearch: " + $description) 2>&1 | Out-Null
    $iterCommit = (Invoke-Git -GitArgs @('rev-parse','HEAD') -Cwd $RepoRootPath).Output
    $shortSha   = if ($iterCommit) { $iterCommit.Substring(0, [Math]::Min(7, $iterCommit.Length)) } else { '0000000' }

    # Run training with a per-run wall-clock kill switch.
    $runLog = Join-Path $RepoRootPath 'run.log'
    if (Test-Path -LiteralPath $runLog) { Remove-Item -LiteralPath $runLog -Force -ErrorAction SilentlyContinue }
    Write-Json -Level info -Message 'Iteration: starting uv run train.py' -Extra @{ commit = $shortSha; timeoutMin = $PerRunTimeoutMin }
    $proc = Start-Process -FilePath 'uv' -ArgumentList @('run','train.py') `
        -WorkingDirectory $RepoRootPath -NoNewWindow -PassThru `
        -RedirectStandardOutput $runLog -RedirectStandardError (Join-Path $RepoRootPath 'run.err.log')
    $killed = $false
    if (-not $proc.WaitForExit([int]($PerRunTimeoutMin * 60 * 1000))) {
        try { $proc.Kill($true) } catch { }
        $killed = $true
        Write-Json -Level warn -Message 'Iteration exceeded per-run timeout; killed' -Extra @{ commit = $shortSha }
    }
    # Merge stderr file into run.log so downstream parsing is unified.
    $errFile = Join-Path $RepoRootPath 'run.err.log'
    if (Test-Path -LiteralPath $errFile) {
        Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue | Add-Content -LiteralPath $runLog -Encoding UTF8
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
    $metrics = Read-RunLogMetrics -Path $runLog
    $valBpb  = $metrics.ValBpb
    $memGb   = if ($metrics.PeakVramMb -gt 0) { $metrics.PeakVramMb / 1024.0 } else { 0.0 }

    # Decide outcome.
    $status = 'crash'
    if (-not $killed -and $valBpb -gt 0) {
        $best = Get-CurrentBestValBpb -Path $ResultsPath
        if ($BaselineRun -or $null -eq $best -or $valBpb -lt $best) {
            $status = 'keep'
        } else {
            $status = 'discard'
        }
    }

    Add-ResultsTsvRow -Path $ResultsPath -Commit $shortSha `
        -ValBpb $valBpb -MemoryGb $memGb -Status $status -Description $description

    if ($status -ne 'keep' -and $startCommit) {
        # Revert any edits + the commit we just made.
        & git -C $RepoRootPath reset --hard $startCommit 2>&1 | Out-Null
        Write-Json -Level info -Message 'Iteration reverted to start commit' -Extra @{
            startCommit = $startCommit.Substring(0,7); status = $status
        }
    }

    Write-Json -Level info -Message 'Iteration finished' -Extra @{
        commit = $shortSha; valBpb = $valBpb; memoryGb = $memGb; status = $status; description = $description
    }
    return @{ Commit = $shortSha; ValBpb = $valBpb; MemoryGb = $memGb; Status = $status; Description = $description }
}

function Invoke-AutoresearchLoop {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $Script:RunLogPath = Join-Path $LogDir "autoresearch-loop-$stamp.jsonl"
    New-Item -ItemType File -Path $Script:RunLogPath -Force | Out-Null

    if (-not (Invoke-IdlePolicyGate -Policy $SchedulerPolicy -IdleMinutes 5 -WaitTimeoutMinutes 60)) {
        Limit-RunLogs
        return 0
    }

    Set-WorkloadEnvironment

    $resultsPath = Join-Path $RepoRoot 'results.tsv'
    Initialize-ResultsTsv -Path $resultsPath

    $deadline = if ($MaxLoopMinutes -gt 0) { (Get-Date).AddMinutes($MaxLoopMinutes) } else { [DateTime]::MaxValue }
    Write-Json -Level info -Message 'Starting autoresearch loop' -Extra @{
        repoRoot             = $RepoRoot
        runLog               = $Script:RunLogPath
        resultsTsv           = $resultsPath
        maxLoopMinutes       = $MaxLoopMinutes
        perRunTimeoutMinutes = $PerRunTimeoutMinutes
        noAiEdit             = [bool]$NoAiEdit
        schedulerPolicy      = $SchedulerPolicy
        policySummary        = (Get-SchedulerPolicyInfo -Policy $SchedulerPolicy).Summary
        deadline             = if ($deadline -eq [DateTime]::MaxValue) { 'none' } else { $deadline.ToString('o') }
    }

    # Baseline iteration first if results.tsv is empty (only the header row).
    $hasBaseline = $false
    if (Test-Path -LiteralPath $resultsPath) {
        $rowCount = (@(Get-Content -LiteralPath $resultsPath -Encoding UTF8) | Where-Object { $_ -and $_ -notmatch '^commit\t' }).Count
        $hasBaseline = ($rowCount -gt 0)
    }
    if (-not $hasBaseline) {
        Write-Json -Level info -Message 'No baseline row in results.tsv; running baseline iteration'
        [void](Invoke-AutoresearchIteration -RepoRootPath $RepoRoot -ResultsPath $resultsPath `
            -PerRunTimeoutMin $PerRunTimeoutMinutes -BaselineRun)
    }

    $iter = 0
    while ((Get-Date) -lt $deadline) {
        $iter++
        Write-Json -Level info -Message "Autoresearch iteration #$iter starting"
        try {
            [void](Invoke-AutoresearchIteration -RepoRootPath $RepoRoot -ResultsPath $resultsPath `
                -PerRunTimeoutMin $PerRunTimeoutMinutes -SkipAiEdit:$NoAiEdit)
        } catch {
            Write-Json -Level error -Message "Iteration #$iter raised: $($_.Exception.Message)"
            # Keep looping; per-iteration failures should not kill the whole loop.
        }
    }

    Write-Json -Level info -Message 'Autoresearch loop deadline reached; exiting' -Extra @{ iterations = $iter }
    Limit-RunLogs
    return 0
}

function Get-PwshExePath {
    $candidate = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
    if ($candidate) { return $candidate.Source }
    $candidate = Get-Command 'pwsh' -ErrorAction SilentlyContinue
    if ($candidate) { return $candidate.Source }
    throw 'pwsh.exe is required for the scheduled task action but was not found on PATH.'
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
    $pwshPath = Get-PwshExePath
    $scriptPath = $Script:CanonicalScript

    # Build the inner argument list for the autoresearch loop invocation. Using
    # an array literal avoids quoting ambiguity when embedded inside the
    # base64-encoded Start-Process command below.
    $innerArgList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath,
                      '-NoGui', '-RunLoop', '-Provider', $Provider, '-Model', $Model,
                      '-SchedulerPolicy', $SchedulerPolicy,
                      '-MaxLoopMinutes', $MaxLoopMinutes,
                      '-PerRunTimeoutMinutes', $PerRunTimeoutMinutes)
    if ($Provider -eq 'ollama') { $innerArgList += @('-OllamaHost', $OllamaHost) }
    if ($NoAiEdit) { $innerArgList += '-NoAiEdit' }
    $innerArgArray = ($innerArgList | ForEach-Object { "'$_'" }) -join ','

    # Wrap the invocation in Start-Process so the task action exits immediately
    # and the training script runs in its own detached process.
    $spCommand = "Start-Process -FilePath '$pwshPath' -ArgumentList @($innerArgArray) -WindowStyle Hidden"
    $spBytes   = [System.Text.Encoding]::Unicode.GetBytes($spCommand)
    $spEncoded = [Convert]::ToBase64String($spBytes)
    $argument  = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $spEncoded"

    return [pscustomobject]@{
        PwshPath        = $pwshPath
        ScriptPath      = $scriptPath
        InnerArgList    = $innerArgList
        StartProcess    = $spCommand
        EncodedArgument = $argument
        WorkloadCommand = "$pwshPath $($innerArgList -join ' ')"
    }
}

function Get-ScheduledTaskDescription {
    param([Parameter(Mandatory)]$PolicyInfo)
    return "Autoresearch: uv run train.py via ai-powered. Policy: $($PolicyInfo.DisplayName). $($PolicyInfo.Summary)"
}

function Get-ComputerIdleState {
    if (-not $IsWindows) {
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

        [DllImport("user32.dll")]
        private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

        [DllImport("kernel32.dll")]
        private static extern uint GetTickCount();

        public static uint GetIdleMilliseconds() {
            LASTINPUTINFO info = new LASTINPUTINFO();
            info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
            GetLastInputInfo(ref info);
            return GetTickCount() - info.dwTime;
        }
    }
}
"@ -Language CSharp
        }

        $idleMs = [Autoresearch.IdleNative]::GetIdleMilliseconds()
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
            Reason     = $_.Exception.Message
        }
    }
}

function Invoke-IdlePolicyGate {
    param(
        [Parameter(Mandatory)][string]$Policy,
        [int]$IdleMinutes = 5,
        [int]$WaitTimeoutMinutes = 60,
        [int]$PollIntervalSeconds = 30
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
        $state = Get-ComputerIdleState
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

    $finalState = Get-ComputerIdleState
    $observed = if ($finalState.Available) { $finalState.IdleMinutes } else { $null }
    Write-Json -Level info -Message "Idle-only policy skipped after waiting $WaitTimeoutMinutes minute(s); observed idle time was $observed minute(s), which did not reach the required $IdleMinutes minute(s)." -Extra @{
        policy            = $Policy
        observedIdle      = $observed
        requiredIdle      = $IdleMinutes
        waitTimeoutMinutes = $WaitTimeoutMinutes
    }
    return $false
}

function Get-TaskXml {
    $policy = Get-SchedulerPolicyInfo -Policy $SchedulerPolicy
    $schedule = Get-ScheduleTriggerSpec -Frequency $ScheduleFrequency -Value $ScheduleTime
    $plan = Get-TaskLauncherPlan

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
    $action.Path = $plan.PwshPath
    $action.Arguments = $plan.EncodedArgument
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
    $existing = Get-RegisteredLauncherTask
    if ($existing) {
        Write-Json -Level info -Message "Existing task $($Script:TaskName) found; replacing"
        Unregister-ScheduledTask -TaskPath $existing.TaskPath -TaskName $existing.TaskName -Confirm:$false
    }
    $policy = Get-SchedulerPolicyInfo -Policy $SchedulerPolicy
    $plan = Get-TaskLauncherPlan
    Write-Json -Level info -Message "Registering scheduled task $($Script:TaskPath)$($Script:TaskName) with $($policy.DisplayName) policy" -Extra @{
        schedulerPolicy = $SchedulerPolicy
        policySummary   = $policy.Summary
        logonType       = $policy.LogonTypeName
        requiresDesktop = $policy.RequiresDesktopSession
        idleGate        = $policy.UsesIdleGate
    }
    $xml = Get-TaskXml

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
        launcherCommand      = "$($plan.PwshPath) $($plan.EncodedArgument)"
        workloadCommand      = $plan.WorkloadCommand
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
    if (Test-Path -LiteralPath $Script:DefaultsPath) {
        try { return Get-Content -LiteralPath $Script:DefaultsPath -Raw | ConvertFrom-Json } catch { return $null }
    }
    return $null
}

function Save-LaunchDefaults {
    param([hashtable]$Values)
    New-Dir (Split-Path -Parent $Script:DefaultsPath)
    ($Values | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $Script:DefaultsPath -Encoding UTF8
}

function Initialize-LaunchConfig {
    param([System.Collections.IDictionary]$Bound)
    if (Test-Path -LiteralPath $Script:DefaultsPath) {
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
            <TextBlock Text="Model" TextWrapping="Wrap" Margin="0,0,0,2"/>
            <ComboBox x:Name="CbModel" TabIndex="10" HorizontalAlignment="Stretch" MinWidth="260" Margin="0,0,0,6"/>
            <TextBlock Text="Ollama host (Ollama only)" TextWrapping="Wrap" Margin="0,0,0,2"/>
            <ComboBox x:Name="CbHost" TabIndex="11" HorizontalAlignment="Stretch" MinWidth="260" IsEditable="True" Margin="0,0,0,6">
          <ComboBoxItem Content="http://127.0.0.1:11434" IsSelected="True"/>
          <ComboBoxItem Content="http://localhost:11434"/>
        </ComboBox>
            <TextBlock Text="API key (OpenAI / Anthropic / Azure)" TextWrapping="Wrap" Margin="0,0,0,2"/>
            <PasswordBox x:Name="PbApiKey" TabIndex="12" HorizontalAlignment="Stretch" MinWidth="260" Margin="0,0,0,6"/>
            <TextBlock x:Name="LblAzEp" Text="Azure endpoint" Visibility="Collapsed" TextWrapping="Wrap" Margin="0,0,0,2"/>
            <TextBox x:Name="TxtAzEp" TabIndex="13" HorizontalAlignment="Stretch" MinWidth="260" Visibility="Collapsed" Margin="0,0,0,6"/>
            <TextBlock x:Name="LblAzDp" Text="Azure deployment" Visibility="Collapsed" TextWrapping="Wrap" Margin="0,0,0,2"/>
            <TextBox x:Name="TxtAzDp" TabIndex="14" HorizontalAlignment="Stretch" MinWidth="260" Visibility="Collapsed"/>
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
            <TextBlock Text="Frequency" TextWrapping="Wrap" Margin="0,0,0,2"/>
            <ComboBox x:Name="CbFreq" TabIndex="18" HorizontalAlignment="Stretch" MinWidth="260" Margin="0,0,0,6">
              <ComboBoxItem Content="Hourly"/>
              <ComboBoxItem Content="Daily" IsSelected="True"/>
              <ComboBoxItem Content="Weekly"/>
            </ComboBox>
            <TextBlock x:Name="LblTime" Text="Time (HH:mm, local)" TextWrapping="Wrap" Margin="0,0,0,2"/>
            <ComboBox x:Name="CbTime" TabIndex="19" HorizontalAlignment="Stretch" MinWidth="260" Margin="0,0,0,6"/>
            <CheckBox x:Name="ChkHistory" TabIndex="20" IsChecked="True" Margin="0,6,0,0"><TextBlock Text="Enable Task Scheduler history (requires elevation)" TextWrapping="Wrap"/></CheckBox>
          </StackPanel>
        </GroupBox>
      </StackPanel>
    </ScrollViewer>
    <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="BtnDefaults" TabIndex="21" MinWidth="130" Margin="0,0,6,0"><TextBlock Text="Save as Defaults" TextWrapping="Wrap"/></Button>
      <Button x:Name="BtnCancel" TabIndex="22" MinWidth="90" Margin="0,0,6,0" IsCancel="True"><TextBlock Text="Cancel" TextWrapping="Wrap"/></Button>
      <Button x:Name="BtnOK" TabIndex="23" MinWidth="90" IsDefault="True"><TextBlock Text="OK" TextWrapping="Wrap"/></Button>
    </StackPanel>
  </Grid>
</Window>
"@
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $window.MaxWidth = [SystemParameters]::WorkArea.Width
    $window.MaxHeight = [SystemParameters]::WorkArea.Height
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
    New-Dir $LogDir
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
    $scheduleOpts = Get-ScheduleTimeOptions -Frequency $ScheduleFrequency
    if ($scheduleOpts -notcontains $ScheduleTime) {
        if ($PSBoundParameters.ContainsKey('ScheduleTime')) {
            Test-ScheduleTime -Frequency $ScheduleFrequency -Value $ScheduleTime
        } else {
            $ScheduleTime = Get-ScheduleTimeDefault -Frequency $ScheduleFrequency
        }
    }
    $actionGiven = ($RegisterTask -or $RunNow -or $RunLoop -or $Unregister -or $Update)
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
        Write-Json -Level info -Message 'Preflight OK. No action selected; nothing to do.'
        Write-Host ''
        Write-Host 'Preflight OK. Re-run with one of:' -ForegroundColor Cyan
        Write-Host "  pwsh -File `"$scriptPath`"                 # GUI launcher"
        Write-Host "  pwsh -File `"$scriptPath`" -NoGui -RunNow  # single training run via ai-powered"
        Write-Host "  pwsh -File `"$scriptPath`" -NoGui -RunLoop  # autoresearch experiment loop"
        Write-Host "  pwsh -File `"$scriptPath`" -NoGui -RunLoop -MaxLoopMinutes 120  # loop with 2-hour limit"
        Write-Host "  pwsh -File `"$scriptPath`" -NoGui -RegisterTask -ScheduleFrequency $ScheduleFrequency -ScheduleTime $ScheduleTime -SchedulerPolicy $SchedulerPolicy"
        Write-Host "  pwsh -File `"$scriptPath`" -NoGui -RegisterTask -SchedulerPolicy Unattended -ScheduleFrequency $ScheduleFrequency -ScheduleTime $ScheduleTime"
        Write-Host "  pwsh -File `"$scriptPath`" -NoGui -Unregister"
        Write-Host "  pwsh -File `"$scriptPath`" -NoGui -Update"
        Write-Host ''
    }
    exit 0
} catch {
    $errMessage = $_.Exception.Message
    try { Write-Json -Level error -Message $errMessage } catch {}
    Write-Error $errMessage
    exit 1
}
