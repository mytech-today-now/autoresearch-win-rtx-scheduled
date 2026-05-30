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
    by default; pass -NoGui for unattended/headless invocations.

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
         -ScheduleFrequency Hourly -ScheduleTime ':30'
    # Run every hour at HH:30 local.

.EXAMPLE
    pwsh -File .\scripts\launch.ps1 -RegisterTask `
         -ScheduleFrequency Weekly -ScheduleTime 'Wednesday'
    # Run weekly on Wednesdays at 03:00 local.

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
    [switch]$RegisterTask,
    [switch]$RunNow,
    [switch]$Unregister,
    [switch]$Update,
    [switch]$NoGui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ConfirmPreference = 'None'

$Script:TaskName = 'Autoresearch-Train'
$Script:TaskPath = '\myTech.Today\'
$Script:InstallRoot = Join-Path $env:HOMEDRIVE 'myTech.Today'
$Script:CanonicalRepo = Join-Path $Script:InstallRoot 'autoresearch-win-rtx-scheduled'
$Script:CanonicalScript = Join-Path $Script:CanonicalRepo 'scripts\launch.ps1'
$Script:DefaultsPath = Join-Path (Split-Path -Parent $Script:CanonicalScript) 'launch.json'
$Script:RepoUrl = 'https://github.com/mytech-today-now/autoresearch-win-rtx-scheduled.git'
$Script:AggregateLog = Join-Path $LogDir 'autoresearch.jsonl'
$Script:RunLogPath = $null
$Script:LogRetention = 10

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

function Test-RunningFromCanonical {
    $self = $PSCommandPath
    if ([string]::IsNullOrEmpty($self)) { return $false }
    if (-not (Test-Path -LiteralPath $Script:CanonicalScript)) { return $false }
    $a = (Resolve-Path -LiteralPath $self).Path
    $b = (Resolve-Path -LiteralPath $Script:CanonicalScript).Path
    return ($a -ieq $b)
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
        & git -C $Script:CanonicalRepo pull --ff-only | Out-Null
    }
    $pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $pwshCmd) { $pwshCmd = Get-Command powershell.exe -ErrorAction Stop }
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $Script:CanonicalScript) + $ForwardArgs
    $p = Start-Process -FilePath $pwshCmd.Source -ArgumentList $argList -NoNewWindow -PassThru -Wait
    exit $p.ExitCode
}

if (-not (Test-RunningFromCanonical)) {
    Invoke-Bootstrap -ForwardArgs (ConvertTo-ForwardArgs $PSBoundParameters)
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
    Install-Tool -Name 'ai-powered' -NpmPackage 'ai-powered'
    Assert-RepoLayout
    if ($Provider -eq 'ollama') {
        Install-Tool -Name 'ollama' -WingetId 'Ollama.Ollama'
        Start-OllamaServer
        Sync-OllamaModel
    }
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
    $pwshPath = Get-PwshExePath
    $scriptPath = $Script:CanonicalScript
    $argParts = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$scriptPath`"",'-NoGui','-RunNow','-Provider',$Provider,'-Model',"`"$Model`"")
    if ($Provider -eq 'ollama') { $argParts += @('-OllamaHost',"`"$OllamaHost`"") }
    $argument = ($argParts -join ' ')
    $action = New-ScheduledTaskAction -Execute $pwshPath -Argument $argument -WorkingDirectory $RepoRoot
    $trigger = Get-TaskTrigger
    $userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) `
        -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $Script:TaskName -TaskPath $Script:TaskPath `
        -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Autoresearch: uv run train.py via ai-powered.' | Out-Null
    Enable-TaskHistoryLog
    Write-Json -Level info -Message "Registered scheduled task $($Script:TaskPath)$($Script:TaskName)" -Extra @{
        schedule = $ScheduleFrequency
        time     = $ScheduleTime
        command  = "$pwshPath $argument"
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
            foreach ($k in 'Provider','Model','OllamaHost','AzureEndpoint','AzureDeployment','LogDir','ScheduleFrequency','ScheduleTime') {
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
        }
    }
}

