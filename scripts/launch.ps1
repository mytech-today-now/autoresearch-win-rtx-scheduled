#Requires -Version 5.1
<#
.SYNOPSIS
    Runs `uv run train.py` via the `ai-powered` CLI against Ollama
    qwen2.5-coder:latest, optionally executed by a Windows Scheduled Task.

.DESCRIPTION
    Performs preflight checks (PATH, dependencies, Ollama daemon, model),
    streams stdout/stderr as JSON lines to a per-invocation log, and manages
    a Scheduled Task named Autoresearch-Train. Pure non-interactive workflow.
    Compatible with Windows PowerShell 5.1 and PowerShell 7+.

    USAGE OVERVIEW
    --------------
    The script has four mutually independent ACTION switches. If none are
    supplied, the script only runs preflight and prints usage hints; it will
    NOT train and will NOT create a scheduled task.

      Switch          Effect
      --------------  ----------------------------------------------------------
      (none)          Preflight only. Prints next-step hints and exits 0.
      -RunNow         Runs `uv run train.py` once, in the foreground.
                      Does NOT register a scheduled task.
      -RegisterTask   Creates/replaces the `Autoresearch-Train` scheduled
                      task. Does NOT run training in this invocation.
      -Unregister     Removes the scheduled task if present and exits.
      -Update         Upgrades uv, Ollama, ai-powered, and re-pulls the model.

    Combine -RegisterTask with -RunNow to both schedule the task AND run
    training immediately in the same invocation.

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
    Time-of-day to start the scheduled task, formatted 'HH:mm' (24-hour,
    local time). Only consulted when -RegisterTask is supplied. The task is
    anchored to today's date at this time; the trigger then repeats per
    -ScheduleFrequency.
    Default: '03:00'.

    Example (schedule for 11:30 PM local):
        pwsh -File .\scripts\launch.ps1 -RegisterTask -ScheduleTime '23:30'

.PARAMETER ScheduleFrequency
    Trigger cadence for the scheduled task. Only consulted when
    -RegisterTask is supplied. Allowed values:
      * Hourly  - Fires at -ScheduleTime then repeats every 1 hour.
      * Daily   - Fires once a day at -ScheduleTime.
      * Weekly  - Fires every Sunday at -ScheduleTime.
    Default: 'Daily'.

    Example (every hour starting at the top of the hour):
        pwsh -File .\scripts\launch.ps1 -RegisterTask `
             -ScheduleFrequency Hourly -ScheduleTime '00:00'

.PARAMETER RegisterTask
    Switch. When set, creates (or replaces) a Windows scheduled task named
    `Autoresearch-Train` that re-invokes this script with `-RunNow` on the
    configured trigger. The task runs as the current user with S4U logon
    (no stored password), at highest run level, and is allowed to start on
    battery. An existing task with the same name is unregistered first.

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
    # 03:00 local time. Does not run training in this invocation; the
    # task itself will invoke the script with -RunNow when it fires.

.EXAMPLE
    pwsh -File .\scripts\launch.ps1 -RegisterTask -RunNow
    # Schedule the daily task AND run one training experiment immediately.

.EXAMPLE
    pwsh -File .\scripts\launch.ps1 -RegisterTask `
         -ScheduleFrequency Hourly -ScheduleTime '00:15'
    # Run every hour starting at 00:15 local.

.EXAMPLE
    pwsh -File .\scripts\launch.ps1 -RegisterTask `
         -ScheduleFrequency Weekly -ScheduleTime '02:00'
    # Run weekly on Sundays at 02:00 local.

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
      Per-run files are pruned to the newest 190 automatically.

    Scheduled task:
      Name:        Autoresearch-Train
      Action:      pwsh.exe -NoProfile -ExecutionPolicy Bypass `
                            -File <this script> -RunNow
      Principal:   current user, S4U logon, RunLevel Highest
      Settings:    StartWhenAvailable, AllowStartIfOnBatteries,
                   DontStopIfGoingOnBatteries, RestartCount=3,
                   RestartInterval=5m, MultipleInstances=IgnoreNew

    Requirements:
      Windows PowerShell 5.1 or PowerShell 7+, internet access for the
      first preflight (to install missing tools and pull the model).
#>
[CmdletBinding()]
param(
    [string]$Model = 'qwen2.5-coder:latest',
    [string]$OllamaHost = 'http://127.0.0.1:11434',
    [string]$RepoRoot,
    [string]$LogDir = "$env:HOMEDRIVE\myTech.Today\logs",
    [string]$ScheduleTime = '03:00',
    [ValidateSet('Hourly', 'Daily', 'Weekly')]
    [string]$ScheduleFrequency = 'Daily',
    [switch]$RegisterTask,
    [switch]$RunNow,
    [switch]$Unregister,
    [switch]$Update
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ConfirmPreference = 'None'

$Script:TaskName = 'Autoresearch-Train'
$Script:AggregateLog = Join-Path $LogDir 'autoresearch.jsonl'
$Script:RunLogPath = $null
$Script:LogRetention = 190

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
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
        [ValidateSet('info', 'warn', 'error', 'stdout', 'stderr')][string]$Level,
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
    if (Test-CommandOnPath $Name) { return }
    Write-Json -Level info -Message "$Name not on PATH; attempting install"
    $ok = $false
    if ($WingetId) {
        $ok = Invoke-Winget @('install', '--id', $WingetId, '--source', 'winget',
            '--accept-package-agreements', '--accept-source-agreements',
            '--silent', '--disable-interactivity')
    }
    if (-not $ok -and $PipxPackage -and (Test-CommandOnPath 'pipx')) {
        & pipx install $PipxPackage | Out-Null
        $ok = ($LASTEXITCODE -eq 0)
    }
    if (-not $ok -and $PipPackage -and (Test-CommandOnPath 'pip')) {
        & pip install --user $PipPackage | Out-Null
        $ok = ($LASTEXITCODE -eq 0)
    }
    if (-not $ok -and $NpmPackage -and (Test-CommandOnPath 'npm')) {
        & npm install -g $NpmPackage | Out-Null
        $ok = ($LASTEXITCODE -eq 0)
    }
    Update-SessionPath
    if (-not (Test-CommandOnPath $Name)) {
        throw "$Name is required but could not be installed automatically. Install $Name manually and re-run."
    }
}

function Test-OllamaListening {
    try {
        Invoke-RestMethod -Uri ("$OllamaHost/api/tags") -Method Get -TimeoutSec 2 | Out-Null
        return $true
    } catch {
        return $false
    }
}


function Start-OllamaServer {
    if (Test-OllamaListening) { return }
    Write-Json -Level info -Message "Starting ollama serve detached at $OllamaHost"
    $ollamaCmd = Get-Command ollama -ErrorAction Stop
    $hostPort = $OllamaHost -replace '^https?://', ''
    [Environment]::SetEnvironmentVariable('OLLAMA_HOST', $hostPort, 'Process')
    Start-Process -FilePath $ollamaCmd.Source -ArgumentList 'serve' -WindowStyle Hidden | Out-Null
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if (Test-OllamaListening) { return }
        Start-Sleep -Seconds 2
    }
    throw "ollama did not become ready at $OllamaHost within 60 seconds. Run 'ollama serve' manually to diagnose."
}