function Show-LaunchGui {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $d = Read-LaunchDefaults
    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="autoresearch launcher" Width="520" SizeToContent="Height"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize">
  <StackPanel Margin="10">
    <GroupBox Header="Action" Padding="6" Margin="0,0,0,6">
      <StackPanel>
        <RadioButton x:Name="ActPreflight" Content="Preflight only"/>
        <RadioButton x:Name="ActRunNow" Content="Run training now" IsChecked="True"/>
        <RadioButton x:Name="ActRegister" Content="Register scheduled task"/>
        <RadioButton x:Name="ActRegisterRun" Content="Register task and run now"/>
        <RadioButton x:Name="ActUnregister" Content="Unregister scheduled task"/>
        <RadioButton x:Name="ActUpdate" Content="Update toolchain"/>
      </StackPanel>
    </GroupBox>
    <GroupBox Header="AI Provider" Padding="6" Margin="0,0,0,6">
      <StackPanel>
        <StackPanel Orientation="Horizontal">
          <RadioButton x:Name="PrvOllama" GroupName="prv" Content="Ollama (local)" IsChecked="True" Margin="0,0,8,0"/>
          <RadioButton x:Name="PrvOpenAI" GroupName="prv" Content="OpenAI" Margin="0,0,8,0"/>
          <RadioButton x:Name="PrvAnthropic" GroupName="prv" Content="Anthropic" Margin="0,0,8,0"/>
          <RadioButton x:Name="PrvAzure" GroupName="prv" Content="Azure OpenAI"/>
        </StackPanel>
        <Label Content="Model"/>
        <ComboBox x:Name="CbModel"/>
        <Label Content="Ollama host (Ollama only)"/>
        <ComboBox x:Name="CbHost" IsEditable="True">
          <ComboBoxItem Content="http://127.0.0.1:11434" IsSelected="True"/>
          <ComboBoxItem Content="http://localhost:11434"/>
        </ComboBox>
        <Label Content="API key (OpenAI / Anthropic / Azure)"/>
        <PasswordBox x:Name="PbApiKey"/>
        <Label x:Name="LblAzEp" Content="Azure endpoint" Visibility="Collapsed"/>
        <TextBox x:Name="TxtAzEp" Visibility="Collapsed"/>
        <Label x:Name="LblAzDp" Content="Azure deployment" Visibility="Collapsed"/>
        <TextBox x:Name="TxtAzDp" Visibility="Collapsed"/>
      </StackPanel>
    </GroupBox>
    <GroupBox Header="Schedule" Padding="6" Margin="0,0,0,6">
      <StackPanel>
        <Label Content="Frequency"/>
        <ComboBox x:Name="CbFreq">
          <ComboBoxItem Content="Hourly"/>
          <ComboBoxItem Content="Daily" IsSelected="True"/>
          <ComboBoxItem Content="Weekly"/>
        </ComboBox>
        <Label x:Name="LblTime" Content="Time (HH:mm, local)"/>
        <ComboBox x:Name="CbTime"/>
        <CheckBox x:Name="ChkHistory" Content="Enable Task Scheduler history (requires elevation)" IsChecked="True" Margin="0,6,0,0"/>
      </StackPanel>
    </GroupBox>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
      <Button x:Name="BtnDefaults" Content="Save as Defaults" Width="120" Margin="0,0,6,0"/>
      <Button x:Name="BtnCancel" Content="Cancel" Width="80" Margin="0,0,6,0"/>
      <Button x:Name="BtnOK" Content="OK" Width="80" IsDefault="True"/>
    </StackPanel>
  </StackPanel>
</Window>
"@
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $script:C = @{}
    foreach ($n in 'ActPreflight','ActRunNow','ActRegister','ActRegisterRun','ActUnregister','ActUpdate',
        'PrvOllama','PrvOpenAI','PrvAnthropic','PrvAzure','CbModel','CbHost','PbApiKey',
        'LblAzEp','TxtAzEp','LblAzDp','TxtAzDp','CbFreq','LblTime','CbTime','ChkHistory','BtnDefaults','BtnCancel','BtnOK') {
        $script:C[$n] = $window.FindName($n)
    }
    $script:applyFreqItems = {
        $freq = if ($script:C.CbFreq.SelectedItem) { [string]$script:C.CbFreq.SelectedItem.Content } else { 'Daily' }
        $script:C.CbTime.SelectedIndex = -1
        $script:C.CbTime.ItemsSource = $null
        $opts = Get-ScheduleTimeOptions -Frequency $freq
        $script:C.CbTime.ItemsSource = $opts
        $script:C.LblTime.Content = switch ($freq) {
            'Hourly' { 'Minute of hour' }
            'Weekly' { 'Day of week' }
            default  { 'Time of day (HH:mm, local)' }
        }
        $defVal = Get-ScheduleTimeDefault -Frequency $freq
        $idx = [array]::IndexOf($opts, $defVal)
        if ($idx -ge 0) { $script:C.CbTime.SelectedIndex = $idx }
    }
    $script:C.CbFreq.add_SelectionChanged({ & $script:applyFreqItems })
    $script:populateModels = {
        param($prv)
        $script:C.CbModel.Items.Clear()
        foreach ($m in $Script:ProviderModels[$prv]) { $script:C.CbModel.Items.Add($m) | Out-Null }
        $script:C.CbModel.SelectedIndex = 0
        $azVis = if ($prv -eq 'azure') { 'Visible' } else { 'Collapsed' }
        foreach ($k in 'LblAzEp','TxtAzEp','LblAzDp','TxtAzDp') { $script:C[$k].Visibility = $azVis }
        $script:C.CbHost.IsEnabled = ($prv -eq 'ollama')
    }
    $script:C.PrvOllama.Add_Checked({ & $script:populateModels 'ollama' })
    $script:C.PrvOpenAI.Add_Checked({ & $script:populateModels 'openai' })
    $script:C.PrvAnthropic.Add_Checked({ & $script:populateModels 'anthropic' })
    $script:C.PrvAzure.Add_Checked({ & $script:populateModels 'azure' })
    & $script:populateModels 'ollama'
    if ($d) {
        switch ($d.Provider) {
            'openai'    { $script:C.PrvOpenAI.IsChecked = $true }
            'anthropic' { $script:C.PrvAnthropic.IsChecked = $true }
            'azure'     { $script:C.PrvAzure.IsChecked = $true }
            default     { $script:C.PrvOllama.IsChecked = $true }
        }
        if ($d.Model) { $script:C.CbModel.SelectedItem = $d.Model }
        if ($d.OllamaHost) { $script:C.CbHost.Text = $d.OllamaHost }
        if ($d.ScheduleFrequency) {
            $script:C.CbFreq.SelectedItem = ($script:C.CbFreq.Items | Where-Object { $_.Content -eq $d.ScheduleFrequency } | Select-Object -First 1)
        }
        if ($d.AzureEndpoint) { $script:C.TxtAzEp.Text = $d.AzureEndpoint }
        if ($d.AzureDeployment) { $script:C.TxtAzDp.Text = $d.AzureDeployment }
    }
    & $script:applyFreqItems
    if ($d -and $d.ScheduleTime) {
        $src = @($script:C.CbTime.ItemsSource)
        $idx = $src.IndexOf([string]$d.ScheduleTime)
        if ($idx -ge 0) { $script:C.CbTime.SelectedIndex = $idx }
    }
    $Script:GuiResult = $null
    $script:collect = {
        $prv = if ($script:C.PrvOpenAI.IsChecked) { 'openai' }
               elseif ($script:C.PrvAnthropic.IsChecked) { 'anthropic' }
               elseif ($script:C.PrvAzure.IsChecked) { 'azure' }
               else { 'ollama' }
        @{
            Provider          = $prv
            Model             = [string]$script:C.CbModel.SelectedItem
            OllamaHost        = [string]$script:C.CbHost.Text
            ApiKey            = $script:C.PbApiKey.Password
            AzureEndpoint     = $script:C.TxtAzEp.Text
            AzureDeployment   = $script:C.TxtAzDp.Text
            ScheduleFrequency = [string]$script:C.CbFreq.SelectedItem.Content
            ScheduleTime      = [string]$script:C.CbTime.SelectedItem
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
        $vals = & $script:collect
        $persist = @{} + $vals
        $persist.Remove('ApiKey') | Out-Null
        Save-LaunchDefaults -Values $persist
    })
    $script:C.BtnCancel.Add_Click({ $window.DialogResult = $false; $window.Close() })
    $script:C.BtnOK.Add_Click({ $Script:GuiResult = & $script:collect; $window.DialogResult = $true; $window.Close() })
    $ok = $window.ShowDialog()
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
    # Mirror back to function-scope params consumed downstream.
    Set-Variable -Name Provider -Value $Gui.Provider -Scope 1
    Set-Variable -Name Model -Value $Gui.Model -Scope 1
    if ($Gui.OllamaHost) { Set-Variable -Name OllamaHost -Value $Gui.OllamaHost -Scope 1 }
    Set-Variable -Name ApiKey -Value $Gui.ApiKey -Scope 1
    Set-Variable -Name AzureEndpoint -Value $Gui.AzureEndpoint -Scope 1
    Set-Variable -Name AzureDeployment -Value $Gui.AzureDeployment -Scope 1
    Set-Variable -Name ScheduleFrequency -Value $Gui.ScheduleFrequency -Scope 1
    Set-Variable -Name ScheduleTime -Value $Gui.ScheduleTime -Scope 1
}

try {
    New-Dir $LogDir
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
    $actionGiven = ($RegisterTask -or $RunNow -or $Unregister -or $Update)
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
    if (-not ($RegisterTask -or $Update)) {
        $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $Script:CanonicalScript }
        Write-Json -Level info -Message 'Preflight OK. No action selected; nothing to do.'
        Write-Host ''
        Write-Host 'Preflight OK. Re-run with one of:' -ForegroundColor Cyan
        Write-Host "  pwsh -File `"$scriptPath`"                 # GUI launcher"
        Write-Host "  pwsh -File `"$scriptPath`" -NoGui -RunNow  # headless run via ai-powered"
        Write-Host "  pwsh -File `"$scriptPath`" -NoGui -RegisterTask -ScheduleFrequency $ScheduleFrequency -ScheduleTime $ScheduleTime"
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