function Test-OllamaModelPresent {
    try {
        $tags = Invoke-RestMethod -Uri ("$OllamaHost/api/tags") -Method Get -TimeoutSec 5
        if ($null -eq $tags -or -not (Get-Member -InputObject $tags -Name 'models' -MemberType NoteProperty)) { return $false }
        return [bool]($tags.models | Where-Object { $_.name -eq $Model })
    } catch {
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
}

function Assert-RepoLayout {
    if (-not (Test-Path -LiteralPath $RepoRoot)) {
        throw "Repo root not found: $RepoRoot"
    }
    $trainPy = Join-Path $RepoRoot 'train.py'
    if (-not (Test-Path -LiteralPath $trainPy)) {
        throw "train.py not found at $trainPy"
    }
    $venv = Join-Path $RepoRoot '.venv'
    if (-not (Test-Path -LiteralPath $venv)) {
        Write-Json -Level info -Message "Project virtualenv missing; running 'uv sync'"
        Push-Location $RepoRoot
        try {
            & uv sync
            if ($LASTEXITCODE -ne 0) {
                throw "uv sync failed (exit $LASTEXITCODE)"
            }
        } finally {
            Pop-Location
        }
    }
}

function Invoke-Preflight {
    New-Dir $LogDir
    Install-Tool -Name 'uv' -WingetId 'astral-sh.uv' -PipxPackage 'uv' -PipPackage 'uv'
    Install-Tool -Name 'ollama' -WingetId 'Ollama.Ollama'
    Install-Tool -Name 'ai-powered' -NpmPackage 'ai-powered'
    Assert-RepoLayout
    Start-OllamaServer
    Sync-OllamaModel
}

function Invoke-Update {
    Write-Json -Level info -Message 'Upgrading uv via self update'
    if (Test-CommandOnPath 'uv') {
        & uv self update 2>&1 | Out-Null
    }
    Write-Json -Level info -Message 'Upgrading Ollama via winget'
    Invoke-Winget @('upgrade', '--id', 'Ollama.Ollama', '--silent',
        '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity') | Out-Null
    Write-Json -Level info -Message 'Upgrading ai-powered via npm -g'
    if (Test-CommandOnPath 'npm') {
        & npm install -g ai-powered@latest | Out-Null
    }
    Update-SessionPath
    Start-OllamaServer
    Write-Json -Level info -Message "Re-pulling model $Model"
    & ollama pull $Model
    if ($LASTEXITCODE -ne 0) {
        throw "ollama pull $Model failed (exit $LASTEXITCODE)"
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
    [Environment]::SetEnvironmentVariable('AI_PROVIDER', 'custom', 'Process')
}

function Invoke-Workload {
    Set-WorkloadEnvironment
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $Script:RunLogPath = Join-Path $LogDir "autoresearch-run-$stamp.jsonl"
    New-Item -ItemType File -Path $Script:RunLogPath -Force | Out-Null

    Write-Json -Level info -Message 'Starting workload' -Extra @{
        repoRoot   = $RepoRoot
        model      = $Model
        ollamaHost = $OllamaHost
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

function Get-PwshExePath {
    $candidate = Get-Command 'pwsh.exe' -ErrorAction SilentlyContinue
    if ($candidate) { return $candidate.Source }
    $candidate = Get-Command 'pwsh' -ErrorAction SilentlyContinue
    if ($candidate) { return $candidate.Source }
    throw 'pwsh.exe is required for the scheduled task action but was not found on PATH.'
}

function Get-TaskTrigger {
    $timeSpan = [TimeSpan]::Parse($ScheduleTime)
    $startAt = ([DateTime]::Today).Add($timeSpan)
    switch ($ScheduleFrequency) {
        'Hourly' {
            $trigger = New-ScheduledTaskTrigger -Once -At $startAt -RepetitionInterval (New-TimeSpan -Hours 1)
        }
        'Daily' {
            $trigger = New-ScheduledTaskTrigger -Daily -At $startAt
        }
        'Weekly' {
            $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At $startAt
        }
    }
    return $trigger
}

function Register-LauncherTask {
    if (Get-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue) {
        Write-Json -Level info -Message "Existing task $($Script:TaskName) found; replacing"
        Unregister-ScheduledTask -TaskName $Script:TaskName -Confirm:$false
    }
    $pwshPath = Get-PwshExePath
    $scriptPath = [System.IO.Path]::GetFullPath($PSCommandPath)
    $argument = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -RunNow"
    $action = New-ScheduledTaskAction -Execute $pwshPath -Argument $argument -WorkingDirectory $RepoRoot
    $trigger = Get-TaskTrigger
    $userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType S4U -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) `
        -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $Script:TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings `
        -Description 'Autoresearch: uv run train.py via ai-powered against Ollama qwen2.5-coder.' | Out-Null
    Write-Json -Level info -Message "Registered scheduled task $($Script:TaskName)" -Extra @{
        schedule = $ScheduleFrequency
        time     = $ScheduleTime
        command  = "$pwshPath $argument"
    }
}

function Unregister-LauncherTask {
    if (Get-ScheduledTask -TaskName $Script:TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $Script:TaskName -Confirm:$false
        Write-Json -Level info -Message "Unregistered scheduled task $($Script:TaskName)"
    } else {
        Write-Json -Level info -Message "Scheduled task $($Script:TaskName) was not present"
    }
}

try {
    New-Dir $LogDir
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
    if (-not ($RegisterTask -or $Update)) {
        $scriptPath = $PSCommandPath
        Write-Json -Level info -Message 'Preflight OK. No action switch supplied; nothing to do.'
        Write-Host ''
        Write-Host 'Preflight OK. No action switch supplied. Choose one of:' -ForegroundColor Cyan
        Write-Host "  pwsh -File `"$scriptPath`" -RunNow         # run 'uv run train.py' now via ai-powered + Ollama"
        Write-Host "  pwsh -File `"$scriptPath`" -RegisterTask   # schedule Autoresearch-Train at $ScheduleTime $ScheduleFrequency"
        Write-Host "  pwsh -File `"$scriptPath`" -Unregister     # remove the scheduled task"
        Write-Host "  pwsh -File `"$scriptPath`" -Update         # upgrade uv, ollama, ai-powered and re-pull the model"
        Write-Host ''
    }
    exit 0
} catch {
    $errMessage = $_.Exception.Message
    try { Write-Json -Level error -Message $errMessage } catch {}
    Write-Error $errMessage
    exit 1
}
