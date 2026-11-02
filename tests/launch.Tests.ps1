#Requires -Version 5.1

$script:RequiredPesterVersion = [version]'5.0.0'
$script:PesterBootstrapScript = Join-Path $PSScriptRoot '..\scripts\install-pester.ps1'
function Test-RunningUnderPesterDiscovery {
    $stack = Get-PSCallStack
    return [bool]($stack | Where-Object {
        $_.Command -in @('Invoke-Pester', 'Discover-Test', 'Invoke-BlockContainer', 'Invoke-Test')
    })
}

if (-not (Test-RunningUnderPesterDiscovery)) {
    if (-not (Test-Path -LiteralPath $script:PesterBootstrapScript)) {
        throw "Pester $($script:RequiredPesterVersion) is required, but the bootstrap script was not found at '$script:PesterBootstrapScript'."
    }

    & $script:PesterBootstrapScript -RequiredVersion $script:RequiredPesterVersion

    $shell = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
    $quotedSelf = "'" + ($PSCommandPath -replace "'", "''") + "'"
    $command = @"
`$ErrorActionPreference = 'Stop'
Import-Module Pester -RequiredVersion $($script:RequiredPesterVersion) -Force
`$result = Invoke-Pester -Path $quotedSelf -Output Detailed -PassThru
if (`$result.FailedCount -gt 0) { exit 1 }
exit 0
"@
    & $shell -NoProfile -ExecutionPolicy Bypass -Command $command
    exit $LASTEXITCODE
}

function script:Get-LaunchFixtureState {
    $state = [ordered]@{}
    foreach ($name in @(
        'LogDir',
        'AggregateLog',
        'RunLogPath',
        'AutoresearchLoopLock',
        'LogRetentionCount',
        'LogRetentionDays',
        'TaskLaunchStatePath',
        'LauncherAclStatus',
        'RepoRoot',
        'CanonicalScript',
        'Provider',
        'Model',
        'OllamaHost',
        'ApiKey',
        'ProviderApiKeyForAi',
        'AzureEndpoint',
        'AzureDeployment',
        'SchedulerPolicy',
        'MaxLoopMinutes',
        'PerRunTimeoutMinutes',
        'NoAiEdit',
        'TaskName',
        'TaskPath',
        'ScheduledTaskAuthor',
        'TaskFixtureRoot',
        'ScheduleFrequency',
        'ScheduleTime',
        'captured',
        'historyCount',
        'installCalls',
        'rollbackCalls',
        'smokeCalls',
        'pathRefreshCount',
        'registerCount',
        'registeredTaskProbes',
        'startProcessArgs',
        'steps',
        'unregisterCount'
    )) {
        $variable = Get-Variable -Scope Script -Name $name -ErrorAction SilentlyContinue
        $state[$name] = if ($null -ne $variable) { $variable.Value } else { $null }
    }

    return [pscustomobject]$state
}

function script:Set-LaunchFixtureState {
    param([Parameter(Mandatory)][psobject]$State)

    foreach ($property in $State.PSObject.Properties) {
        Set-Variable -Scope Script -Name $property.Name -Value $property.Value -Force
    }
}

function script:Initialize-LaunchFixtureState {
    param([Parameter(Mandatory)][string]$LaunchScriptPath)

    $logDir = Join-Path (Join-Path $env:HOMEDRIVE 'myTech.Today') 'logs'
    $script:LogDir = $logDir
    $script:AggregateLog = Join-Path $logDir 'autoresearch.jsonl'
    $script:RunLogPath = $null
    $script:LogRetentionCount = 25
    $script:LogRetentionDays = 14
    $script:TaskLaunchStatePath = Join-Path $logDir 'autoresearch-task-launch.json'
    $script:LauncherAclStatus = @{}
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:CanonicalScript = (Resolve-Path -LiteralPath $LaunchScriptPath).Path
    $script:Provider = 'ollama'
    $script:Model = 'qwen2.5-coder:latest'
    $script:OllamaHost = 'http://127.0.0.1:11434'
    $script:ApiKey = $null
    $script:ProviderApiKeyForAi = $null
    $script:AzureEndpoint = $null
    $script:AzureDeployment = $null
    $script:SchedulerPolicy = 'IdleOnly'
    $script:TaskName = 'Autoresearch-Train'
    $script:TaskPath = '\myTech.Today\'
    $script:ScheduledTaskAuthor = 'myTech.Today (sales@mytech.today)'
    $script:TaskFixtureRoot = $null
    $script:ScheduleFrequency = 'Daily'
    $script:ScheduleTime = $null
    $script:MaxLoopMinutes = 0
    $script:PerRunTimeoutMinutes = 10
    $script:NoAiEdit = $false
    $script:captured = @()
    $script:historyCount = 0
    $script:installCalls = @()
    $script:rollbackCalls = @()
    $script:smokeCalls = @()
    $script:pathRefreshCount = 0
    $script:registerCount = 0
    $script:registeredTaskProbes = 0
    $script:startProcessArgs = $null
    $script:steps = @()
    $script:unregisterCount = 0
    $script:previousLaunchScope = Get-LaunchFixtureState
}

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..\scripts\launch.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "launch.ps1 not found at $scriptPath"
    }

    # Extract only the helper function definitions from launch.ps1 so the
    # script's top-level main flow (preflight, GUI, task registration) does
    # not execute when the test file loads.
    $wanted = @(
        'ConvertTo-SingleQuotedLiteral',
        'Format-CommandLine',
        'Format-CommandLineArgumentList',
        'ConvertTo-WeekdayMask',
        'Get-ComputerIdleState',
        'Get-CurrentProcessCommandLine',
        'Get-RedactedTaskLaunchCommandLine',
        'Get-RedactedTaskLaunchState',
        'Get-PwshExePath',
        'Get-ScheduleTriggerSpec',
        'Get-ScheduleTimeOptions',
        'Get-ScheduleTimeDefault',
        'Get-SchedulerPolicyInfo',
        'Get-ScheduledTaskDescription',
        'Get-TaskLauncherPlan',
        'Get-TaskXml',
        'Invoke-TaskLaunchSupervisor',
        'Test-ScheduleTime',
        'Get-TaskTrigger',
        'Invoke-IdlePolicyGate',
        'Get-ProviderApiKeyEnvironmentName',
        'Clear-ProviderApiKeyEnvironment',
        'Set-WorkloadEnvironment',
        'Get-VersionToken',
        'ConvertTo-VersionObject',
        'Get-ToolVersion',
        'Get-CompatibleVersionFromList',
        'Get-UvReleaseVersions',
        'Get-UvCompatibleTargetVersion',
        'Get-WingetPackageVersions',
        'Get-OllamaCompatibleTargetVersion',
        'Get-NpmGlobalPackageVersion',
        'Get-PinnedAiPoweredVersion',
        'Read-LaunchDefaults',
        'Save-LaunchDefaults',
        'Initialize-LaunchConfig',
        'Update-SessionPath',
        'Start-OllamaServer',
        'Sync-OllamaModel',
        'Add-RunLogReason',
        'Get-RunLogMetadata',
        'Get-RunLogRetentionPlan',
        'Limit-RunLogs',
        'Add-ResultsTsvRow',
        'Assert-AutoresearchSourceCheckoutClean',
        'Get-CurrentBestValBpb',
        'Initialize-ResultsTsv',
        'Invoke-AiPoweredEdit',
        'Invoke-AutoresearchGit',
        'Invoke-AutoresearchIteration',
        'Assert-AutoresearchGeneratedCodeReviewAvailable',
        'Confirm-AutoresearchGeneratedCode',
        'Get-AutoresearchLoopLockIdentity',
        'Read-AutoresearchLoopLockOwner',
        'Format-AutoresearchLoopLockBusyMessage',
        'Enter-AutoresearchLoopLock',
        'Exit-AutoresearchLoopLock',
        'Invoke-AutoresearchLoopCore',
        'Invoke-AutoresearchLoop',
        'Invoke-Git',
        'New-AutoresearchExperimentBranch',
        'Read-RunLogMetrics',
        'Invoke-UvSelfUpdate',
        'Test-UvSmoke',
        'Invoke-OllamaUpgrade',
        'Test-OllamaSmoke',
        'Invoke-AiPoweredInstall',
        'Test-AiPoweredSmoke',
        'Invoke-CompatibilityCheckedUpdateStep',
        'Invoke-UvUpdate',
        'Invoke-OllamaUpdate',
        'Invoke-AiPoweredUpdate',
        'Invoke-Update',
        'Write-Json',
        'Write-TaskLaunchState',
        'New-Dir',
        'Test-WindowsHost',
        'Get-LauncherAclPrincipals',
        'ConvertTo-LauncherSidValue',
        'Test-LauncherDirectoryAcl',
        'Set-LauncherDirectoryAcl',
        'Ensure-LauncherDirectoryAcl',
        'Initialize-LauncherStorage',
        'Get-TaskLaunchStatePath',
        'Register-LauncherTask',
        'Unregister-LauncherTask',
        'Get-RegisteredLauncherTask',
        'Enable-TaskHistoryLog'
    )
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath, [ref]$null, [ref]$null)
    $funcs = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | Where-Object { $wanted -contains $_.Name }
    foreach ($f in $funcs) {
        . ([scriptblock]::Create($f.Extent.Text))
    }

    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:CanonicalScript = (Resolve-Path $scriptPath).Path
    $script:TaskName = 'Autoresearch-Train'
    $script:TaskPath = '\myTech.Today\'
    $script:ScheduledTaskAuthor = 'myTech.Today (sales@mytech.today)'

    # Provide a stub when running on hosts without the Windows ScheduledTasks
    # module so Mock has a target to replace.
    if (-not (Get-Command New-ScheduledTaskTrigger -ErrorAction SilentlyContinue)) {
        function global:New-ScheduledTaskTrigger {
            [CmdletBinding()]
            param(
                [switch]$Once, [switch]$Daily, [switch]$Weekly,
                [datetime]$At, [timespan]$RepetitionInterval,
                $DaysOfWeek
            )
        }
    }

    Initialize-LaunchFixtureState -LaunchScriptPath $scriptPath
}

function script:New-TestRoot {
    param([string]$Name)
    $path = Join-Path $env:TEMP ("autoresearch-$Name-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function script:Write-RunLogFixture {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$ExitCode,
        [datetime]$LastWriteTimeUtc = (Get-Date).ToUniversalTime(),
        [switch]$IncludeErrorLine
    )

    $path = Join-Path $Directory $Name
    $lines = @(
        ([ordered]@{
            ts    = '2026-01-01T00:00:00.0000000Z'
            level = 'info'
            msg   = 'Starting workload'
        } | ConvertTo-Json -Compress)
    )
    if ($IncludeErrorLine) {
        $lines += ([ordered]@{
            ts    = '2026-01-01T00:00:01.0000000Z'
            level = 'error'
            msg   = 'simulated failure'
        } | ConvertTo-Json -Compress)
    }
    $lines += ([ordered]@{
        ts       = '2026-01-01T00:00:02.0000000Z'
        level    = 'info'
        msg      = 'Workload finished'
        exitCode = $ExitCode
    } | ConvertTo-Json -Compress)

    Set-Content -LiteralPath $path -Value $lines -Encoding UTF8
    [System.IO.File]::SetLastWriteTimeUtc($path, $LastWriteTimeUtc)
    return $path
}

function script:ConvertTo-SingleQuotedLiteral {
    param([Parameter(Mandatory)][string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

function script:New-FakeGitCommand {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$LogPath,
        [int]$PullExitCode = 0
    )
    $bin = Join-Path $Root 'bin'
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    $gitExecutable = (Get-Command git.exe -ErrorAction Stop).Source
    $content = @"
@echo off
setlocal
echo %*>>"$LogPath"
if /i "%1"=="clone" exit /b 81
if /i "%1"=="-C" if /i "%3"=="pull" exit /b $PullExitCode
if /i "%1"=="-C" if /i "%3"=="status" (
    "$gitExecutable" %*
    exit /b %errorlevel%
)
if /i "%1"=="-C" if /i "%3"=="remote" (
    "$gitExecutable" %*
    exit /b %errorlevel%
)
exit /b 0
"@
    Set-Content -LiteralPath (Join-Path $bin 'git.cmd') -Value $content -Encoding ASCII
    return $bin
}

function script:New-TemporaryGitRepository {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$OriginUrl,
        [switch]$Dirty
    )

    New-Item -ItemType Directory -Path (Join-Path $Root 'scripts') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Root '.gitignore') -Value 'ignored.sentinel' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $Root 'tracked.txt') -Value 'tracked baseline' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $Root 'scripts\launch.ps1') -Value '# canonical launcher fixture' -Encoding ASCII

    & git.exe -C $Root init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the temporary Git repository.' }
    & git.exe -C $Root add -- .gitignore tracked.txt scripts/launch.ps1
    if ($LASTEXITCODE -ne 0) { throw 'Could not stage the temporary Git repository fixture.' }
    & git.exe -C $Root -c user.name=BootstrapTest -c user.email=bootstrap@example.invalid commit --quiet -m initial
    if ($LASTEXITCODE -ne 0) { throw 'Could not commit the temporary Git repository fixture.' }
    & git.exe -C $Root remote add origin $OriginUrl
    if ($LASTEXITCODE -ne 0) { throw 'Could not configure the temporary Git repository origin.' }

    $trackedPath = Join-Path $Root 'tracked.txt'
    $untrackedPath = Join-Path $Root 'untracked.sentinel'
    $ignoredPath = Join-Path $Root 'ignored.sentinel'
    if ($Dirty) {
        Set-Content -LiteralPath $trackedPath -Value 'tracked user edit' -Encoding ASCII
        Set-Content -LiteralPath $untrackedPath -Value 'untracked user data' -Encoding ASCII
    }
    Set-Content -LiteralPath $ignoredPath -Value 'ignored user data' -Encoding ASCII

    return [pscustomobject]@{
        TrackedPath   = $trackedPath
        UntrackedPath = $untrackedPath
        IgnoredPath   = $ignoredPath
        LauncherPath  = Join-Path $Root 'scripts\launch.ps1'
    }
}

function script:Invoke-BootstrapTestFixture {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$CanonicalRepo,
        [Parameter(Mandatory)][string]$GitBin,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RepoUrl,
        [string[]]$ForwardArgs = @()
    )

    $startProcessLog = Join-Path $Root 'start-process.log'
    $removeItemLog = Join-Path $Root 'remove-item.log'
    $command = @"
`$ErrorActionPreference = 'Continue'
`$env:AUTORESEARCH_DOT_SOURCE_ONLY = '1'
function Start-Process {
    [CmdletBinding()]
    param(
        [string]`$FilePath,
        [object[]]`$ArgumentList,
        [switch]`$NoNewWindow,
        [switch]`$PassThru,
        [switch]`$Wait
    )
    [System.IO.File]::AppendAllText($(ConvertTo-SingleQuotedLiteral $startProcessLog), (`$FilePath + '|' + (`$ArgumentList -join '|') + [Environment]::NewLine))
    return [pscustomobject]@{ ExitCode = 0 }
}
function Remove-Item {
    [CmdletBinding()]
    param(
        [string]`$LiteralPath,
        [switch]`$Recurse,
        [switch]`$Force
    )
    [System.IO.File]::AppendAllText($(ConvertTo-SingleQuotedLiteral $removeItemLog), (`$LiteralPath + [Environment]::NewLine))
}
`$env:PATH = $(ConvertTo-SingleQuotedLiteral $GitBin) + ';' + `$env:PATH
. $(ConvertTo-SingleQuotedLiteral $ScriptPath)
Set-Variable -Scope Script -Name CanonicalRepo -Value $(ConvertTo-SingleQuotedLiteral $CanonicalRepo) -Force
Set-Variable -Scope Script -Name CanonicalScript -Value $(ConvertTo-SingleQuotedLiteral (Join-Path $CanonicalRepo 'scripts\launch.ps1')) -Force
Set-Variable -Scope Script -Name RepoUrl -Value $(ConvertTo-SingleQuotedLiteral $RepoUrl) -Force
Invoke-Bootstrap -ForwardArgs @($(($ForwardArgs | ForEach-Object { ConvertTo-SingleQuotedLiteral $_ }) -join ','))
"@

    return Invoke-PowershellCommandForTest -Command $command -Environment @{ PATH = "$GitBin;$env:PATH" }
}

function script:Write-FakePesterModule {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Version
    )

    $moduleRoot = Join-Path $Root (Join-Path 'Pester' $Version)
    New-Item -ItemType Directory -Path $moduleRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $moduleRoot 'Pester.psd1') -Value @"
@{
  RootModule = 'Pester.psm1'
  ModuleVersion = '$Version'
  GUID = '9b4b87df-5f8d-4a3e-83f7-9e2b0a2a7fd4'
  Author = 'autoresearch tests'
  CompanyName = 'autoresearch'
  PowerShellVersion = '5.1'
}
"@ -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $moduleRoot 'Pester.psm1') -Value @'
# Fake Pester module used by bootstrap regression tests.
'@ -Encoding ASCII
    return $moduleRoot
}

function script:Write-ProviderVerificationFixture {
    param([Parameter(Mandatory)][string]$Root)
    New-Item -ItemType Directory -Path (Join-Path $Root 'scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Root 'src') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Root 'package.json') -Value @'
{
  "dependencies": {
    "ai-powered": "^0.3.2"
  }
}
'@ -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $Root 'package-lock.json') -Value @'
{
  "name": "fixture",
  "lockfileVersion": 3,
  "packages": {
    "": {
      "dependencies": {
        "ai-powered": "^0.3.2"
      }
    }
  }
}
'@ -Encoding ASCII
}

function script:Invoke-PowershellCommandForTest {
    param(
        [Parameter(Mandatory)][string]$Command,
        [hashtable]$Environment = @{}
    )
    $previous = @{}
    $previousErrorActionPreference = $ErrorActionPreference
    foreach ($key in $Environment.Keys) {
        $previous[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
        [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], "Process")
    }
    try {
        $ErrorActionPreference = "Continue"
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -Command $Command 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output) }
    }
    finally {
        foreach ($key in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($key, $previous[$key], "Process")
        }
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function script:Invoke-ProviderVerificationForTest {
    param([Parameter(Mandatory)][string]$Root)
    Push-Location $Root
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $harnessRoot = Split-Path -Parent $PSScriptRoot
        $output = & node (Join-Path $harnessRoot 'scripts/verify-ai-provider.mjs') 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output) }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Pop-Location
    }
}

function script:Invoke-LauncherBootstrapRelaunchForTest {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$HomeDrive,
        [Parameter(Mandatory)][string]$GitBin,
        [Parameter(Mandatory)][string]$StartProcessLogPath,
        [string[]]$Arguments = @()
    )
    $quotedArgs = @()
    foreach ($arg in $Arguments) {
        $quotedArgs += (ConvertTo-SingleQuotedLiteral $arg)
    }
    $argText = if ($quotedArgs.Count -gt 0) { ' ' + ($quotedArgs -join ' ') } else { '' }
    $command = @"
`$ErrorActionPreference = 'Stop'
function Start-Process {
    param(
        [string]`$FilePath,
        [string[]]`$ArgumentList,
        [switch]`$NoNewWindow,
        [switch]`$PassThru,
        [switch]`$Wait
    )
    Add-Content -LiteralPath $(ConvertTo-SingleQuotedLiteral $StartProcessLogPath) -Value ('FilePath=' + `$FilePath)
    Add-Content -LiteralPath $(ConvertTo-SingleQuotedLiteral $StartProcessLogPath) -Value ('Args=' + (`$ArgumentList -join '|'))
    return [pscustomobject]@{ ExitCode = 0 }
}
& $(ConvertTo-SingleQuotedLiteral $ScriptPath)$argText
"@
    return Invoke-PowershellCommandForTest -Command $command -Environment @{
        HOMEDRIVE = $HomeDrive
        PATH      = "$GitBin;$env:PATH"
    }
}

function script:Get-LaunchGuiXaml {
    $launch = Get-Content -Path $scriptPath -Raw
    $match = [regex]::Match($launch, '(?s)\[xml\]\$xaml = @"\s*(<Window.*?</Window>)\s*"@')
    if (-not $match.Success) { throw "Unable to locate the launcher XAML block." }
    return $match.Groups[1].Value
}

function script:Initialize-TaskFixture {
    param([Parameter(Mandatory)][string]$Policy)
    $root = New-TestRoot "task-$Policy"
    New-Item -ItemType Directory -Path (Join-Path $root 'scripts') -Force | Out-Null
    $script:TaskFixtureRoot = $root
    $script:TaskName = 'Autoresearch-Train'
    $script:TaskPath = '\myTech.Today\'
    $script:ScheduledTaskAuthor = 'myTech.Today (sales@mytech.today)'
    $script:RepoRoot = $root
    $script:CanonicalScript = Join-Path $root 'scripts\launch.ps1'
    $script:Provider = 'ollama'
    $script:Model = 'qwen2.5-coder:latest'
    $script:OllamaHost = 'http://127.0.0.1:11434'
    $script:MaxLoopMinutes = 0
    $script:PerRunTimeoutMinutes = 10
    $script:NoAiEdit = $false
    $script:SchedulerPolicy = $Policy
    $script:ScheduleFrequency = 'Daily'
    $script:ScheduleTime = '18:00'
    return $root
}

function script:Get-AutoresearchFixtureGit {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string[]]$GitArgs
    )
    $output = & git -C $Root @GitArgs 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "Fixture Git command failed: git $($GitArgs -join ' '): $($output.Trim())"
    }
    return $output.TrimEnd([char[]]@("`r","`n"))
}

function script:Get-AutoresearchFixtureHash {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function script:Get-AutoresearchIterationTrainBytes {
    param(
        [Parameter(Mandatory)][psobject]$Fixture,
        [Parameter(Mandatory)][string]$Content
    )

    $expectedPath = Join-Path $Fixture.Container 'expected-train.py'
    try {
        Set-Content -LiteralPath $expectedPath -Value $Content -Encoding UTF8 -NoNewline
        return ,([System.IO.File]::ReadAllBytes($expectedPath))
    } finally {
        if (Test-Path -LiteralPath $expectedPath -PathType Leaf) {
            Remove-Item -LiteralPath $expectedPath -Force
        }
    }
}

function script:New-AutoresearchGitFixture {
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$Dirty
    )

    $container = New-TestRoot "iteration-$Name"
    $root = Join-Path $container 'source checkout with spaces'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $root '.gitignore') -Value "worktrees/`nignored.sentinel`n" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'train.py') -Value "print('baseline')" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'program.md') -Value 'fixture program' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'staged.sentinel') -Value 'staged baseline' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'unstaged.sentinel') -Value 'unstaged baseline' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'committed.sentinel') -Value 'committed baseline' -Encoding ASCII

    & git -C $root init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Could not initialize the autoresearch iteration fixture.' }
    & git -C $root add -- .gitignore train.py program.md staged.sentinel unstaged.sentinel committed.sentinel
    if ($LASTEXITCODE -ne 0) { throw 'Could not stage the autoresearch iteration fixture.' }
    & git -C $root -c user.name=IterationTest -c user.email=iteration@example.invalid commit --quiet -m initial
    if ($LASTEXITCODE -ne 0) { throw 'Could not commit the autoresearch iteration fixture.' }

    $sentinelPaths = @(
        'train.py', 'program.md', 'staged.sentinel', 'unstaged.sentinel', 'committed.sentinel'
    )
    if ($Dirty) {
        Set-Content -LiteralPath (Join-Path $root 'staged.sentinel') -Value 'staged user work' -Encoding ASCII
        & git -C $root add -- staged.sentinel
        if ($LASTEXITCODE -ne 0) { throw 'Could not stage the user sentinel change.' }
        Set-Content -LiteralPath (Join-Path $root 'unstaged.sentinel') -Value 'unstaged user work' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $root 'untracked.sentinel') -Value 'untracked user work' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $root 'ignored.sentinel') -Value 'ignored user work' -Encoding ASCII
        New-Item -ItemType Directory -Path (Join-Path $root 'worktrees') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'worktrees\ignored-user.sentinel') -Value 'ignored worktree parent data' -Encoding ASCII
        $sentinelPaths += @('untracked.sentinel','ignored.sentinel','worktrees\ignored-user.sentinel')
    }

    $status = Get-AutoresearchFixtureGit -Root $root -GitArgs @('status','--porcelain=1','--untracked-files=all')
    $indexRelativePath = Get-AutoresearchFixtureGit -Root $root -GitArgs @('rev-parse','--git-path','index')
    $indexPath = if ([System.IO.Path]::IsPathRooted($indexRelativePath)) {
        $indexRelativePath
    } else {
        Join-Path $root $indexRelativePath
    }
    $hashes = [ordered]@{}
    foreach ($relativePath in $sentinelPaths) {
        $hashes[$relativePath] = Get-AutoresearchFixtureHash -Path (Join-Path $root $relativePath)
    }

    return [pscustomobject]@{
        Container        = $container
        Root             = $root
        ResultsPath      = Join-Path $container 'results.tsv'
        OriginalBranch   = Get-AutoresearchFixtureGit -Root $root -GitArgs @('branch','--show-current')
        OriginalHead     = Get-AutoresearchFixtureGit -Root $root -GitArgs @('rev-parse','HEAD')
        OriginalStatus   = $status
        IndexPath        = [System.IO.Path]::GetFullPath($indexPath)
        OriginalIndexHash = Get-AutoresearchFixtureHash -Path $indexPath
        SentinelHashes   = $hashes
    }
}

function script:Assert-AutoresearchGitFixtureUnchanged {
    param([Parameter(Mandatory)][psobject]$Fixture)

    (Get-AutoresearchFixtureGit -Root $Fixture.Root -GitArgs @('rev-parse','HEAD')) | Should -BeExactly $Fixture.OriginalHead
    (Get-AutoresearchFixtureGit -Root $Fixture.Root -GitArgs @('branch','--show-current')) | Should -BeExactly $Fixture.OriginalBranch
    (Get-AutoresearchFixtureGit -Root $Fixture.Root -GitArgs @('status','--porcelain=1','--untracked-files=all')) | Should -BeExactly $Fixture.OriginalStatus
    (Get-AutoresearchFixtureHash -Path $Fixture.IndexPath) | Should -BeExactly $Fixture.OriginalIndexHash
    foreach ($relativePath in $Fixture.SentinelHashes.Keys) {
        (Get-AutoresearchFixtureHash -Path (Join-Path $Fixture.Root $relativePath)) |
            Should -BeExactly $Fixture.SentinelHashes[$relativePath]
    }
}

function script:New-AutoresearchLoopProcessFixture {
    param([Parameter(Mandatory)][string]$Name)

    $gitFixture = New-AutoresearchGitFixture -Name $Name
    $logDir = Join-Path $gitFixture.Container 'loop logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $resultsPath = Join-Path $gitFixture.Root 'results.tsv'
    $results = "commit`tval_bpb`tmemory_gb`tstatus`tdescription`r`nbase`t0.200000`t1.0`tkeep`tbaseline`r`n"
    [System.IO.File]::WriteAllText($resultsPath, $results, (New-Object System.Text.UTF8Encoding($false)))

    return [pscustomobject]@{
        GitFixture       = $gitFixture
        Root             = $gitFixture.Root
        Container        = $gitFixture.Container
        LogDir           = $logDir
        RunLogPath       = Join-Path $logDir 'run.log'
        ResultsPath      = $resultsPath
        AiCallsPath      = Join-Path $gitFixture.Container 'ai-calls.txt'
        GitMutationsPath = Join-Path $gitFixture.Container 'git-mutations.txt'
    }
}

function script:Get-AutoresearchLoopWorkerPaths {
    param(
        [Parameter(Mandatory)][psobject]$Fixture,
        [Parameter(Mandatory)][string]$RunId
    )

    return [pscustomobject]@{
        LaunchScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\launch.ps1'
        RepoRootPath     = $Fixture.Root
        LogDirPath       = $Fixture.LogDir
        RunId            = $RunId
        AiCallsPath      = $Fixture.AiCallsPath
        GitMutationsPath = $Fixture.GitMutationsPath
        ResultsPath      = $Fixture.ResultsPath
        ReadyPath        = Join-Path $Fixture.Container "$RunId.ready"
        ReleasePath      = Join-Path $Fixture.Container "$RunId.release"
        StdOutPath       = Join-Path $Fixture.Container "$RunId.stdout.txt"
        StdErrPath       = Join-Path $Fixture.Container "$RunId.stderr.txt"
    }
}

function script:Start-AutoresearchLoopWorker {
    param(
        [Parameter(Mandatory)][psobject]$Paths,
        [ValidateSet('RunLoop', 'Abandon')][string]$Mode = 'RunLoop'
    )

    $workerPath = Join-Path $PSScriptRoot 'fixtures\autoresearch-loop-worker.ps1'
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $workerPath),
        '-Mode', $Mode,
        '-LaunchScriptPath', ('"{0}"' -f $Paths.LaunchScriptPath),
        '-RepoRootPath', ('"{0}"' -f $Paths.RepoRootPath),
        '-LogDirPath', ('"{0}"' -f $Paths.LogDirPath),
        '-RunId', $Paths.RunId,
        '-AiCallsPath', ('"{0}"' -f $Paths.AiCallsPath),
        '-GitMutationsPath', ('"{0}"' -f $Paths.GitMutationsPath),
        '-ResultsPath', ('"{0}"' -f $Paths.ResultsPath),
        '-ReadyPath', ('"{0}"' -f $Paths.ReadyPath),
        '-ReleasePath', ('"{0}"' -f $Paths.ReleasePath)
    )

    return Start-Process -FilePath (Get-PwshExePath) -ArgumentList $arguments `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $Paths.StdOutPath -RedirectStandardError $Paths.StdErrPath
}

function script:Wait-AutoresearchLoopWorkerReady {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][psobject]$Paths,
        [int]$TimeoutSeconds = 30
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $Paths.ReadyPath -PathType Leaf) { return }
        if ($Process.HasExited) {
            $stdout = if (Test-Path -LiteralPath $Paths.StdOutPath) { Get-Content -LiteralPath $Paths.StdOutPath -Raw } else { '' }
            $stderr = if (Test-Path -LiteralPath $Paths.StdErrPath) { Get-Content -LiteralPath $Paths.StdErrPath -Raw } else { '' }
            throw "Loop worker $($Paths.RunId) exited before reaching its barrier (exit $($Process.ExitCode)). stdout: $stdout stderr: $stderr"
        }
        Start-Sleep -Milliseconds 50
    }
    throw "Loop worker $($Paths.RunId) did not reach its barrier within $TimeoutSeconds seconds."
}

function script:Wait-AutoresearchLoopWorkerExit {
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory)][psobject]$Paths,
        [int]$TimeoutMilliseconds = 30000
    )

    if (-not $Process.WaitForExit($TimeoutMilliseconds)) {
        throw "Loop worker $($Paths.RunId) did not exit within $TimeoutMilliseconds milliseconds."
    }
    return $Process.ExitCode
}

function script:New-AiPoweredEditMockFixture {
    param([Parameter(Mandatory)][string]$Name)

    $root = New-TestRoot $Name
    $repoRoot = Join-Path $root 'repo'
    $bin = Join-Path $root 'mock cli bin'
    $tempRoot = Join-Path $root 'prompt temp'
    foreach ($path in @($repoRoot, $bin, $tempRoot)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $mockCliPath = Join-Path $bin 'mock-ai-powered.js'
    $mockCli = @'
const fs = require("fs");
const chunks = [];

function quoteWindowsArgument(value) {
  let result = '"';
  let backslashes = 0;
  for (const character of value) {
    if (character === "\\") {
      backslashes += 1;
    } else if (character === '"') {
      result += "\\".repeat(backslashes * 2 + 1) + '"';
      backslashes = 0;
    } else {
      result += "\\".repeat(backslashes) + character;
      backslashes = 0;
    }
  }
  return result + "\\".repeat(backslashes * 2) + '"';
}

process.stdin.on("data", chunk => chunks.push(chunk));
process.stdin.on("end", () => {
  const rawPrompt = Buffer.concat(chunks).toString("utf8");
  const args = process.argv.slice(2);
  const commandLine = process.argv.map(quoteWindowsArgument).join(" ");
  const argvLength = args.reduce((total, value) => total + value.length, 0) +
    Math.max(0, args.length - 1);
  const mode = process.env.AUTORESEARCH_AI_EDIT_MOCK_MODE || "success";
  const providerKeys = {
    OPENAI_API_KEY: process.env.OPENAI_API_KEY || null,
    ANTHROPIC_API_KEY: process.env.ANTHROPIC_API_KEY || null,
    AZURE_OPENAI_API_KEY: process.env.AZURE_OPENAI_API_KEY || null
  };
  const capture = {
    prompt: rawPrompt.trim(),
    rawPromptLength: rawPrompt.length,
    args,
    argvLength,
    commandLineLength: commandLine.length,
    mode,
    providerKeys,
    provider: process.env.AI_PROVIDER || null,
    model: process.env.AI_POWERED_MODEL || process.env.AI_MODEL || null,
    ollamaHost: process.env.OLLAMA_HOST || null,
    azureEndpoint: process.env.AZURE_OPENAI_ENDPOINT || null,
    azureDeployment: process.env.AZURE_OPENAI_DEPLOYMENT || null
  };
  fs.writeFileSync(process.env.AUTORESEARCH_AI_EDIT_MOCK_CAPTURE, JSON.stringify(capture));

  if (mode === "failure") {
    process.stderr.write("mock CLI failure\n");
    process.exitCode = 23;
    return;
  }
  if (mode === "empty") return;

  const fence = String.fromCharCode(96).repeat(3);
  const responsePath = process.env.AUTORESEARCH_AI_EDIT_MOCK_RESPONSE_FILE;
  const trainSource = responsePath ? fs.readFileSync(responsePath, "utf8") : "print('mock edit')";
  process.stdout.write(
    "DESCRIPTION: mock experiment\n" +
    fence + "python\n" + trainSource + "\n" +
    fence + "\n"
  );
});
'@
    [System.IO.File]::WriteAllText($mockCliPath, $mockCli, $utf8)

    $shimPath = Join-Path $bin 'ai-powered.ps1'
    $shim = @'
if ($MyInvocation.ExpectingInput) {
    $input | & node.exe $env:AUTORESEARCH_AI_EDIT_MOCK_SCRIPT @args
} else {
    & node.exe $env:AUTORESEARCH_AI_EDIT_MOCK_SCRIPT @args
}
'@
    [System.IO.File]::WriteAllText($shimPath, $shim, $utf8)

    return [pscustomobject]@{
        Root        = $root
        RepoRoot    = $repoRoot
        Bin         = $bin
        TempRoot    = $tempRoot
        MockCliPath = $mockCliPath
        CapturePath = Join-Path $root 'mock-capture.json'
        ResponsePath = Join-Path $root 'mock-response.py'
    }
}

function script:Get-AiPoweredEditExpectedPrompt {
    param([Parameter(Mandatory)][psobject]$Fixture)

    $program = [System.IO.File]::ReadAllText((Join-Path $Fixture.RepoRoot 'program.md'), [System.Text.Encoding]::UTF8)
    $train = [System.IO.File]::ReadAllText((Join-Path $Fixture.RepoRoot 'train.py'), [System.Text.Encoding]::UTF8)
    $resultsPath = Join-Path $Fixture.RepoRoot 'results.tsv'
    $results = if (Test-Path -LiteralPath $resultsPath) {
        ((Get-Content -LiteralPath $resultsPath -Encoding UTF8) | Select-Object -Last 20) -join ([char]10)
    } else {
        ''
    }
    $openingFence = ([string]::new([char]96, 3) + 'python')
    $fence = [string]::new([char]96, 3)

    return @"
PROGRAM:
$program

RECENT RESULTS (tail of results.tsv):
$results

CURRENT train.py:
$openingFence
$train
$fence

Propose ONE small experimental change to train.py and return the complete new file.
"@
}

function script:Get-AiPoweredEditMockCapture {
    param([Parameter(Mandatory)][psobject]$Fixture)
    if (-not (Test-Path -LiteralPath $Fixture.CapturePath -PathType Leaf)) {
        throw 'The local ai-powered mock did not capture its input.'
    }
    return [System.IO.File]::ReadAllText($Fixture.CapturePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
}

function script:Assert-AiPoweredEditPromptReceived {
    param(
        [Parameter(Mandatory)][psobject]$Capture,
        [Parameter(Mandatory)][string]$ExpectedPrompt
    )

    if ($Capture.prompt -cne $ExpectedPrompt) {
        throw "Mock prompt mismatch: expected $($ExpectedPrompt.Length) characters, received $($Capture.prompt.Length)."
    }
    $Capture.prompt.Length | Should -Be $ExpectedPrompt.Length
    $Capture.argvLength | Should -BeLessThan 32767
    $Capture.commandLineLength | Should -BeLessThan 32767
}

Describe 'Invoke-AiPoweredEdit prompt transport' {
    BeforeEach {
        $script:AiPoweredEditFixture = New-AiPoweredEditMockFixture 'ai-edit-prompt-transport'
        $script:AiPoweredEditSavedEnvironment = @{}
        foreach ($name in @(
            'PATH',
            'TEMP',
            'TMP',
            'AUTORESEARCH_AI_EDIT_MOCK_SCRIPT',
            'AUTORESEARCH_AI_EDIT_MOCK_CAPTURE',
            'AUTORESEARCH_AI_EDIT_MOCK_MODE',
            'AUTORESEARCH_AI_EDIT_MOCK_RESPONSE_FILE',
            'OPENAI_API_KEY',
            'ANTHROPIC_API_KEY',
            'AZURE_OPENAI_API_KEY'
        )) {
            $script:AiPoweredEditSavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }

        $env:PATH = $script:AiPoweredEditFixture.Bin + ';' + $env:PATH
        $env:TEMP = $script:AiPoweredEditFixture.TempRoot
        $env:TMP = $script:AiPoweredEditFixture.TempRoot
        $env:AUTORESEARCH_AI_EDIT_MOCK_SCRIPT = $script:AiPoweredEditFixture.MockCliPath
        $env:AUTORESEARCH_AI_EDIT_MOCK_CAPTURE = $script:AiPoweredEditFixture.CapturePath
        $env:AUTORESEARCH_AI_EDIT_MOCK_MODE = 'success'
        [Environment]::SetEnvironmentVariable('AUTORESEARCH_AI_EDIT_MOCK_RESPONSE_FILE', $null, 'Process')

        $utf8 = New-Object System.Text.UTF8Encoding($false)
        $programText = 'Keep all program instructions. Unicode: ' + [char]0x0394 + '.'
        [System.IO.File]::WriteAllText((Join-Path $script:AiPoweredEditFixture.RepoRoot 'program.md'), $programText, $utf8)
        [System.IO.File]::WriteAllText((Join-Path $script:AiPoweredEditFixture.RepoRoot 'train.py'), "print('baseline')", $utf8)
        $tab = [char]9
        $lineFeed = [char]10
        $results = 'commit' + $tab + 'val_bpb' + $tab + 'memory_gb' + $tab + 'status' + $tab + 'description' + $lineFeed +
            'base' + $tab + '0.200000' + $tab + '1.0' + $tab + 'keep' + $tab + 'baseline' + $lineFeed
        [System.IO.File]::WriteAllText((Join-Path $script:AiPoweredEditFixture.RepoRoot 'results.tsv'), $results, $utf8)
        Mock Write-Json {}
    }

    AfterEach {
        foreach ($name in $script:AiPoweredEditSavedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:AiPoweredEditSavedEnvironment[$name], 'Process')
        }
        if (Test-Path -LiteralPath $script:AiPoweredEditFixture.Root) {
            Remove-Item -LiteralPath $script:AiPoweredEditFixture.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'keeps short input behavior and sends the complete oversized prompt through stdin' {
        $system = 'You are an autonomous ML research agent. Reply with EXACTLY one short one-line description prefixed by "DESCRIPTION: ", then a single fenced code block ' +
            [string]::new([char]96, 3) + 'python containing the COMPLETE new contents of train.py. No other text.'

        $shortExpected = Get-AiPoweredEditExpectedPrompt -Fixture $script:AiPoweredEditFixture
        $shortResult = Invoke-AiPoweredEdit -RepoRootPath $script:AiPoweredEditFixture.RepoRoot
        $shortCapture = Get-AiPoweredEditMockCapture -Fixture $script:AiPoweredEditFixture
        Assert-AiPoweredEditPromptReceived -Capture $shortCapture -ExpectedPrompt $shortExpected
        $shortResult.Description | Should -BeExactly 'mock experiment'
        $shortResult.NewContent | Should -BeExactly "print('mock edit')"
        $shortCapture.args | Should -Contain 'text'
        $shortCapture.args | Should -Contain '--quiet'
        $shortCapture.args | Should -Contain '--system'
        $shortCapture.args | Should -Contain $system
        @(Get-ChildItem -LiteralPath $script:AiPoweredEditFixture.TempRoot -File).Count | Should -Be 0

        $sentinel = 'TRAIN_TAIL_SENTINEL_ISSUE_03'
        $longTrain = [string]::new([char]'x', 90000) + [Environment]::NewLine + $sentinel
        [System.IO.File]::WriteAllText(
            (Join-Path $script:AiPoweredEditFixture.RepoRoot 'train.py'),
            $longTrain,
            (New-Object System.Text.UTF8Encoding($false))
        )
        $fullExpected = Get-AiPoweredEditExpectedPrompt -Fixture $script:AiPoweredEditFixture
        $fullExpected.Length | Should -BeGreaterThan 90000

        $fullResult = Invoke-AiPoweredEdit -RepoRootPath $script:AiPoweredEditFixture.RepoRoot
        $fullCapture = Get-AiPoweredEditMockCapture -Fixture $script:AiPoweredEditFixture
        Assert-AiPoweredEditPromptReceived -Capture $fullCapture -ExpectedPrompt $fullExpected
        $fullCapture.prompt.Substring($fullCapture.prompt.Length - 256) | Should -Match ([regex]::Escape($sentinel))
        ($fullCapture.args -join ' ') | Should -Not -Match ([regex]::Escape($sentinel))
        $fullResult.Description | Should -BeExactly 'mock experiment'
        $fullResult.NewContent | Should -BeExactly "print('mock edit')"
        @(Get-ChildItem -LiteralPath $script:AiPoweredEditFixture.TempRoot -File).Count | Should -Be 0
    }

    It 'cleans the temporary prompt and skips an empty CLI response without changing train.py' {
        $env:AUTORESEARCH_AI_EDIT_MOCK_MODE = 'empty'
        $trainPath = Join-Path $script:AiPoweredEditFixture.RepoRoot 'train.py'
        $before = [System.IO.File]::ReadAllText($trainPath, [System.Text.Encoding]::UTF8)

        $result = Invoke-AiPoweredEdit -RepoRootPath $script:AiPoweredEditFixture.RepoRoot

        $result | Should -BeNullOrEmpty
        [System.IO.File]::ReadAllText($trainPath, [System.Text.Encoding]::UTF8) | Should -BeExactly $before
        (Get-AiPoweredEditMockCapture -Fixture $script:AiPoweredEditFixture).mode | Should -BeExactly 'empty'
        @(Get-ChildItem -LiteralPath $script:AiPoweredEditFixture.TempRoot -File).Count | Should -Be 0
    }

    It 'cleans the temporary prompt and preserves train.py when the CLI exits nonzero' {
        $env:AUTORESEARCH_AI_EDIT_MOCK_MODE = 'failure'
        $trainPath = Join-Path $script:AiPoweredEditFixture.RepoRoot 'train.py'
        $before = [System.IO.File]::ReadAllText($trainPath, [System.Text.Encoding]::UTF8)

        $result = Invoke-AiPoweredEdit -RepoRootPath $script:AiPoweredEditFixture.RepoRoot

        $result | Should -BeNullOrEmpty
        [System.IO.File]::ReadAllText($trainPath, [System.Text.Encoding]::UTF8) | Should -BeExactly $before
        (Get-AiPoweredEditMockCapture -Fixture $script:AiPoweredEditFixture).mode | Should -BeExactly 'failure'
        @(Get-ChildItem -LiteralPath $script:AiPoweredEditFixture.TempRoot -File).Count | Should -Be 0
    }
}

Describe 'Provider credential scope and generated-code review' {
    BeforeEach {
        $script:ProviderScopePreviousState = Get-LaunchFixtureState
        $script:ProviderScopeFixture = New-AiPoweredEditMockFixture 'provider-credential-scope'
        $script:ProviderScopeSavedEnvironment = @{}
        $environmentNames = @(
            'PATH', 'TEMP', 'TMP',
            'AUTORESEARCH_AI_EDIT_MOCK_SCRIPT',
            'AUTORESEARCH_AI_EDIT_MOCK_CAPTURE',
            'AUTORESEARCH_AI_EDIT_MOCK_MODE',
            'AUTORESEARCH_AI_EDIT_MOCK_RESPONSE_FILE',
            'AUTORESEARCH_PROVIDER_PROBE_PATH',
            'OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'AZURE_OPENAI_API_KEY',
            'AI_PROVIDER', 'AI_MODEL', 'AI_POWERED_MODEL', 'OLLAMA_HOST',
            'AZURE_OPENAI_ENDPOINT', 'AZURE_OPENAI_DEPLOYMENT'
        )
        foreach ($name in $environmentNames) {
            $script:ProviderScopeSavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }

        $env:PATH = $script:ProviderScopeFixture.Bin + ';' + $env:PATH
        $env:TEMP = $script:ProviderScopeFixture.TempRoot
        $env:TMP = $script:ProviderScopeFixture.TempRoot
        $env:AUTORESEARCH_AI_EDIT_MOCK_SCRIPT = $script:ProviderScopeFixture.MockCliPath
        $env:AUTORESEARCH_AI_EDIT_MOCK_CAPTURE = $script:ProviderScopeFixture.CapturePath
        $env:AUTORESEARCH_AI_EDIT_MOCK_MODE = 'success'
        $env:AUTORESEARCH_AI_EDIT_MOCK_RESPONSE_FILE = $script:ProviderScopeFixture.ResponsePath
        [System.IO.File]::WriteAllText(
            $script:ProviderScopeFixture.ResponsePath,
            "print('mock edit')",
            (New-Object System.Text.UTF8Encoding($false))
        )
        foreach ($name in @('OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'AZURE_OPENAI_API_KEY')) {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }

        $script:Provider = 'ollama'
        $script:ApiKey = $null
        $script:ProviderApiKeyForAi = $null
        $script:Model = 'issue-06-model'
        $script:OllamaHost = 'http://127.0.0.1:11434'
        $script:AzureEndpoint = $null
        $script:AzureDeployment = $null
        $script:SchedulerPolicy = 'Interactive'
        $script:ProviderScopeLogRecords = @()
        $script:ProviderScopeGitFixture = $null
    }

    AfterEach {
        Set-LaunchFixtureState -State $script:ProviderScopePreviousState
        foreach ($name in $script:ProviderScopeSavedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:ProviderScopeSavedEnvironment[$name], 'Process')
        }
        if (Test-Path -LiteralPath $script:ProviderScopeFixture.Root) {
            Remove-Item -LiteralPath $script:ProviderScopeFixture.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($script:ProviderScopeGitFixture -and (Test-Path -LiteralPath $script:ProviderScopeGitFixture.Container)) {
            Remove-Item -LiteralPath $script:ProviderScopeGitFixture.Container -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'passes only the selected fake provider key to the AI CLI and preserves provider configuration' {
        $sentinel = 'ISSUE06_FAKE_PROVIDER_SENTINEL'
        $cases = @(
            @{ Provider = 'openai'; KeyName = 'OPENAI_API_KEY'; Model = 'issue-06-openai-model' },
            @{ Provider = 'anthropic'; KeyName = 'ANTHROPIC_API_KEY'; Model = 'issue-06-anthropic-model' },
            @{ Provider = 'azure'; KeyName = 'AZURE_OPENAI_API_KEY'; Model = 'issue-06-azure-model' }
        )
        $keyNames = @('OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'AZURE_OPENAI_API_KEY')
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $script:ProviderScopeFixture.RepoRoot 'program.md'), 'local provider mock', $utf8)
        [System.IO.File]::WriteAllText((Join-Path $script:ProviderScopeFixture.RepoRoot 'train.py'), "print('baseline')", $utf8)

        foreach ($case in $cases) {
            foreach ($name in $keyNames) {
                [Environment]::SetEnvironmentVariable($name, $sentinel, 'Process')
            }
            $script:Provider = $case.Provider
            $script:Model = $case.Model
            $script:AzureEndpoint = if ($case.Provider -eq 'azure') { 'https://example.invalid' } else { $null }
            $script:AzureDeployment = if ($case.Provider -eq 'azure') { 'issue-06-deployment' } else { $null }

            Set-WorkloadEnvironment
            @($keyNames | Where-Object { -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($_, 'Process')) }).Count |
                Should -Be 0

            $edit = Invoke-AiPoweredEdit -RepoRootPath $script:ProviderScopeFixture.RepoRoot
            $edit.NewContent | Should -BeExactly "print('mock edit')"
            $capture = Get-AiPoweredEditMockCapture -Fixture $script:ProviderScopeFixture
            $expectedProvider = if ($case.Provider -eq 'ollama') { 'custom' } else { $case.Provider }
            $capture.provider | Should -BeExactly $expectedProvider
            $capture.model | Should -BeExactly $case.Model
            $presentKeys = @($keyNames | Where-Object {
                -not [string]::IsNullOrEmpty([string]$capture.providerKeys.PSObject.Properties[$_].Value)
            })
            $presentKeys.Count | Should -Be 1
            $presentKeys[0] | Should -BeExactly $case.KeyName
            ($capture.providerKeys.PSObject.Properties[$case.KeyName].Value -ceq $sentinel) | Should -BeTrue
            @($keyNames | Where-Object { -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($_, 'Process')) }).Count |
                Should -Be 0
            if ($case.Provider -eq 'azure') {
                $capture.azureEndpoint | Should -BeExactly 'https://example.invalid'
                $capture.azureDeployment | Should -BeExactly 'issue-06-deployment'
            }
        }
    }

    It 'keeps Ollama mock selection credential-free while forwarding model and host settings' {
        $script:Provider = 'ollama'
        $script:Model = 'issue-06-ollama-model'
        $script:OllamaHost = 'http://127.0.0.1:11434'
        Set-WorkloadEnvironment
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $script:ProviderScopeFixture.RepoRoot 'program.md'), 'local Ollama mock', $utf8)
        [System.IO.File]::WriteAllText((Join-Path $script:ProviderScopeFixture.RepoRoot 'train.py'), "print('baseline')", $utf8)

        $edit = Invoke-AiPoweredEdit -RepoRootPath $script:ProviderScopeFixture.RepoRoot
        $edit.NewContent | Should -BeExactly "print('mock edit')"
        $capture = Get-AiPoweredEditMockCapture -Fixture $script:ProviderScopeFixture
        $capture.provider | Should -BeExactly 'custom'
        $capture.model | Should -BeExactly 'issue-06-ollama-model'
        $capture.ollamaHost | Should -BeExactly 'http://127.0.0.1:11434'
        @($capture.providerKeys.PSObject.Properties | Where-Object { -not [string]::IsNullOrEmpty([string]$_.Value) }).Count |
            Should -Be 0
    }

    It 'runs a harmless generated-code probe in a fake uv child with no provider keys' {
        $sentinel = 'ISSUE06_FAKE_PROVIDER_SENTINEL'
        $script:Provider = 'openai'
        $script:Model = 'issue-06-openai-model'
        $script:ApiKey = $null
        $script:SchedulerPolicy = 'Interactive'
        $script:ProviderScopeProbePath = Join-Path $script:ProviderScopeFixture.Root 'probe-output.json'
        $script:ProviderProbePythonPath = (Get-Command python.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $env:AUTORESEARCH_PROVIDER_PROBE_PATH = $script:ProviderScopeProbePath
        foreach ($name in @('OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'AZURE_OPENAI_API_KEY')) {
            [Environment]::SetEnvironmentVariable($name, $sentinel, 'Process')
        }
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures\\provider-credential-probe.py') -Destination $script:ProviderScopeFixture.ResponsePath
        Set-Content -LiteralPath (Join-Path $script:ProviderScopeFixture.RepoRoot 'program.md') -Value 'local provider mock' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:ProviderScopeFixture.RepoRoot 'train.py') -Value "print('baseline')" -Encoding UTF8
        $tab = [char]9
        $newline = [Environment]::NewLine
        $results = 'commit' + $tab + 'val_bpb' + $tab + 'memory_gb' + $tab + 'status' + $tab + 'description' + $newline +
            'base' + $tab + '0.2' + $tab + '1.0' + $tab + 'keep' + $tab + 'baseline' + $newline
        [System.IO.File]::WriteAllText((Join-Path $script:ProviderScopeFixture.RepoRoot 'results.tsv'), $results)

        $savedTemp = $env:TEMP
        $savedTmp = $env:TMP
        try {
            $env:TEMP = $env:USERPROFILE
            $env:TMP = $env:USERPROFILE
            $gitFixture = New-AutoresearchGitFixture -Name 'cred-child'
        } finally {
            $env:TEMP = $savedTemp
            $env:TMP = $savedTmp
        }
        $script:ProviderScopeGitFixture = $gitFixture
        Mock Write-Json {
            $script:ProviderScopeLogRecords += [pscustomobject]@{ Level = $Level; Message = $Message; Extra = $Extra }
        }
        Mock Assert-AutoresearchGeneratedCodeReviewAvailable {}
        Mock Confirm-AutoresearchGeneratedCode { return $true }
        Mock Start-Process {
            param(
                [string]$FilePath,
                [string[]]$ArgumentList,
                [string]$WorkingDirectory,
                [switch]$NoNewWindow,
                [switch]$PassThru,
                [string]$RedirectStandardOutput,
                [string]$RedirectStandardError
            )
            if ($FilePath -cne 'uv' -or (($ArgumentList -join ' ') -cne 'run train.py')) {
                throw 'The iteration requested an unexpected child process.'
            }
            $script:ProviderFakeUvCalls++
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $script:ProviderProbePythonPath
            $startInfo.Arguments = 'train.py'
            $startInfo.WorkingDirectory = $WorkingDirectory
            $startInfo.UseShellExecute = $false
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $child = New-Object System.Diagnostics.Process
            $child.StartInfo = $startInfo
            [void]$child.Start()
            $stdout = $child.StandardOutput.ReadToEnd()
            $stderr = $child.StandardError.ReadToEnd()
            if (-not $child.WaitForExit(30000)) {
                $child.Kill()
                throw 'The harmless generated-code probe timed out.'
            }
            $script:ProviderFakeUvExitCode = $child.ExitCode
            [System.IO.File]::WriteAllText($RedirectStandardOutput, $stdout)
            [System.IO.File]::WriteAllText($RedirectStandardError, $stderr)
            $process = [pscustomobject]@{ Id = $child.Id; ExitCode = $child.ExitCode }
            $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
                param([int]$Milliseconds = -1)
                return $true
            }
            return $process
        }

        Set-WorkloadEnvironment
        $script:ProviderFakeUvCalls = 0
        $result = Invoke-AutoresearchIteration -RepoRootPath $gitFixture.Root -ResultsPath $gitFixture.ResultsPath -PerRunTimeoutMin 1

        $result.Commit | Should -Match '^[0-9a-f]{7}$'
        $script:ProviderFakeUvCalls | Should -Be 1
        $script:ProviderFakeUvExitCode | Should -Be 0
        Test-Path -LiteralPath $script:ProviderScopeProbePath -PathType Leaf | Should -BeTrue
        $probe = Get-Content -LiteralPath $script:ProviderScopeProbePath -Raw | ConvertFrom-Json
        @($probe.provider_key_names_present).Count | Should -Be 0
        $capture = Get-AiPoweredEditMockCapture -Fixture $script:ProviderScopeFixture
        ($capture.providerKeys.OPENAI_API_KEY -ceq $sentinel) | Should -BeTrue
        @(@('OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'AZURE_OPENAI_API_KEY') | Where-Object {
            -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($_, 'Process'))
        }).Count | Should -Be 0

        $logJson = ConvertTo-Json -InputObject @($script:ProviderScopeLogRecords) -Depth 10
        $logJson.Contains($sentinel) | Should -BeFalse
        $taskState = Get-RedactedTaskLaunchState -State @{
            commandLine = ('powershell -File launch.ps1 -ApiKey {0} -SchedulerPolicy Interactive' -f $sentinel)
            provider = 'openai'
        }
        $taskStateJson = ConvertTo-Json -InputObject $taskState -Depth 10
        $taskStateJson.Contains($sentinel) | Should -BeFalse
    }

    It 'fails closed before model execution for IdleOnly and Unattended policies' {
        foreach ($policy in @('IdleOnly', 'Unattended')) {
            $script:SchedulerPolicy = $policy
            $gitFixture = New-AutoresearchGitFixture -Name ("blocked-$policy")
            {
                Invoke-AutoresearchIteration -RepoRootPath $gitFixture.Root -ResultsPath $gitFixture.ResultsPath
            } | Should -Throw '*AI-generated train.py is blocked for scheduler policy*'
            $experimentBranches = Get-AutoresearchFixtureGit -Root $gitFixture.Root `
                -GitArgs @('for-each-ref','--format=%(refname:short)','refs/heads/autoresearch/experiment*')
            $experimentBranches | Should -BeNullOrEmpty
            Test-Path -LiteralPath (Join-Path $gitFixture.Root 'worktrees') | Should -BeFalse
        }
    }

    It 'requires the exact review token before generated code may run' {
        $script:SchedulerPolicy = 'Interactive'
        Mock Assert-AutoresearchGeneratedCodeReviewAvailable {}
        Mock Read-Host { return 'RUN REVIEWED TRAIN.PY' }
        (Confirm-AutoresearchGeneratedCode -TrainPath 'C:\temp\train.py') | Should -BeTrue

        Mock Read-Host { return 'no' }
        (Confirm-AutoresearchGeneratedCode -TrainPath 'C:\temp\train.py') | Should -BeFalse
    }
}

Describe 'Autoresearch experiment worktree transaction' {
    BeforeEach {
        $script:IterationSavedProviderEnvironment = @{}
        foreach ($name in @('OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'AZURE_OPENAI_API_KEY')) {
            $script:IterationSavedProviderEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
        $script:FakeTrainingScore = 0.30
        $script:FakeTrainContent = "print('experiment')"
        $script:FakeEditRoots = @()
        $script:FakeTrainingRoots = @()
        $script:AutoresearchGitFault = $null
        $script:AutoresearchGitFaultOutput = 'mock failure detail api_key=TEST_ONLY_SECRET'
        $script:AutoresearchGitCalls = @()
        $script:AutoresearchLogRecords = @()

        Mock Write-Json {
            $script:AutoresearchLogRecords += [pscustomobject]@{
                Level   = $Level
                Message = $Message
                Extra   = $Extra
            }
        }

        Mock Invoke-Git {
            $script:AutoresearchGitCalls += [pscustomobject]@{
                GitArgs = @($GitArgs)
                Cwd     = $Cwd
            }
            $subcommand = if ($GitArgs -contains 'commit') {
                'commit'
            } elseif ($GitArgs.Count -gt 0 -and $GitArgs[0] -ceq 'add') {
                'add'
            } else {
                $null
            }
            $faultMatches = ($null -ne $script:AutoresearchGitFault) -and `
                (($script:AutoresearchGitFault -ceq $subcommand) -or `
                ($script:AutoresearchGitFault -ceq 'no-head-advance' -and $subcommand -ceq 'commit')
                )
            if ($faultMatches) {
                $faultExitCode = if ($subcommand -ceq 'add') { 17 } else { 23 }
                if ($script:AutoresearchGitFault -ceq 'no-head-advance') { $faultExitCode = 0 }
                return [pscustomobject]@{
                    ExitCode = $faultExitCode
                    Output   = $script:AutoresearchGitFaultOutput
                }
            }
            $output = & git -C $Cwd @GitArgs 2>&1 | Out-String
            return [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Output   = $output.TrimEnd([char[]]@("`r","`n"))
            }
        }

        Mock Invoke-AiPoweredEdit {
            $script:FakeEditRoots += $RepoRootPath
            return @{ NewContent = $script:FakeTrainContent; Description = 'fixture experiment' }
        }

        Mock Assert-AutoresearchGeneratedCodeReviewAvailable {}
        Mock Confirm-AutoresearchGeneratedCode { return $true }

        Mock Start-Process {
            param(
                [string]$FilePath,
                [string[]]$ArgumentList,
                [string]$WorkingDirectory,
                [switch]$NoNewWindow,
                [switch]$PassThru,
                [string]$RedirectStandardOutput,
                [string]$RedirectStandardError
            )
            $script:FakeTrainingRoots += $WorkingDirectory
            [System.IO.File]::WriteAllText(
                $RedirectStandardOutput,
                "val_bpb: $script:FakeTrainingScore`npeak_vram_mb: 1024`n"
            )
            $process = [pscustomobject]@{ Id = 9001; ExitCode = 0 }
            $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
                param([int]$Milliseconds = -1)
                return $true
            }
            return $process
        }
    }

    AfterEach {
        foreach ($name in $script:IterationSavedProviderEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:IterationSavedProviderEnvironment[$name], 'Process')
        }
    }

    It 'keeps an improved candidate without changing staged, unstaged, untracked, ignored, or source index data' {
        $fixture = New-AutoresearchGitFixture -Name 'dirty-keep' -Dirty
        $result = Invoke-AutoresearchIteration -RepoRootPath $fixture.Root `
            -ResultsPath $fixture.ResultsPath -PerRunTimeoutMin 1

        $result.Status | Should -BeExactly 'keep'
        $result.ExperimentBranch | Should -Match '^autoresearch/experiment-'
        (Get-AutoresearchFixtureGit -Root $fixture.Root -GitArgs @('rev-parse',("$($result.ExperimentBranch)^"))) |
            Should -BeExactly $fixture.OriginalHead
        (Get-AutoresearchFixtureGit -Root $fixture.Root -GitArgs @('diff-tree','--no-commit-id','--name-only','-r',$result.ExperimentBranch)) |
            Should -BeExactly 'train.py'
        Test-Path -LiteralPath $result.WorktreePath | Should -BeFalse
        $script:FakeEditRoots[0] | Should -Match ([regex]::Escape((Join-Path $fixture.Root 'worktrees\iteration-')))
        $script:FakeTrainingRoots[0] | Should -BeExactly $script:FakeEditRoots[0]
        Assert-AutoresearchGitFixtureUnchanged -Fixture $fixture
    }

    It 'discards a non-improving candidate only on its experiment branch and preserves all source sentinels' {
        $fixture = New-AutoresearchGitFixture -Name 'dirty-discard' -Dirty
        Set-Content -LiteralPath $fixture.ResultsPath -Value "commit`tval_bpb`tmemory_gb`tstatus`tdescription`nbase`t0.200000`t1.0`tkeep`tbaseline" -Encoding ASCII
        $result = Invoke-AutoresearchIteration -RepoRootPath $fixture.Root `
            -ResultsPath $fixture.ResultsPath -PerRunTimeoutMin 1

        $result.Status | Should -BeExactly 'discard'
        $result.ExperimentBranch | Should -Match '^autoresearch/experiment-'
        (Get-AutoresearchFixtureGit -Root $fixture.Root -GitArgs @('rev-parse',$result.ExperimentBranch)) |
            Should -BeExactly $fixture.OriginalHead
        Test-Path -LiteralPath $result.WorktreePath | Should -BeFalse
        $script:FakeEditRoots[0] | Should -Match ([regex]::Escape((Join-Path $fixture.Root 'worktrees\iteration-')))
        $script:FakeTrainingRoots[0] | Should -BeExactly $script:FakeEditRoots[0]
        Assert-AutoresearchGitFixtureUnchanged -Fixture $fixture
    }

    It 'keeps a clean-checkout improvement as a train.py-only commit on the available experiment branch' {
        $fixture = New-AutoresearchGitFixture -Name 'clean-keep'
        $sourceTrainHash = Get-AutoresearchFixtureHash -Path (Join-Path $fixture.Root 'train.py')
        $result = Invoke-AutoresearchIteration -RepoRootPath $fixture.Root `
            -ResultsPath $fixture.ResultsPath -PerRunTimeoutMin 1

        $result.Status | Should -BeExactly 'keep'
        $result.Commit | Should -Match '^[0-9a-f]{7}$'
        $fullCommit = Get-AutoresearchFixtureGit -Root $fixture.Root -GitArgs @('rev-parse',$result.ExperimentBranch)
        $result.Commit | Should -BeExactly $fullCommit.Substring(0, 7)
        (Get-AutoresearchFixtureGit -Root $fixture.Root -GitArgs @('rev-parse',('{0}^' -f $result.ExperimentBranch))) |
            Should -BeExactly $fixture.OriginalHead
        (Get-AutoresearchFixtureGit -Root $fixture.Root -GitArgs @('diff-tree','--no-commit-id','--name-only','-r',$result.ExperimentBranch)) |
            Should -BeExactly 'train.py'
        (Get-AutoresearchFixtureGit -Root $fixture.Root -GitArgs @('show',('{0}:train.py' -f $result.ExperimentBranch))) |
            Should -BeExactly $script:FakeTrainContent
        $startingLogs = @($script:AutoresearchLogRecords | Where-Object { $_.Message -ceq 'Iteration: starting uv run train.py' })
        $startingLogs.Count | Should -Be 1
        $startingLogs[0].Extra.commit | Should -BeExactly $result.Commit
        $resultRow = [System.IO.File]::ReadAllText($fixture.ResultsPath, [System.Text.Encoding]::UTF8).TrimEnd([char[]]@("`r","`n"))
        ($resultRow -split "`t")[0] | Should -BeExactly $result.Commit
        (Get-AutoresearchFixtureHash -Path (Join-Path $fixture.Root 'train.py')) | Should -BeExactly $sourceTrainHash
        Test-Path -LiteralPath $result.WorktreePath | Should -BeFalse
        @($script:AutoresearchGitCalls | Where-Object { $_.GitArgs.Count -gt 0 -and $_.GitArgs[0] -ceq 'add' }).Count |
            Should -Be 1
        @($script:AutoresearchGitCalls | Where-Object { $_.GitArgs -contains 'commit' }).Count | Should -Be 1
        Assert-AutoresearchGitFixtureUnchanged -Fixture $fixture
    }

    It 'stops before training and retains the edited worktree when git add fails' {
        $fixture = New-AutoresearchGitFixture -Name 'git-add-failure'
        $sourceTrainHash = Get-AutoresearchFixtureHash -Path (Join-Path $fixture.Root 'train.py')
        $script:AutoresearchGitFault = 'add'

        $failureMessage = $null
        try {
            Invoke-AutoresearchIteration -RepoRootPath $fixture.Root `
                -ResultsPath $fixture.ResultsPath -PerRunTimeoutMin 1 | Out-Null
        } catch {
            $failureMessage = $_.Exception.Message
        }

        $failureMessage | Should -Match 'git add -- train.py'
        $failureMessage | Should -Match 'exit code 17'
        $failureMessage | Should -Match 'retained for review'
        $failureMessage | Should -Not -Match 'TEST_ONLY_SECRET'
        $script:FakeTrainingRoots.Count | Should -Be 0
        Test-Path -LiteralPath $fixture.ResultsPath | Should -BeFalse
        @($script:AutoresearchGitCalls | Where-Object { $_.GitArgs -contains 'commit' }).Count | Should -Be 0
        @($script:AutoresearchLogRecords | Where-Object { $_.Message -match 'TEST_ONLY_SECRET' }).Count | Should -Be 0

        $retainedWorktrees = @(Get-ChildItem -LiteralPath (Join-Path $fixture.Root 'worktrees') -Directory -Filter 'iteration-*')
        $retainedWorktrees.Count | Should -Be 1
        $retainedTrain = [System.IO.File]::ReadAllBytes((Join-Path $retainedWorktrees[0].FullName 'train.py'))
        $expectedTrain = Get-AutoresearchIterationTrainBytes -Fixture $fixture -Content $script:FakeTrainContent
        [Convert]::ToBase64String($retainedTrain) | Should -BeExactly ([Convert]::ToBase64String($expectedTrain))
        (Get-AutoresearchFixtureGit -Root $retainedWorktrees[0].FullName -GitArgs @('rev-parse','HEAD')) |
            Should -BeExactly $fixture.OriginalHead
        (Get-AutoresearchFixtureHash -Path (Join-Path $fixture.Root 'train.py')) | Should -BeExactly $sourceTrainHash
        Assert-AutoresearchGitFixtureUnchanged -Fixture $fixture
    }

    It 'stops before training and retains the edited worktree when git commit fails' {
        $fixture = New-AutoresearchGitFixture -Name 'git-commit-failure'
        $sourceTrainHash = Get-AutoresearchFixtureHash -Path (Join-Path $fixture.Root 'train.py')
        $script:AutoresearchGitFault = 'commit'

        $failureMessage = $null
        try {
            Invoke-AutoresearchIteration -RepoRootPath $fixture.Root `
                -ResultsPath $fixture.ResultsPath -PerRunTimeoutMin 1 | Out-Null
        } catch {
            $failureMessage = $_.Exception.Message
        }

        $failureMessage | Should -Match 'git commit --allow-empty -m <description>'
        $failureMessage | Should -Match 'exit code 23'
        $failureMessage | Should -Match 'retained for review'
        $failureMessage | Should -Not -Match 'TEST_ONLY_SECRET'
        $script:FakeTrainingRoots.Count | Should -Be 0
        Test-Path -LiteralPath $fixture.ResultsPath | Should -BeFalse
        @($script:AutoresearchGitCalls | Where-Object { $_.GitArgs.Count -gt 0 -and $_.GitArgs[0] -ceq 'add' }).Count |
            Should -Be 1
        @($script:AutoresearchGitCalls | Where-Object { $_.GitArgs -contains 'commit' }).Count | Should -Be 1

        $retainedWorktrees = @(Get-ChildItem -LiteralPath (Join-Path $fixture.Root 'worktrees') -Directory -Filter 'iteration-*')
        $retainedWorktrees.Count | Should -Be 1
        (Get-AutoresearchFixtureGit -Root $retainedWorktrees[0].FullName -GitArgs @('diff','--cached','--name-only')) |
            Should -BeExactly 'train.py'
        $retainedTrain = [System.IO.File]::ReadAllBytes((Join-Path $retainedWorktrees[0].FullName 'train.py'))
        $expectedTrain = Get-AutoresearchIterationTrainBytes -Fixture $fixture -Content $script:FakeTrainContent
        [Convert]::ToBase64String($retainedTrain) | Should -BeExactly ([Convert]::ToBase64String($expectedTrain))
        $experimentBranch = Get-AutoresearchFixtureGit -Root $fixture.Root `
            -GitArgs @('for-each-ref','--format=%(refname:short)','refs/heads/autoresearch')
        $experimentBranch | Should -Match '^autoresearch/experiment-'
        (Get-AutoresearchFixtureGit -Root $fixture.Root -GitArgs @('rev-parse',$experimentBranch)) |
            Should -BeExactly $fixture.OriginalHead
        (Get-AutoresearchFixtureHash -Path (Join-Path $fixture.Root 'train.py')) | Should -BeExactly $sourceTrainHash
        Assert-AutoresearchGitFixtureUnchanged -Fixture $fixture
    }

    It 'rejects a successful git commit that leaves HEAD unchanged and keeps the edit for review' {
        $fixture = New-AutoresearchGitFixture -Name 'git-commit-no-head-advance'
        $sourceTrainHash = Get-AutoresearchFixtureHash -Path (Join-Path $fixture.Root 'train.py')
        $script:AutoresearchGitFault = 'no-head-advance'

        $failureMessage = $null
        try {
            Invoke-AutoresearchIteration -RepoRootPath $fixture.Root `
                -ResultsPath $fixture.ResultsPath -PerRunTimeoutMin 1 | Out-Null
        } catch {
            $failureMessage = $_.Exception.Message
        }

        $failureMessage | Should -Match 'succeeded without advancing HEAD'
        $failureMessage | Should -Match 'retained for review'
        $failureMessage | Should -Not -Match 'TEST_ONLY_SECRET'
        $script:FakeTrainingRoots.Count | Should -Be 0
        Test-Path -LiteralPath $fixture.ResultsPath | Should -BeFalse
        $commitCalls = @($script:AutoresearchGitCalls | Where-Object { $_.GitArgs -contains 'commit' })
        $commitCalls.Count | Should -Be 1

        $retainedWorktrees = @(Get-ChildItem -LiteralPath (Join-Path $fixture.Root 'worktrees') -Directory -Filter 'iteration-*')
        $retainedWorktrees.Count | Should -Be 1
        $retainedTrain = [System.IO.File]::ReadAllBytes((Join-Path $retainedWorktrees[0].FullName 'train.py'))
        $expectedTrain = Get-AutoresearchIterationTrainBytes -Fixture $fixture -Content $script:FakeTrainContent
        [Convert]::ToBase64String($retainedTrain) | Should -BeExactly ([Convert]::ToBase64String($expectedTrain))
        $experimentBranch = Get-AutoresearchFixtureGit -Root $fixture.Root `
            -GitArgs @('for-each-ref','--format=%(refname:short)','refs/heads/autoresearch')
        $experimentBranch | Should -Match '^autoresearch/experiment-'
        (Get-AutoresearchFixtureGit -Root $fixture.Root -GitArgs @('rev-parse',$experimentBranch)) |
            Should -BeExactly $fixture.OriginalHead
        (Get-AutoresearchFixtureHash -Path (Join-Path $fixture.Root 'train.py')) | Should -BeExactly $sourceTrainHash
        Assert-AutoresearchGitFixtureUnchanged -Fixture $fixture
    }

    It 'returns a nonzero loop result and stops retrying after a retained Git verification failure' {
        $fixture = New-AutoresearchGitFixture -Name 'git-loop-failure'
        $resultsPath = Join-Path $fixture.Root 'results.tsv'
        $baselineRow = "commit`tval_bpb`tmemory_gb`tstatus`tdescription`n$($fixture.OriginalHead.Substring(0, 7))`t0.200000`t1.0`tkeep`tbaseline"
        Set-Content -LiteralPath $resultsPath -Value $baselineRow -Encoding ASCII
        $fixture.OriginalStatus = Get-AutoresearchFixtureGit -Root $fixture.Root `
            -GitArgs @('status','--porcelain=1','--untracked-files=all')
        $resultsHash = Get-AutoresearchFixtureHash -Path $resultsPath

        $previousValues = @{}
        foreach ($name in @('RepoRoot','LogDir','MaxLoopMinutes','PerRunTimeoutMinutes','NoAiEdit','SchedulerPolicy','RunLogPath')) {
            $previousVariable = Get-Variable -Scope Script -Name $name -ErrorAction SilentlyContinue
            $previousValues[$name] = [pscustomobject]@{
                Exists = ($null -ne $previousVariable)
                Value  = if ($null -ne $previousVariable) { $previousVariable.Value } else { $null }
            }
        }
        $script:LoopFixture = $fixture
        $script:RepoRoot = $fixture.Root
        $script:LogDir = $fixture.Container
        $script:MaxLoopMinutes = 1
        $script:PerRunTimeoutMinutes = 1
        $script:NoAiEdit = $false
        $script:SchedulerPolicy = 'Interactive'
        $script:LoopIterationCalls = 0

        Mock Assert-AutoresearchSourceCheckoutClean {}
        Mock Invoke-IdlePolicyGate { return $true }
        Mock Assert-AutoresearchGeneratedCodeReviewAvailable {}
        Mock New-AutoresearchExperimentBranch {
            return [pscustomobject]@{ Name = 'autoresearch/experiment-loop-failure'; BaseCommit = $script:LoopFixture.OriginalHead }
        }
        Mock Set-WorkloadEnvironment {}
        Mock Initialize-ResultsTsv {}
        Mock Limit-RunLogs {}
        Mock Invoke-AutoresearchIteration {
            $script:LoopIterationCalls++
            $failure = [System.InvalidOperationException]::new('Mock Git verification failure.')
            $failure.Data['AutoresearchGitVerificationFailure'] = $true
            throw $failure
        }

        try {
            $loopResult = Invoke-AutoresearchLoop
        } finally {
            foreach ($name in $previousValues.Keys) {
                if ($previousValues[$name].Exists) {
                    Set-Variable -Scope Script -Name $name -Value $previousValues[$name].Value
                } else {
                    Remove-Variable -Scope Script -Name $name -ErrorAction SilentlyContinue
                }
            }
        }

        $loopResult | Should -Be 1
        $script:LoopIterationCalls | Should -Be 1
        (Get-AutoresearchFixtureHash -Path $resultsPath) | Should -BeExactly $resultsHash
        $script:FakeTrainingRoots.Count | Should -Be 0
        Assert-AutoresearchGitFixtureUnchanged -Fixture $fixture
    }

    It 'refuses to start the production loop when the source checkout is dirty' {
        $fixture = New-AutoresearchGitFixture -Name 'dirty-loop' -Dirty
        $previousRepoRoot = $script:RepoRoot
        $script:RepoRoot = $fixture.Root
        try {
            { Invoke-AutoresearchLoop } | Should -Throw '*source checkout is dirty*'
        } finally {
            $script:RepoRoot = $previousRepoRoot
        }
        Assert-AutoresearchGitFixtureUnchanged -Fixture $fixture
    }

    It 'retains a declined model edit for review and never starts uv' {
        $fixture = New-AutoresearchGitFixture -Name 'review-declined'
        $script:FakeTrainContent = "print('review candidate')"
        Mock Confirm-AutoresearchGeneratedCode { return $false }

        $failureMessage = $null
        try {
            Invoke-AutoresearchIteration -RepoRootPath $fixture.Root -ResultsPath $fixture.ResultsPath -PerRunTimeoutMin 1 | Out-Null
        } catch {
            $failureMessage = $_.Exception.Message
        }

        $failureMessage | Should -Match 'not approved; training did not run'
        $failureMessage | Should -Match 'retained for review'
        $script:FakeTrainingRoots.Count | Should -Be 0
        @($script:AutoresearchGitCalls | Where-Object { $_.GitArgs -contains 'commit' }).Count | Should -Be 0
        $retainedWorktrees = @(Get-ChildItem -LiteralPath (Join-Path $fixture.Root 'worktrees') -Directory -Filter 'iteration-*')
        $retainedWorktrees.Count | Should -Be 1
        [System.IO.File]::ReadAllText((Join-Path $retainedWorktrees[0].FullName 'train.py'), [System.Text.Encoding]::UTF8) |
            Should -BeExactly $script:FakeTrainContent
        (Get-AutoresearchFixtureGit -Root $fixture.Root -GitArgs @('rev-parse','HEAD')) | Should -BeExactly $fixture.OriginalHead
        Assert-AutoresearchGitFixtureUnchanged -Fixture $fixture
    }
}

Describe 'Invoke-AutoresearchLoop repository lock' {
    BeforeEach {
        $script:LoopLockPreviousState = Get-LaunchFixtureState
        $script:LoopLockFixtures = @()
        $script:LoopLockWorkers = @()
        $script:LoopLockWorkerRecords = @()
        $script:LoopLockRecoveryRecords = @()
        $script:AutoresearchLoopLock = $null
    }

    AfterEach {
        foreach ($record in $script:LoopLockWorkerRecords) {
            if (-not [string]::IsNullOrWhiteSpace($record.Paths.ReleasePath)) {
                [System.IO.File]::WriteAllText($record.Paths.ReleasePath, 'release')
            }
        }
        foreach ($worker in $script:LoopLockWorkers) {
            if ($null -ne $worker -and -not $worker.HasExited) {
                try {
                    if (-not $worker.WaitForExit(5000)) {
                        Stop-Process -Id $worker.Id -Force -ErrorAction SilentlyContinue
                        [void]$worker.WaitForExit(5000)
                    }
                } catch { }
            }
        }
        foreach ($fixture in $script:LoopLockFixtures) {
            $ownerPath = $null
            if ($fixture -and $fixture.Root -and (Test-Path -LiteralPath $fixture.Root -PathType Container)) {
                try {
                    $identity = Get-AutoresearchLoopLockIdentity -RepoRootPath $fixture.Root
                    $ownerPath = $identity.OwnerPath
                } catch { }
            }
            if ($ownerPath -and (Test-Path -LiteralPath $ownerPath -PathType Leaf)) {
                Remove-Item -LiteralPath $ownerPath -Force -ErrorAction SilentlyContinue
            }
            if ($fixture -and (Test-Path -LiteralPath $fixture.Container -PathType Container)) {
                Remove-Item -LiteralPath $fixture.Container -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Set-LaunchFixtureState -State $script:LoopLockPreviousState
    }

    It 'lets one process own the shared repo, results, and fixed run log while a second exits busy' {
        $fixture = New-AutoresearchLoopProcessFixture -Name 'same-root-race'
        $script:LoopLockFixtures += $fixture.GitFixture
        $ownerPaths = Get-AutoresearchLoopWorkerPaths -Fixture $fixture -RunId 'owner'
        $contenderPaths = Get-AutoresearchLoopWorkerPaths -Fixture $fixture -RunId 'contender'
        $owner = Start-AutoresearchLoopWorker -Paths $ownerPaths
        $script:LoopLockWorkers += $owner
        $script:LoopLockWorkerRecords += [pscustomobject]@{ Paths = $ownerPaths }
        Wait-AutoresearchLoopWorkerReady -Process $owner -Paths $ownerPaths

        $ownerPid = [int]((Get-Content -LiteralPath $ownerPaths.ReadyPath -Raw) -split '\|')[1]
        $logHashBeforeContender = Get-AutoresearchFixtureHash -Path $fixture.RunLogPath
        $contender = Start-AutoresearchLoopWorker -Paths $contenderPaths
        $script:LoopLockWorkers += $contender
        $script:LoopLockWorkerRecords += [pscustomobject]@{ Paths = $contenderPaths }

        (Wait-AutoresearchLoopWorkerExit -Process $contender -Paths $contenderPaths) | Should -Be 2
        $contenderOutput = Get-Content -LiteralPath $contenderPaths.StdOutPath -Raw
        $contenderOutput | Should -Match 'Autoresearch loop busy'
        $contenderOutput | Should -Match "PID $ownerPid"
        (Get-AutoresearchFixtureHash -Path $fixture.RunLogPath) | Should -BeExactly $logHashBeforeContender
        $owner.HasExited | Should -BeFalse

        [System.IO.File]::WriteAllText($ownerPaths.ReleasePath, 'release')
        (Wait-AutoresearchLoopWorkerExit -Process $owner -Paths $ownerPaths) | Should -Be 0

        $aiCalls = [System.IO.File]::ReadAllLines($fixture.AiCallsPath)
        $aiCalls.Count | Should -Be 1
        $aiCalls[0] | Should -Match '^owner\|'
        $gitMutations = [System.IO.File]::ReadAllLines($fixture.GitMutationsPath)
        $gitMutations.Count | Should -Be 1
        $gitMutations[0] | Should -Match '^owner\|branch\|'
        $branchOutput = Get-AutoresearchFixtureGit -Root $fixture.Root `
            -GitArgs @('for-each-ref','--format=%(refname:short)','refs/heads/autoresearch/lock-test-owner')
        @($branchOutput -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count | Should -Be 1

        $resultRows = [System.IO.File]::ReadAllLines($fixture.ResultsPath)
        $resultRows.Count | Should -Be 3
        foreach ($row in $resultRows) { ($row -split "`t").Count | Should -Be 5 }
        ($resultRows[2] -split "`t")[0] | Should -BeExactly 'owner'

        $logRecords = @([System.IO.File]::ReadAllLines($fixture.RunLogPath) | ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop })
        $logRecords.Count | Should -Be 2
        @($logRecords | Select-Object -ExpandProperty ownerId -Unique) | Should -Be @('owner')
        @($logRecords | Select-Object -ExpandProperty ownerPid -Unique) | Should -Be @($ownerPid)
        Test-Path -LiteralPath $contenderPaths.ReadyPath | Should -BeFalse
    }

    It 'allows loop processes for separate repository roots to overlap and complete' {
        $firstFixture = New-AutoresearchLoopProcessFixture -Name 'separate-root-one'
        $secondFixture = New-AutoresearchLoopProcessFixture -Name 'separate-root-two'
        $script:LoopLockFixtures += @($firstFixture.GitFixture, $secondFixture.GitFixture)
        $firstPaths = Get-AutoresearchLoopWorkerPaths -Fixture $firstFixture -RunId 'first'
        $secondPaths = Get-AutoresearchLoopWorkerPaths -Fixture $secondFixture -RunId 'second'
        $first = Start-AutoresearchLoopWorker -Paths $firstPaths
        $script:LoopLockWorkers += $first
        $script:LoopLockWorkerRecords += [pscustomobject]@{ Paths = $firstPaths }
        Wait-AutoresearchLoopWorkerReady -Process $first -Paths $firstPaths
        $second = Start-AutoresearchLoopWorker -Paths $secondPaths
        $script:LoopLockWorkers += $second
        $script:LoopLockWorkerRecords += [pscustomobject]@{ Paths = $secondPaths }
        Wait-AutoresearchLoopWorkerReady -Process $second -Paths $secondPaths

        [System.IO.File]::WriteAllText($firstPaths.ReleasePath, 'release')
        [System.IO.File]::WriteAllText($secondPaths.ReleasePath, 'release')
        (Wait-AutoresearchLoopWorkerExit -Process $first -Paths $firstPaths) | Should -Be 0
        (Wait-AutoresearchLoopWorkerExit -Process $second -Paths $secondPaths) | Should -Be 0

        foreach ($entry in @(
            @{ Fixture = $firstFixture; RunId = 'first' },
            @{ Fixture = $secondFixture; RunId = 'second' }
        )) {
            [System.IO.File]::ReadAllLines($entry.Fixture.AiCallsPath).Count | Should -Be 1
            [System.IO.File]::ReadAllLines($entry.Fixture.GitMutationsPath).Count | Should -Be 1
            $rows = [System.IO.File]::ReadAllLines($entry.Fixture.ResultsPath)
            $rows.Count | Should -Be 3
            ($rows[2] -split "`t")[0] | Should -BeExactly $entry.RunId
            $records = @([System.IO.File]::ReadAllLines($entry.Fixture.RunLogPath) | ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop })
            $records.Count | Should -Be 2
            @($records | Select-Object -ExpandProperty ownerId -Unique) | Should -Be @($entry.RunId)
        }
    }

    It 'releases the mutex in finally when the loop raises an unexpected exception' {
        $fixture = New-AutoresearchGitFixture -Name 'unexpected-loop-error'
        $script:LoopLockFixtures += $fixture
        $script:RepoRoot = $fixture.Root
        Mock Invoke-AutoresearchLoopCore { throw [System.InvalidOperationException]::new('synthetic loop failure') }

        { Invoke-AutoresearchLoop } | Should -Throw '*synthetic loop failure*'
        $lock = Enter-AutoresearchLoopLock -RepoRootPath $fixture.Root
        $lock.Acquired | Should -BeTrue
        Exit-AutoresearchLoopLock -Lock $lock
    }

    It 'recovers a dead owner record and reports its PID after the kernel mutex is available' {
        $fixture = New-AutoresearchLoopProcessFixture -Name 'abandoned-loop-owner'
        $script:LoopLockFixtures += $fixture.GitFixture
        $abandonedPaths = Get-AutoresearchLoopWorkerPaths -Fixture $fixture -RunId 'abandoned'
        $abandonedProcess = Start-AutoresearchLoopWorker -Paths $abandonedPaths -Mode Abandon
        $script:LoopLockWorkers += $abandonedProcess
        $script:LoopLockWorkerRecords += [pscustomobject]@{ Paths = $abandonedPaths }

        (Wait-AutoresearchLoopWorkerExit -Process $abandonedProcess -Paths $abandonedPaths) | Should -Be 86
        $abandonedOutput = Get-Content -LiteralPath $abandonedPaths.StdOutPath -Raw
        $abandonedPidMatch = [regex]::Match($abandonedOutput, 'ABANDONED_PID=(\d+)')
        $abandonedPidMatch.Success | Should -BeTrue
        $abandonedPid = [int]$abandonedPidMatch.Groups[1].Value
        $script:RepoRoot = $fixture.Root
        Mock Invoke-AutoresearchLoopCore { return 0 }
        Mock Write-Json {
            $script:LoopLockRecoveryRecords += [pscustomobject]@{
                Level = $Level
                Message = $Message
                Extra = $Extra
            }
        }

        (Invoke-AutoresearchLoop) | Should -Be 0
        $script:LoopLockRecoveryRecords.Count | Should -Be 1
        $script:LoopLockRecoveryRecords[0].Extra.staleOwnerRecovered | Should -BeTrue
        $script:LoopLockRecoveryRecords[0].Extra.staleOwnerProcessId | Should -Be $abandonedPid
        $script:LoopLockRecoveryRecords[0].Message | Should -Match 'stale autoresearch repository lock owner'
    }

    It 'acquires a RunLoop lock before initializing storage or running preflight' {
        $launchPath = Join-Path $PSScriptRoot '..\scripts\launch.ps1'
        $source = [System.IO.File]::ReadAllText($launchPath, [System.Text.Encoding]::UTF8)
        $mainMatch = [regex]::Match($source, '(?s)try\s*\{\s*if\s*\(\$RunLoop\)\s*\{(?<lockBlock>.*?)\}\s*Initialize-LauncherStorage')
        $mainMatch.Success | Should -BeTrue
        $mainMatch.Groups['lockBlock'].Value | Should -Match 'Enter-AutoresearchLoopLock -RepoRootPath \$RepoRoot'
        $mainMatch.Groups['lockBlock'].Value | Should -Match 'if \(-not \$loopLock\.Acquired\)'

        $mainStart = $mainMatch.Index
        $storagePosition = $source.IndexOf('Initialize-LauncherStorage', $mainStart, [System.StringComparison]::Ordinal)
        $preflightPosition = $source.IndexOf('Invoke-Preflight', $mainStart, [System.StringComparison]::Ordinal)
        $loopPosition = $source.IndexOf('Invoke-AutoresearchLoop', $mainStart, [System.StringComparison]::Ordinal)
        $storagePosition | Should -BeGreaterThan $mainStart
        $preflightPosition | Should -BeGreaterThan $storagePosition
        $loopPosition | Should -BeGreaterThan $preflightPosition
    }
}

Describe 'Test-ScheduleTime' {
    Context 'Hourly frequency' {
        It 'accepts every documented 10-minute offset' {
            foreach ($v in ':00',':10',':20',':30',':40',':50') {
                { Test-ScheduleTime -Frequency Hourly -Value $v } | Should -Not -Throw
            }
        }
        It 'rejects an off-grid minute value and lists the allowed set' {
            { Test-ScheduleTime -Frequency Hourly -Value ':07' } |
                Should -Throw -ExpectedMessage "*Hourly*Expected one of:*:00*"
        }
    }

    Context 'Daily frequency' {
        It 'accepts a 15-minute-aligned time' {
            { Test-ScheduleTime -Frequency Daily -Value '18:00' } | Should -Not -Throw
        }
        It 'rejects a non-aligned time' {
            { Test-ScheduleTime -Frequency Daily -Value '18:05' } | Should -Throw
        }
    }

    Context 'Weekly frequency' {
        It 'accepts a weekday name' {
            { Test-ScheduleTime -Frequency Weekly -Value 'Wednesday' } | Should -Not -Throw
        }
        It 'rejects a non-weekday value' {
            { Test-ScheduleTime -Frequency Weekly -Value 'Funday' } |
                Should -Throw -ExpectedMessage "*Weekly*"
        }
    }
}

Describe 'Get-TaskTrigger' {
    BeforeEach {
        Mock New-ScheduledTaskTrigger { return [pscustomobject]@{
            Once               = [bool]$Once
            Daily              = [bool]$Daily
            Weekly             = [bool]$Weekly
            At                 = $At
            RepetitionInterval = $RepetitionInterval
            DaysOfWeek         = $DaysOfWeek
        } }
    }

    It 'builds an Hourly trigger anchored at the chosen minute offset' {
        $script:ScheduleFrequency = 'Hourly'
        $script:ScheduleTime = ':30'
        $t = Get-TaskTrigger
        $t.Once | Should -BeTrue
        $t.At.Minute | Should -Be 30
        $t.At.Hour | Should -Be 0
        $t.RepetitionInterval | Should -Be ([timespan]::FromHours(1))
    }

    It 'builds a Daily trigger anchored at the chosen time-of-day' {
        $script:ScheduleFrequency = 'Daily'
        $script:ScheduleTime = '18:00'
        $t = Get-TaskTrigger
        $t.Daily | Should -BeTrue
        $t.At.Hour | Should -Be 18
        $t.At.Minute | Should -Be 0
    }

    It 'builds a Weekly trigger using the named day' {
        $script:ScheduleFrequency = 'Weekly'
        $script:ScheduleTime = 'Wednesday'
        $t = Get-TaskTrigger
        $t.Weekly | Should -BeTrue
        $t.DaysOfWeek | Should -Be 'Wednesday'
    }

    It 'propagates Test-ScheduleTime errors for invalid combinations' {
        $script:ScheduleFrequency = 'Hourly'
        $script:ScheduleTime = '18:00'
        { Get-TaskTrigger } | Should -Throw -ExpectedMessage "*not valid for ScheduleFrequency 'Hourly'*"
    }
}

Describe 'Scheduler policy' {
    It 'describes the interactive policy as logged-on only' {
        $p = Get-SchedulerPolicyInfo -Policy Interactive
        $p.LogonTypeName | Should -Be 'InteractiveToken'
        $p.RequiresDesktopSession | Should -BeTrue
        $p.UsesIdleGate | Should -BeFalse
        $p.Summary | Should -Match 'logged on'
    }

    It 'describes the idle-only policy with a 5 minute idle window' {
        $p = Get-SchedulerPolicyInfo -Policy IdleOnly
        $p.LogonTypeName | Should -Be 'InteractiveToken'
        $p.RequiresDesktopSession | Should -BeTrue
        $p.UsesIdleGate | Should -BeTrue
        $p.IdleDuration | Should -Be 'PT5M'
        $p.IdleWaitTimeout | Should -Be 'PT1H'
        $p.Summary | Should -Match 'skip'
    }

    It 'describes the unattended policy as S4U based' {
        $p = Get-SchedulerPolicyInfo -Policy Unattended
        $p.LogonTypeName | Should -Be 'S4U'
        $p.RequiresDesktopSession | Should -BeFalse
        $p.UsesIdleGate | Should -BeFalse
        $p.Summary | Should -Match 'without an active desktop session'
    }
}

Describe 'Get-TaskXml' {
    BeforeEach {
        $script:Provider = 'openai'
        $script:Model = 'gpt-4o'
        $script:OllamaHost = 'http://127.0.0.1:11434'
        $script:MaxLoopMinutes = 0
        $script:PerRunTimeoutMinutes = 10
        $script:NoAiEdit = $false
    }

    It 'emits idle-only XML with interactive logon and a 5 minute idle window' {
        $script:SchedulerPolicy = 'IdleOnly'
        $script:ScheduleFrequency = 'Daily'
        $script:ScheduleTime = '18:00'
        $xml = [xml](Get-TaskXml)
        $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
        ($xml.SelectSingleNode('//t:Principals/t:Principal/t:LogonType', $ns).InnerText) | Should -Be 'InteractiveToken'
        ($xml.SelectSingleNode('//t:Settings/t:RunOnlyIfIdle', $ns).InnerText) | Should -Be 'true'
        ($xml.SelectSingleNode('//t:Settings/t:IdleSettings/t:Duration', $ns).InnerText) | Should -Be 'PT5M'
        ($xml.SelectSingleNode('//t:Settings/t:IdleSettings/t:WaitTimeout', $ns).InnerText) | Should -Be 'PT1H'
        ($xml.SelectSingleNode('//t:RegistrationInfo/t:Description', $ns).InnerText) | Should -Match 'Idle-only'
        $arguments = $xml.SelectSingleNode('//t:Actions/t:Exec/t:Arguments', $ns).InnerText
        $arguments | Should -Match '-NoGui'
        $arguments | Should -Match '-TaskSupervisor'
        $arguments | Should -Match '-SchedulerPolicy'
        $arguments | Should -Match 'IdleOnly'
        $arguments | Should -Not -Match '-EncodedCommand'
        $arguments | Should -Not -Match '-RunLoop'
    }

    It 'emits interactive XML with zero idle window' {
        $script:SchedulerPolicy = 'Interactive'
        $script:ScheduleFrequency = 'Hourly'
        $script:ScheduleTime = ':30'
        $xml = [xml](Get-TaskXml)
        $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
        ($xml.SelectSingleNode('//t:Principals/t:Principal/t:LogonType', $ns).InnerText) | Should -Be 'InteractiveToken'
        ($xml.SelectSingleNode('//t:Settings/t:RunOnlyIfIdle', $ns).InnerText) | Should -Be 'false'
        ($xml.SelectSingleNode('//t:Settings/t:IdleSettings/t:Duration', $ns).InnerText) | Should -Be 'PT0M'
        ($xml.SelectSingleNode('//t:Settings/t:IdleSettings/t:WaitTimeout', $ns).InnerText) | Should -Be 'PT0M'
        ($xml.SelectSingleNode('//t:RegistrationInfo/t:Description', $ns).InnerText) | Should -Match 'Interactive'
    }

    It 'emits unattended XML with S4U logon and zero idle window' {
        $script:SchedulerPolicy = 'Unattended'
        $script:ScheduleFrequency = 'Weekly'
        $script:ScheduleTime = 'Wednesday'
        $xml = [xml](Get-TaskXml)
        $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
        ($xml.SelectSingleNode('//t:Principals/t:Principal/t:LogonType', $ns).InnerText) | Should -Be 'S4U'
        ($xml.SelectSingleNode('//t:Settings/t:RunOnlyIfIdle', $ns).InnerText) | Should -Be 'false'
        ($xml.SelectSingleNode('//t:Settings/t:IdleSettings/t:Duration', $ns).InnerText) | Should -Be 'PT0M'
        ($xml.SelectSingleNode('//t:Settings/t:IdleSettings/t:WaitTimeout', $ns).InnerText) | Should -Be 'PT0M'
        ($xml.SelectSingleNode('//t:RegistrationInfo/t:Description', $ns).InnerText) | Should -Match 'Unattended'
    }
}

Describe 'Invoke-IdlePolicyGate' {
    BeforeEach {
        $script:captured = @()
        Mock Write-Json {
            param([string]$Level, [string]$Message, [hashtable]$Extra)
            $script:captured += [pscustomobject]@{ Level = $Level; Message = $Message; Extra = $Extra }
        }
    }

    It 'logs an explicit skip reason when the idle window is never reached' {
        Mock Get-ComputerIdleState {
            return [pscustomobject]@{
                Available   = $true
                IdleMs      = 0
                IdleMinutes = 0
                Reason      = $null
            }
        }
        $result = Invoke-IdlePolicyGate -Policy IdleOnly -IdleMinutes 5 -WaitTimeoutMinutes 0 -PollIntervalSeconds 0
        $result | Should -BeFalse
        @($script:captured | Where-Object { $_.Message -match 'Idle-only policy skipped' }).Count | Should -Be 1
    }

    It 'passes through for non-idle-only policies without probing idle state' {
        $result = Invoke-IdlePolicyGate -Policy Interactive -IdleMinutes 5 -WaitTimeoutMinutes 0 -PollIntervalSeconds 0
        $result | Should -BeTrue
    }
}

Describe 'Register-LauncherTask' {
    BeforeEach {
        $script:registerCount = 0
        $script:unregisterCount = 0
        $script:historyCount = 0
        $script:registeredTaskProbes = 0
        Mock Write-Json { }
        Mock Get-TaskXml { return '<Task />' }
        Mock Enable-TaskHistoryLog { $script:historyCount++ }
        Mock Register-ScheduledTask { $script:registerCount++ }
        Mock Unregister-ScheduledTask { $script:unregisterCount++ }
        Mock Get-RegisteredLauncherTask {
            $script:registeredTaskProbes++
            if ($script:registeredTaskProbes -eq 1) { return $null }
            return [pscustomobject]@{
                TaskPath = $script:TaskPath
                TaskName = $script:TaskName
            }
        }
    }

    It 'replaces an existing task instead of duplicating it on repeated registration' {
        $script:SchedulerPolicy = 'IdleOnly'
        $script:ScheduleFrequency = 'Daily'
        $script:ScheduleTime = '18:00'
        Register-LauncherTask
        Register-LauncherTask
        $script:registerCount | Should -Be 2
        $script:unregisterCount | Should -Be 1
        $script:historyCount | Should -Be 2
    }
}

Describe 'Launcher plan' {
    It 'forwards the scheduler policy into the supervisor and worker launch arguments' {
        $script:SchedulerPolicy = 'Unattended'
        $script:ScheduleFrequency = 'Weekly'
        $script:ScheduleTime = 'Wednesday'
        $script:Provider = 'ollama'
        $script:Model = 'qwen2.5-coder:latest'
        $script:MaxLoopMinutes = 0
        $script:PerRunTimeoutMinutes = 10
        Mock Get-PwshExePath { return 'C:\Program Files\PowerShell\7\pwsh.exe' }
        $plan = Get-TaskLauncherPlan
        $plan.InnerArgList | Should -Contain '-SchedulerPolicy'
        $plan.InnerArgList | Should -Contain 'Unattended'
        $plan.InnerArgList | Should -Contain '-RunLoop'
        $plan.TaskActionArguments | Should -Match '-TaskSupervisor'
        $plan.TaskActionArguments | Should -Not -Match '-RunLoop'
        $plan.TaskActionCommand | Should -Match '-TaskSupervisor'
        $plan.TaskActionCommand | Should -Match "^'C:\\Program Files\\PowerShell\\7\\pwsh\.exe'"
        $plan.WorkloadCommand | Should -Match "^'C:\\Program Files\\PowerShell\\7\\pwsh\.exe'"
        $plan.WorkloadCommand | Should -Match '-RunLoop'
        $plan.TaskLaunchStatePath | Should -Match 'autoresearch-task-launch\.json$'
    }
}

Describe 'Launcher ACL hardening' {
    BeforeEach {
        $script:LauncherAclStatus = @{}
    }

    It 'creates log and task-state directories with explicit readable ACLs' {
        if (-not (Test-WindowsHost)) {
            Set-ItResult -Skipped -Because 'The launcher ACL policy is Windows-specific.'
            return
        }

        $root = New-TestRoot 'launcher-acl'
        $script:LogDir = Join-Path $root 'logs'
        $script:AggregateLog = Join-Path $script:LogDir 'autoresearch.jsonl'
        $stateDirectory = Join-Path $root 'task-state'
        $script:TaskLaunchStatePath = Join-Path $stateDirectory 'autoresearch-task-launch.json'

        Initialize-LauncherStorage

        foreach ($directory in @($script:LogDir, $stateDirectory)) {
            $verification = Test-LauncherDirectoryAcl -Path $directory
            $verification.IsHardened | Should -BeTrue
            $verification.InheritanceLocked | Should -BeTrue
            $verification.MissingPrincipals | Should -HaveCount 0
            $verification.UnexpectedRules | Should -HaveCount 0

            $acl = Get-Acl -LiteralPath $directory
            $acl.AreAccessRulesProtected | Should -BeTrue
            foreach ($principal in @(Get-LauncherAclPrincipals)) {
                $readRules = @($acl.Access | Where-Object {
                    (ConvertTo-LauncherSidValue -IdentityReference $_.IdentityReference) -eq $principal.Value -and
                        $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
                        (([int]$_.FileSystemRights -band [int][System.Security.AccessControl.FileSystemRights]::Read) -eq [int][System.Security.AccessControl.FileSystemRights]::Read)
                })
                $readRules.Count | Should -BeGreaterThan 0
            }
        }
    }

    It 'emits a visible warning and preserves fallback behavior when hardening fails' {
        $root = New-TestRoot 'launcher-acl-warning'
        $script:aclWarnings = @()
        Mock Test-WindowsHost { return $false }
        Mock Write-Warning {
            param([string]$Message)
            $script:aclWarnings += $Message
        }

        $result = Set-LauncherDirectoryAcl -Path (Join-Path $root 'logs') -Purpose 'launcher log root'

        $result.IsHardened | Should -BeFalse
        $script:aclWarnings | Should -HaveCount 1
        $script:aclWarnings[0] | Should -Match 'ACL hardening failed'
        $script:aclWarnings[0] | Should -Match 'may be readable by other accounts'
    }
}

Describe 'Run log retention' {
    BeforeEach {
        $script:previousLaunchScope = Get-LaunchFixtureState
        $root = New-TestRoot 'run-log-retention'
        $script:LogDir = Join-Path $root 'logs'
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        $script:AggregateLog = Join-Path $script:LogDir 'autoresearch.jsonl'
        $script:RunLogPath = Join-Path $script:LogDir 'session-summary.jsonl'
    }

    AfterEach {
        Set-LaunchFixtureState -State $script:previousLaunchScope
    }

    It 'keeps the latest failure and most recent success even when older logs exceed the age window' {
        $keptSuccess = Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260907-090000.jsonl' -ExitCode 0 -LastWriteTimeUtc ([datetime]::UtcNow.AddDays(-1))
        $keptFailure = Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260906-090000.jsonl' -ExitCode 1 -LastWriteTimeUtc ([datetime]::UtcNow.AddDays(-20)) -IncludeErrorLine
        $prunedSuccess = Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260905-090000.jsonl' -ExitCode 0 -LastWriteTimeUtc ([datetime]::UtcNow.AddDays(-21))

        $plan = Get-RunLogRetentionPlan -LogDir $script:LogDir -LogRetentionCount 0 -LogRetentionDays 7

        $plan.LatestSuccess.Name | Should -Be (Split-Path -Leaf $keptSuccess)
        $plan.LatestFailure.Name | Should -Be (Split-Path -Leaf $keptFailure)
        @($plan.Kept.Name) | Should -Contain (Split-Path -Leaf $keptSuccess)
        @($plan.Kept.Name) | Should -Contain (Split-Path -Leaf $keptFailure)
        @($plan.Pruned.Name) | Should -Contain (Split-Path -Leaf $prunedSuccess)
    }

    It 'respects the configured count without deleting the most recent useful diagnostic files' {
        $recentSuccess = Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260907-100000.jsonl' -ExitCode 0 -LastWriteTimeUtc ([datetime]::UtcNow.AddDays(-1))
        $recentFailure = Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260906-100000.jsonl' -ExitCode 2 -LastWriteTimeUtc ([datetime]::UtcNow.AddDays(-2)) -IncludeErrorLine
        $oldOne = Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260810-100000.jsonl' -ExitCode 0 -LastWriteTimeUtc ([datetime]::UtcNow.AddDays(-20))
        $oldTwo = Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260809-100000.jsonl' -ExitCode 0 -LastWriteTimeUtc ([datetime]::UtcNow.AddDays(-21))
        $oldThree = Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260808-100000.jsonl' -ExitCode 0 -LastWriteTimeUtc ([datetime]::UtcNow.AddDays(-22))

        $plan = Get-RunLogRetentionPlan -LogDir $script:LogDir -LogRetentionCount 1 -LogRetentionDays 7

        @($plan.Kept.Name) | Should -Contain (Split-Path -Leaf $recentSuccess)
        @($plan.Kept.Name) | Should -Contain (Split-Path -Leaf $recentFailure)
        @($plan.Pruned.Name) | Should -Contain (Split-Path -Leaf $oldTwo)
        @($plan.Pruned.Name) | Should -Contain (Split-Path -Leaf $oldThree)
        @($plan.Kept.Name) | Should -Contain (Split-Path -Leaf $oldOne)
        $plan.Pruned.Count | Should -Be 2
    }

    It 'prunes deterministically when multiple files share the same write time' {
        $stamp = [datetime]::UtcNow.AddDays(-30)
        $keepD = Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260801-120000-d.jsonl' -ExitCode 0 -LastWriteTimeUtc $stamp
        $keepC = Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260801-120000-c.jsonl' -ExitCode 0 -LastWriteTimeUtc $stamp
        $pruneB = Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260801-120000-b.jsonl' -ExitCode 0 -LastWriteTimeUtc $stamp
        $pruneA = Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260801-120000-a.jsonl' -ExitCode 0 -LastWriteTimeUtc $stamp

        $plan = Get-RunLogRetentionPlan -LogDir $script:LogDir -LogRetentionCount 2 -LogRetentionDays 7

        @($plan.Kept.Name) | Should -Contain (Split-Path -Leaf $keepD)
        @($plan.Kept.Name) | Should -Contain (Split-Path -Leaf $keepC)
        @($plan.Pruned.Name) | Should -Contain (Split-Path -Leaf $pruneB)
        @($plan.Pruned.Name) | Should -Contain (Split-Path -Leaf $pruneA)
        $plan.Kept[0].Name | Should -Be (Split-Path -Leaf $keepD)
        $plan.Kept[1].Name | Should -Be (Split-Path -Leaf $keepC)
    }

    It 'appends a pruning summary to the aggregate log after deleting older files' {
        $oldOne = Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260810-080000.jsonl' -ExitCode 0 -LastWriteTimeUtc ([datetime]::UtcNow.AddDays(-20))
        $oldTwo = Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260809-080000.jsonl' -ExitCode 0 -LastWriteTimeUtc ([datetime]::UtcNow.AddDays(-21))
        $oldThree = Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260808-080000.jsonl' -ExitCode 0 -LastWriteTimeUtc ([datetime]::UtcNow.AddDays(-22))
        $recentSuccess = Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260907-080000.jsonl' -ExitCode 0 -LastWriteTimeUtc ([datetime]::UtcNow.AddDays(-1))

        $result = Limit-RunLogs -LogDir $script:LogDir -LogRetentionCount 1 -LogRetentionDays 7

        Test-Path -LiteralPath $oldOne | Should -BeTrue
        Test-Path -LiteralPath $oldTwo | Should -BeFalse
        Test-Path -LiteralPath $oldThree | Should -BeFalse
        Test-Path -LiteralPath $recentSuccess | Should -BeTrue
        Test-Path -LiteralPath $script:AggregateLog | Should -BeTrue
        $summary = ((Get-Content -LiteralPath $script:AggregateLog -Raw) -split "`r?`n" | Where-Object { $_ }) | Select-Object -Last 1 | ConvertFrom-Json
        $summary.msg | Should -Match 'Run log pruning reviewed'
        $summary.pruning.phase | Should -Be 'completed'
        $summary.pruning.plannedDeleteCount | Should -Be 2
        $summary.pruning.deletedCount | Should -Be 2
        @($summary.pruning.deleted) | Should -HaveCount 2
        $result.Summary.deletedCount | Should -Be 2
    }

    It 'captures the pruning plan before deleting older files' {
        Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260810-070000.jsonl' -ExitCode 0 -LastWriteTimeUtc ([datetime]::UtcNow.AddDays(-20)) | Out-Null
        Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260809-070000.jsonl' -ExitCode 0 -LastWriteTimeUtc ([datetime]::UtcNow.AddDays(-21)) | Out-Null
        Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260808-070000.jsonl' -ExitCode 0 -LastWriteTimeUtc ([datetime]::UtcNow.AddDays(-22)) | Out-Null
        Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260907-070000.jsonl' -ExitCode 0 -LastWriteTimeUtc ([datetime]::UtcNow.AddDays(-1)) | Out-Null

        $events = New-Object System.Collections.Generic.List[string]
        Mock Write-Json {
            $events.Add('summary') | Out-Null
        }
        Mock Remove-Item {
            param(
                [string]$LiteralPath,
                [switch]$Force,
                [System.Management.Automation.ActionPreference]$ErrorAction
            )
            $events.Add("delete:$([System.IO.Path]::GetFileName($LiteralPath))") | Out-Null
        }

        $result = Limit-RunLogs -LogDir $script:LogDir -LogRetentionCount 1 -LogRetentionDays 7

        $events[0] | Should -Be 'summary'
        @($events | Where-Object { $_ -like 'delete:*' }) | Should -HaveCount 2
        $events[-1] | Should -Be 'summary'
        $result.Summary.phase | Should -Be 'completed'
        $result.Summary.deletedCount | Should -Be 2
    }

    It 'does not delete older files when the pre-delete summary cannot be written' {
        $oldOne = Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260810-060000.jsonl' -ExitCode 0 -LastWriteTimeUtc ([datetime]::UtcNow.AddDays(-20))
        $oldTwo = Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260809-060000.jsonl' -ExitCode 0 -LastWriteTimeUtc ([datetime]::UtcNow.AddDays(-21))
        Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260808-060000.jsonl' -ExitCode 0 -LastWriteTimeUtc ([datetime]::UtcNow.AddDays(-22)) | Out-Null
        Write-RunLogFixture -Directory $script:LogDir -Name 'autoresearch-run-20260907-060000.jsonl' -ExitCode 0 -LastWriteTimeUtc ([datetime]::UtcNow.AddDays(-1)) | Out-Null

        $deleteAttempts = 0
        Mock Write-Json {
            throw 'simulated aggregate log write failure'
        }
        Mock Remove-Item {
            $deleteAttempts++
        }

        {
            Limit-RunLogs -LogDir $script:LogDir -LogRetentionCount 1 -LogRetentionDays 7
        } | Should -Throw '*could not be recorded before deletion*'

        $deleteAttempts | Should -Be 0
        Test-Path -LiteralPath $oldOne | Should -BeTrue
        Test-Path -LiteralPath $oldTwo | Should -BeTrue
    }
}

Describe 'Launch fixture state' {
    It 'initializes the shared fixture from a blank script scope' {
        $launchScriptPath = Join-Path $PSScriptRoot '..\scripts\launch.ps1'
        $previousState = Get-LaunchFixtureState
        $previousLaunchScopeValue = Get-Variable -Scope Script -Name previousLaunchScope -ErrorAction SilentlyContinue
        try {
            foreach ($name in @(
                'LogDir',
                'AggregateLog',
                'RunLogPath',
                'LogRetentionCount',
                'LogRetentionDays',
                'TaskLaunchStatePath',
                'RepoRoot',
                'CanonicalScript',
                'Provider',
                'Model',
                'OllamaHost',
                'SchedulerPolicy',
                'MaxLoopMinutes',
                'PerRunTimeoutMinutes',
                'NoAiEdit',
                'TaskName',
                'TaskPath',
                'ScheduledTaskAuthor',
                'TaskFixtureRoot',
                'ScheduleFrequency',
                'ScheduleTime',
                'previousLaunchScope'
            )) {
                Remove-Variable -Scope Script -Name $name -ErrorAction SilentlyContinue
            }

            Initialize-LaunchFixtureState -LaunchScriptPath $launchScriptPath

            $expectedLogDir = Join-Path (Join-Path $env:HOMEDRIVE 'myTech.Today') 'logs'
            $expectedAggregateLog = Join-Path $expectedLogDir 'autoresearch.jsonl'
            $expectedTaskLaunchStatePath = Join-Path $expectedLogDir 'autoresearch-task-launch.json'

            $script:LogDir | Should -Be $expectedLogDir
            $script:AggregateLog | Should -Be $expectedAggregateLog
            $script:RunLogPath | Should -BeNullOrEmpty
            $script:LogRetentionCount | Should -Be 25
            $script:LogRetentionDays | Should -Be 14
            $script:TaskLaunchStatePath | Should -Be $expectedTaskLaunchStatePath
            $script:Provider | Should -Be 'ollama'
            $script:SchedulerPolicy | Should -Be 'IdleOnly'
            $script:NoAiEdit | Should -BeFalse
            $script:previousLaunchScope.LogDir | Should -Be $expectedLogDir
            $script:previousLaunchScope.AggregateLog | Should -Be $expectedAggregateLog
            $script:previousLaunchScope.TaskLaunchStatePath | Should -Be $expectedTaskLaunchStatePath
        }
        finally {
            Set-LaunchFixtureState -State $previousState
            if ($null -ne $previousLaunchScopeValue) {
                $script:previousLaunchScope = $previousLaunchScopeValue.Value
            } else {
                Remove-Variable -Scope Script -Name previousLaunchScope -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'Launcher defaults persistence' {
    BeforeEach {
        $defaultsPathVariable = Get-Variable -Scope Script -Name DefaultsPath -ErrorAction SilentlyContinue
        $legacyDefaultsPathVariable = Get-Variable -Scope Script -Name LegacyDefaultsPath -ErrorAction SilentlyContinue
        $script:previousDefaultsPath = $defaultsPathVariable
        $script:previousLegacyDefaultsPath = $legacyDefaultsPathVariable
        $root = New-TestRoot 'launch-defaults'
        $script:DefaultsPath = Join-Path $root 'local-app-data\myTech.Today\autoresearch-win-rtx-scheduled\launch.json'
        $script:LegacyDefaultsPath = Join-Path $root 'canonical\scripts\launch.json'
    }

    AfterEach {
        if ($null -ne $script:previousDefaultsPath) {
            Set-Variable -Scope Script -Name DefaultsPath -Value $script:previousDefaultsPath.Value -Force
        } else {
            Remove-Variable -Scope Script -Name DefaultsPath -ErrorAction SilentlyContinue
        }
        if ($null -ne $script:previousLegacyDefaultsPath) {
            Set-Variable -Scope Script -Name LegacyDefaultsPath -Value $script:previousLegacyDefaultsPath.Value -Force
        } else {
            Remove-Variable -Scope Script -Name LegacyDefaultsPath -ErrorAction SilentlyContinue
        }
        Remove-Variable -Scope Script -Name previousDefaultsPath -ErrorAction SilentlyContinue
        Remove-Variable -Scope Script -Name previousLegacyDefaultsPath -ErrorAction SilentlyContinue
    }

    It 'round-trips only documented non-secret fields' {
        $expected = [ordered]@{
            Provider          = 'azure'
            Model             = 'gpt-4o'
            OllamaHost        = 'http://127.0.0.1:11434'
            AzureEndpoint     = 'https://example.openai.azure.com/'
            AzureDeployment   = 'research'
            LogDir            = 'C:\myTech.Today\logs'
            ScheduleFrequency = 'Weekly'
            ScheduleTime      = 'Wednesday'
            SchedulerPolicy   = 'Unattended'
        }
        $values = @{} + $expected
        $values.ApiKey = 'must-not-be-written'
        $values.EnableHistory = $true
        $values.Action = 'RunNow'

        Save-LaunchDefaults -Values $values

        $persisted = Get-Content -LiteralPath $script:DefaultsPath -Raw | ConvertFrom-Json
        @($persisted.PSObject.Properties.Name | Sort-Object) | Should -Be @($expected.Keys | Sort-Object)
        $persisted.PSObject.Properties['ApiKey'] | Should -BeNullOrEmpty
        $persisted.PSObject.Properties['EnableHistory'] | Should -BeNullOrEmpty
        $persisted.PSObject.Properties['Action'] | Should -BeNullOrEmpty

        $loaded = Read-LaunchDefaults
        foreach ($key in $expected.Keys) {
            $loaded.$key | Should -Be $expected[$key]
        }
    }

    It 'reads legacy adjacent defaults without writing them back' {
        $legacyValues = [ordered]@{
            Provider          = 'openai'
            Model             = 'gpt-4o-mini'
            OllamaHost        = 'http://localhost:11434'
            AzureEndpoint     = ''
            AzureDeployment   = ''
            LogDir            = 'C:\logs\autoresearch'
            ScheduleFrequency = 'Daily'
            ScheduleTime      = '18:00'
            SchedulerPolicy   = 'IdleOnly'
        }
        New-Dir -Path (Split-Path -Parent $script:LegacyDefaultsPath)
        ($legacyValues | ConvertTo-Json) | Set-Content -LiteralPath $script:LegacyDefaultsPath -Encoding UTF8

        $loaded = Read-LaunchDefaults

        $loaded.Provider | Should -Be 'openai'
        $loaded.Model | Should -Be 'gpt-4o-mini'
        Test-Path -LiteralPath $script:DefaultsPath | Should -BeFalse
    }
}

Describe 'Task launch supervisor' {
    BeforeEach {
        $script:previousLaunchScope = Get-LaunchFixtureState
        $root = New-TestRoot 'task-launch-supervisor'
        $script:LogDir = Join-Path $root 'logs'
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        $script:AggregateLog = Join-Path $script:LogDir 'autoresearch.jsonl'
        $script:TaskLaunchStatePath = Join-Path $script:LogDir 'autoresearch-task-launch.json'
        $script:RepoRoot = $root
        $script:CanonicalScript = Join-Path $root 'scripts\launch.ps1'
        $script:Provider = 'ollama'
        $script:Model = 'qwen2.5-coder:latest'
        $script:OllamaHost = 'http://127.0.0.1:11434'
        $script:SchedulerPolicy = 'IdleOnly'
        $script:MaxLoopMinutes = 0
        $script:PerRunTimeoutMinutes = 10
        $script:NoAiEdit = $false
        Mock Write-Json { }
        Mock Get-PwshExePath { return 'C:\Program Files\PowerShell\7\pwsh.exe' }
        Mock Get-CurrentProcessCommandLine {
            return 'pwsh.exe -NoProfile -ExecutionPolicy Bypass -File launch.ps1 -NoGui -TaskSupervisor -ApiKey super-secret -AzureEndpoint https://example.openai.azure.com -AzureDeployment prod-deploy'
        }
    }

    AfterEach {
        Set-LaunchFixtureState -State $script:previousLaunchScope
    }

    It 'records the child pid and exit code when the child succeeds' {
        $script:startProcessArgs = $null
        Mock Start-Process {
            param(
                [string]$FilePath,
                [string[]]$ArgumentList,
                [string]$WorkingDirectory,
                [string]$WindowStyle,
                [switch]$PassThru,
                [switch]$Wait
            )
            $script:startProcessArgs = [pscustomobject]@{
                FilePath = $FilePath
                ArgumentList = @($ArgumentList)
                WorkingDirectory = $WorkingDirectory
                WindowStyle = $WindowStyle
                PassThru = [bool]$PassThru
                Wait = [bool]$Wait
            }
            return [pscustomobject]@{ Id = 4242; ExitCode = 0 }
        }

        $exitCode = Invoke-TaskLaunchSupervisor

        $exitCode | Should -Be 0
        Test-Path -LiteralPath $script:TaskLaunchStatePath | Should -BeTrue
        $state = Get-Content -LiteralPath $script:TaskLaunchStatePath -Raw | ConvertFrom-Json
        $state.status | Should -Be 'succeeded'
        $state.childPid | Should -Be 4242
        $state.childExitCode | Should -Be 0
        $state.parentPid | Should -Be $PID
        $state.parentCommandLine | Should -Match 'TaskSupervisor'
        $state.parentCommandLine | Should -Not -Match 'super-secret'
        $state.parentCommandLine | Should -Match 'ApiKey'
        $state.parentCommandLine | Should -Match 'AzureEndpoint'
        $state.parentCommandLine | Should -Match 'AzureDeployment'
        $state.childCommandLine | Should -Match '-RunLoop'
        $state.taskActionCommand | Should -Match '-TaskSupervisor'
        $script:startProcessArgs.FilePath | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
        $script:startProcessArgs.WindowStyle | Should -Be 'Hidden'
        $script:startProcessArgs.ArgumentList | Should -Contain '-RunLoop'
        $script:startProcessArgs.ArgumentList | Should -Contain '-NoGui'
        $stateFileContents = Get-Content -LiteralPath $script:TaskLaunchStatePath -Raw
        $stateFileContents | Should -Not -Match 'super-secret'
        $stateFileContents | Should -Not -Match 'https://example\.openai\.azure\.com'
        $stateFileContents | Should -Not -Match 'prod-deploy'
    }

    It 'records the failure when the child exits non-zero' {
        Mock Start-Process {
            return [pscustomobject]@{ Id = 4243; ExitCode = 7 }
        }

        $exitCode = Invoke-TaskLaunchSupervisor

        $exitCode | Should -Be 7
        $state = Get-Content -LiteralPath $script:TaskLaunchStatePath -Raw | ConvertFrom-Json
        $state.status | Should -Be 'failed'
        $state.childPid | Should -Be 4243
        $state.childExitCode | Should -Be 7
    }
}

Describe 'Task launch state persistence' {
    BeforeEach {
        $script:previousLaunchScope = Get-LaunchFixtureState
        $root = New-TestRoot 'task-launch-state-writer'
        $script:LogDir = Join-Path $root 'logs'
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        $script:AggregateLog = Join-Path $script:LogDir 'autoresearch.jsonl'
        $script:TaskLaunchStatePath = Join-Path $script:LogDir 'autoresearch-task-launch.json'
        Mock New-Dir { }
        Mock Ensure-LauncherDirectoryAcl { }
        Mock Write-Json { }
    }

    AfterEach {
        Set-LaunchFixtureState -State $script:previousLaunchScope
    }

    It 'warns and throws when the state file cannot be written' {
        Mock Set-Content {
            throw 'simulated state write failure'
        }

        { Write-TaskLaunchState -State @{ status = 'starting'; parentPid = 1234 } } |
            Should -Throw '*simulated state write failure*'

        Should -Invoke Write-Json -Times 1 -Exactly -Scope It -ParameterFilter {
            $Level -eq 'warn' -and
            $Message -like 'Task launch state write failed*'
        }
        Test-Path -LiteralPath $script:TaskLaunchStatePath | Should -BeFalse
    }
}

Describe 'Update compatibility' {
    It 'keeps uv on the current minor line' {
        Mock Get-ToolVersion { return '0.11.19' } -ParameterFilter { $Name -eq 'uv' }
        Mock Get-UvReleaseVersions { return @('0.12.10', '0.11.33', '0.11.32') }

        Get-UvCompatibleTargetVersion | Should -Be '0.11.33'
    }

    It 'keeps Ollama on the current minor line' {
        Mock Get-ToolVersion { return '0.32.1' } -ParameterFilter { $Name -eq 'ollama' }
        Mock Get-WingetPackageVersions { return @('0.33.3', '0.32.15', '0.32.1') }

        Get-OllamaCompatibleTargetVersion | Should -Be '0.32.15'
    }

    It 'reads the pinned ai-powered version from package-lock' {
        Get-PinnedAiPoweredVersion | Should -Be '0.3.2'
    }

    It 'rolls back a failed update before the workload can continue' {
        $script:installCalls = @()
        $script:rollbackCalls = @()
        $script:smokeCalls = @()
        $script:pathRefreshCount = 0
        Mock Write-Json { }
        Mock Update-SessionPath { $script:pathRefreshCount++ }
        $install = {
            param([string]$TargetVersion, [string]$CurrentVersion)
            $script:installCalls += "$CurrentVersion->$TargetVersion"
        }
        $smoke = {
            param([string]$TargetVersion, [string]$CurrentVersion)
            $script:smokeCalls += "$CurrentVersion->$TargetVersion"
            if ($TargetVersion -eq '0.11.33') {
                throw 'simulated smoke failure'
            }
            return $TargetVersion
        }
        $rollback = {
            param([string]$TargetVersion, [string]$CurrentVersion)
            $script:rollbackCalls += "$CurrentVersion->$TargetVersion"
        }

        { Invoke-CompatibilityCheckedUpdateStep -ToolName 'uv' -CurrentVersion '0.11.19' -TargetVersion '0.11.33' -InstallAction $install -SmokeAction $smoke -RollbackAction $rollback } |
            Should -Throw -ExpectedMessage '*simulated smoke failure*'

        $script:installCalls | Should -Be @('0.11.19->0.11.33')
        $script:rollbackCalls | Should -Be @('0.11.33->0.11.19')
        $script:smokeCalls | Should -Be @('0.11.19->0.11.33', '0.11.19->0.11.19')
        $script:pathRefreshCount | Should -Be 2
    }

    It 'returns a structured summary when the smoke check passes' {
        $script:installCalls = @()
        $script:smokeCalls = @()
        Mock Write-Json { }
        Mock Update-SessionPath { }
        $install = {
            param([string]$TargetVersion, [string]$CurrentVersion)
            $script:installCalls += "$CurrentVersion->$TargetVersion"
        }
        $smoke = {
            param([string]$TargetVersion, [string]$CurrentVersion)
            $script:smokeCalls += "$CurrentVersion->$TargetVersion"
            return $TargetVersion
        }
        $rollback = {
            param([string]$TargetVersion, [string]$CurrentVersion)
            throw 'rollback should not run on success'
        }

        $result = Invoke-CompatibilityCheckedUpdateStep -ToolName 'ai-powered' -CurrentVersion '0.3.1' -TargetVersion '0.3.2' -InstallAction $install -SmokeAction $smoke -RollbackAction $rollback

        $result.tool | Should -Be 'ai-powered'
        $result.before | Should -Be '0.3.1'
        $result.target | Should -Be '0.3.2'
        $result.after | Should -Be '0.3.2'
        $result.updated | Should -BeTrue
        $result.rolledBack | Should -BeFalse
        $script:installCalls | Should -Be @('0.3.1->0.3.2')
        $script:smokeCalls | Should -Be @('0.3.1->0.3.2')
    }
}

Describe 'Update orchestration' {
    BeforeEach {
        $script:steps = @()
        Mock Write-Json { }
    }

    It 'reports upgraded and left-alone steps and keeps Ollama post-update behavior intact' {
        $script:Provider = 'ollama'
        Mock Invoke-UvUpdate {
            $script:steps += 'uv'
            return [pscustomobject]@{
                tool = 'uv'
                before = '0.11.19'
                target = '0.11.33'
                after = '0.11.33'
                updated = $true
                rolledBack = $false
            }
        }
        Mock Invoke-OllamaUpdate {
            $script:steps += 'ollama'
            return [pscustomobject]@{
                tool = 'ollama'
                before = '0.32.1'
                target = '0.32.15'
                after = '0.32.15'
                updated = $true
                rolledBack = $false
            }
        }
        Mock Invoke-AiPoweredUpdate {
            $script:steps += 'ai-powered'
            return [pscustomobject]@{
                tool = 'ai-powered'
                before = '0.3.2'
                target = '0.3.2'
                after = '0.3.2'
                updated = $false
                rolledBack = $false
            }
        }
        Mock Start-OllamaServer { $script:steps += 'start-ollama' }
        Mock Sync-OllamaModel { $script:steps += 'sync-model' }

        $result = Invoke-Update

        $result.Summary | Should -Match 'uv 0.11.19 -> 0.11.33'
        $result.Summary | Should -Match 'ollama 0.32.1 -> 0.32.15'
        $result.Summary | Should -Match 'ai-powered left at 0.3.2'
        $script:steps | Should -Be @('uv', 'ollama', 'ai-powered', 'start-ollama', 'sync-model')
        Should -Invoke Start-OllamaServer -Times 1 -Exactly -Scope It
        Should -Invoke Sync-OllamaModel -Times 1 -Exactly -Scope It
    }

    It 'leaves Ollama alone when another provider is selected' {
        $script:Provider = 'openai'
        Mock Invoke-UvUpdate {
            $script:steps += 'uv'
            return [pscustomobject]@{
                tool = 'uv'
                before = '0.11.19'
                target = '0.11.33'
                after = '0.11.33'
                updated = $true
                rolledBack = $false
            }
        }
        Mock Invoke-AiPoweredUpdate {
            $script:steps += 'ai-powered'
            return [pscustomobject]@{
                tool = 'ai-powered'
                before = '0.3.2'
                target = '0.3.2'
                after = '0.3.2'
                updated = $false
                rolledBack = $false
            }
        }
        Mock Start-OllamaServer { throw 'should not be called for openai provider' }
        Mock Sync-OllamaModel { throw 'should not be called for openai provider' }

        $result = Invoke-Update

        $result.Steps[1].skipped | Should -BeTrue
        $result.Steps[1].reason | Should -Match 'does not use Ollama'
        $script:steps | Should -Be @('uv', 'ai-powered')
        Should -Invoke Start-OllamaServer -Times 0 -Scope It
        Should -Invoke Sync-OllamaModel -Times 0 -Scope It
    }
}

Describe 'Unregister-LauncherTask' {
    BeforeEach {
        $script:unregisterCount = 0
        Mock Write-Json { }
        Mock Unregister-ScheduledTask { $script:unregisterCount++ }
        Mock Get-RegisteredLauncherTask { return $null }
    }

    It 'is safe to call repeatedly when the task is already absent' {
        Unregister-LauncherTask
        Unregister-LauncherTask
        $script:unregisterCount | Should -Be 0
    }
}

Describe 'GUI policy surface' {
    It 'surfaces the scheduler policy choices and explanation text' {
        $xaml = Get-LaunchGuiXaml
        $xaml | Should -Match 'PolInteractive'
        $xaml | Should -Match 'PolIdleOnly'
        $xaml | Should -Match 'PolUnattended'
        $xaml | Should -Match 'TxtPolicySummary'
        $xaml | Should -Match 'Interactive - logged-on session only, no idle wait'
        $xaml | Should -Match 'Idle-only - waits for 5 minutes of idle time'
        $xaml | Should -Match 'Unattended - S4U logon, no active desktop required'
    }
}

Describe 'Bootstrap boundary' {
    It 'loads functions in import-only mode without invoking bootstrap commands' {
        $root = New-TestRoot 'import-only'
        $fakeGitLog = Join-Path $root 'git-invocations.log'
        $fakeGitBin = New-FakeGitCommand -Root $root -LogPath $fakeGitLog
        $checkout = Join-Path $root 'checkout'
        New-Item -ItemType Directory -Path $checkout -Force | Out-Null
        $scriptCopy = Join-Path $checkout 'launch.ps1'
        Copy-Item -LiteralPath $scriptPath -Destination $scriptCopy
        $command = @"
`$ErrorActionPreference = 'Stop'
`$env:AUTORESEARCH_DOT_SOURCE_ONLY = '1'
`$env:PATH = $(ConvertTo-SingleQuotedLiteral $fakeGitBin) + ';' + `$env:PATH
. $(ConvertTo-SingleQuotedLiteral $scriptCopy)
if (-not (Get-Command Invoke-Bootstrap -ErrorAction SilentlyContinue)) {
    throw 'Invoke-Bootstrap was not loaded.'
}
"@
        $result = Invoke-PowershellCommandForTest -Command $command
        $result.ExitCode | Should -Be 0
        Test-Path -LiteralPath $fakeGitLog | Should -BeFalse
    }

    It 'refuses a dirty canonical install and preserves tracked, untracked, and ignored files when clone would fail' {
        $root = New-TestRoot 'dirty-bootstrap-refusal'
        $fakeGitLog = Join-Path $root 'git-invocations.log'
        $fakeGitBin = New-FakeGitCommand -Root $root -LogPath $fakeGitLog
        $canonicalRepo = Join-Path $root 'canonical repo'
        $repoUrl = 'https://example.invalid/autoresearch-win-rtx-scheduled.git'
        $repoFiles = New-TemporaryGitRepository -Root $canonicalRepo -OriginUrl $repoUrl -Dirty
        $checkout = Join-Path $root 'checkout'
        New-Item -ItemType Directory -Path $checkout -Force | Out-Null
        $scriptCopy = Join-Path $checkout 'launch.ps1'
        Copy-Item -LiteralPath $scriptPath -Destination $scriptCopy

        $trackedBefore = Get-Content -LiteralPath $repoFiles.TrackedPath -Raw
        $untrackedBefore = Get-Content -LiteralPath $repoFiles.UntrackedPath -Raw
        $ignoredBefore = Get-Content -LiteralPath $repoFiles.IgnoredPath -Raw
        $result = Invoke-BootstrapTestFixture -ScriptPath $scriptCopy -CanonicalRepo $canonicalRepo -GitBin $fakeGitBin -Root $root -RepoUrl $repoUrl
        $result.ExitCode | Should -Not -Be 0
        (Get-Content -LiteralPath $repoFiles.TrackedPath -Raw) | Should -BeExactly $trackedBefore
        (Get-Content -LiteralPath $repoFiles.UntrackedPath -Raw) | Should -BeExactly $untrackedBefore
        (Get-Content -LiteralPath $repoFiles.IgnoredPath -Raw) | Should -BeExactly $ignoredBefore
        $output = $result.Output -join "`n"
        $outputText = $output -join "`n"
        $outputText | Should -Match 'Refusing to bootstrap canonical install'
        $outputText | Should -Match 'because it has\s+local changes'
        $output | Should -Match 'tracked.txt'
        $output | Should -Match 'untracked.sentinel'
        $gitLog = Get-Content -LiteralPath $fakeGitLog -Raw
        $gitLog | Should -Match 'status --porcelain'
        $gitLog | Should -Not -Match '\b(pull|clone)\b'
        Test-Path -LiteralPath (Join-Path $root 'start-process.log') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'remove-item.log') | Should -BeFalse
    }

    It 'refuses an unexpected origin and preserves the existing canonical tree' {
        $root = New-TestRoot 'origin-mismatch-bootstrap'
        $fakeGitLog = Join-Path $root 'git-invocations.log'
        $fakeGitBin = New-FakeGitCommand -Root $root -LogPath $fakeGitLog
        $canonicalRepo = Join-Path $root 'canonical'
        $repoFiles = New-TemporaryGitRepository -Root $canonicalRepo -OriginUrl 'https://wrong.invalid/other.git'
        $checkout = Join-Path $root 'checkout'
        New-Item -ItemType Directory -Path $checkout -Force | Out-Null
        $scriptCopy = Join-Path $checkout 'launch.ps1'
        Copy-Item -LiteralPath $scriptPath -Destination $scriptCopy

        $trackedBefore = Get-Content -LiteralPath $repoFiles.TrackedPath -Raw
        $ignoredBefore = Get-Content -LiteralPath $repoFiles.IgnoredPath -Raw
        $expectedRepoUrl = 'https://example.invalid/autoresearch-win-rtx-scheduled.git'
        $result = Invoke-BootstrapTestFixture -ScriptPath $scriptCopy -CanonicalRepo $canonicalRepo -GitBin $fakeGitBin -Root $root -RepoUrl $expectedRepoUrl

        $result.ExitCode | Should -Not -Be 0
        (Get-Content -LiteralPath $repoFiles.TrackedPath -Raw) | Should -BeExactly $trackedBefore
        (Get-Content -LiteralPath $repoFiles.IgnoredPath -Raw) | Should -BeExactly $ignoredBefore
        ($result.Output -join "`n") | Should -Match '(?s)origin\s+could not be verified as the expected repository'
        $gitLog = Get-Content -LiteralPath $fakeGitLog -Raw
        $gitLog | Should -Match 'remote get-url --all origin'
        $gitLog | Should -Not -Match '\b(pull|clone)\b'
        Test-Path -LiteralPath (Join-Path $root 'start-process.log') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'remove-item.log') | Should -BeFalse
    }

    It 'updates a clean canonical checkout with the expected origin and forwards arguments once' {
        $root = New-TestRoot 'clean-bootstrap-update'
        $fakeGitLog = Join-Path $root 'git-invocations.log'
        $fakeGitBin = New-FakeGitCommand -Root $root -LogPath $fakeGitLog
        $canonicalRepo = Join-Path $root 'canonical'
        $repoUrl = 'https://example.invalid/autoresearch-win-rtx-scheduled.git'
        $repoFiles = New-TemporaryGitRepository -Root $canonicalRepo -OriginUrl $repoUrl
        $checkout = Join-Path $root 'checkout'
        New-Item -ItemType Directory -Path $checkout -Force | Out-Null
        $scriptCopy = Join-Path $checkout 'launch.ps1'
        Copy-Item -LiteralPath $scriptPath -Destination $scriptCopy

        $trackedBefore = Get-Content -LiteralPath $repoFiles.TrackedPath -Raw
        $ignoredBefore = Get-Content -LiteralPath $repoFiles.IgnoredPath -Raw
        $result = Invoke-BootstrapTestFixture -ScriptPath $scriptCopy -CanonicalRepo $canonicalRepo -GitBin $fakeGitBin -Root $root -RepoUrl $repoUrl -ForwardArgs @('-NoGui', '--custom', 'value with spaces')

        $result.ExitCode | Should -Be 0
        (Get-Content -LiteralPath $repoFiles.TrackedPath -Raw) | Should -BeExactly $trackedBefore
        (Get-Content -LiteralPath $repoFiles.IgnoredPath -Raw) | Should -BeExactly $ignoredBefore
        @((Get-Content -LiteralPath $fakeGitLog) | Where-Object { $_ -match '\bpull --ff-only$' }) | Should -HaveCount 1
        @((Get-Content -LiteralPath (Join-Path $root 'start-process.log'))).Count | Should -Be 1
        (Get-Content -LiteralPath (Join-Path $root 'start-process.log') -Raw) | Should -Match '-NoGui\|--custom\|value with spaces'
        Test-Path -LiteralPath (Join-Path $root 'remove-item.log') | Should -BeFalse
    }

    It 'keeps the clean canonical tree when the mocked fast-forward update fails' {
        $root = New-TestRoot 'failed-clean-bootstrap-update'
        $fakeGitLog = Join-Path $root 'git-invocations.log'
        $fakeGitBin = New-FakeGitCommand -Root $root -LogPath $fakeGitLog -PullExitCode 82
        $canonicalRepo = Join-Path $root 'canonical'
        $repoUrl = 'https://example.invalid/autoresearch-win-rtx-scheduled.git'
        $repoFiles = New-TemporaryGitRepository -Root $canonicalRepo -OriginUrl $repoUrl
        $checkout = Join-Path $root 'checkout'
        New-Item -ItemType Directory -Path $checkout -Force | Out-Null
        $scriptCopy = Join-Path $checkout 'launch.ps1'
        Copy-Item -LiteralPath $scriptPath -Destination $scriptCopy

        $trackedBefore = Get-Content -LiteralPath $repoFiles.TrackedPath -Raw
        $ignoredBefore = Get-Content -LiteralPath $repoFiles.IgnoredPath -Raw
        $result = Invoke-BootstrapTestFixture -ScriptPath $scriptCopy -CanonicalRepo $canonicalRepo -GitBin $fakeGitBin -Root $root -RepoUrl $repoUrl

        $result.ExitCode | Should -Not -Be 0
        (Get-Content -LiteralPath $repoFiles.TrackedPath -Raw) | Should -BeExactly $trackedBefore
        (Get-Content -LiteralPath $repoFiles.IgnoredPath -Raw) | Should -BeExactly $ignoredBefore
        @((Get-Content -LiteralPath $fakeGitLog) | Where-Object { $_ -match '\bpull --ff-only$' }) | Should -HaveCount 1
        Test-Path -LiteralPath (Join-Path $root 'start-process.log') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'remove-item.log') | Should -BeFalse
    }

    It 'skips bootstrap when -NoBootstrap is used and still reaches local entry points' {
        $root = New-TestRoot 'no-bootstrap'
        $fakeGitLog = Join-Path $root 'git-invocations.log'
        $fakeGitBin = New-FakeGitCommand -Root $root -LogPath $fakeGitLog
        $checkout = Join-Path $root 'checkout'
        New-Item -ItemType Directory -Path $checkout -Force | Out-Null
        $scriptCopy = Join-Path $checkout 'launch.ps1'
        Copy-Item -LiteralPath $scriptPath -Destination $scriptCopy
$command = @"
`$ErrorActionPreference = 'Stop'
function Get-ScheduledTask {
    [CmdletBinding()]
    param(
        [string]`$TaskPath,
        [string]`$TaskName
    )
    return $null
}
function Unregister-ScheduledTask {
    [CmdletBinding()]
    param(
        [string]`$TaskPath,
        [string]`$TaskName
    )
}
& $(ConvertTo-SingleQuotedLiteral $scriptCopy) -NoBootstrap -Debug -Unregister
"@
        $result = Invoke-PowershellCommandForTest -Command $command -Environment @{ HOMEDRIVE = $root; PATH = "$fakeGitBin;$env:PATH" }
        $result.ExitCode | Should -Be 0
        $output = $result.Output -join "`n"
        $output | Should -Match '(-NoBootstrap was supplied|Import-only mode enabled via AUTORESEARCH_DOT_SOURCE_ONLY)'
        Test-Path -LiteralPath $fakeGitLog | Should -BeFalse
    }
}

Describe 'Launcher quick-start guidance' {
    It 'defaults to a local checkout workflow instead of remote execution' {
        $source = Get-Content -LiteralPath $scriptPath -Raw
        $headerEnd = $source.IndexOf('<#')
        $headerEnd | Should -BeGreaterThan 0
        $header = $source.Substring(0, $headerEnd)

        $header | Should -Match '(?m)^# Local Quick Start\.'
        $header | Should -Match '(?m)^#\s+git clone https://github\.com/mytech-today-now/autoresearch-win-rtx-scheduled\.git\r?$'
        $header | Should -Match '(?m)^#\s+powershell -NoProfile -ExecutionPolicy Bypass -File \.\\scripts\\launch\.ps1\r?$'
        $header | Should -Not -Match '(?is)\biwr\b.*\biex\b'
        $source | Should -Not -Match '(?is)\biwr\b.*\biex\b'
    }
}

Describe 'Pester bootstrap' {
    It 'reports a clear setup error when only an older Pester version is visible' {
        $root = New-TestRoot 'pester-bootstrap'
        $moduleRoot = Join-Path $root 'modules'
        Write-FakePesterModule -Root $moduleRoot -Version '4.10.0' | Out-Null
        $installScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\scripts\install-pester.ps1')).Path
        $command = @"
`$ErrorActionPreference = 'Stop'
function Install-Module {
    throw 'simulated install failure'
}
& $(ConvertTo-SingleQuotedLiteral $installScript) -RequiredVersion 5.0.0
"@
        $result = Invoke-PowershellCommandForTest -Command $command -Environment @{
            PSModulePath = $moduleRoot
        }
        $result.ExitCode | Should -Not -Be 0
        $output = $result.Output -join "`n"
        $output | Should -Match 'Pester 5\.0\.0'
        $output | Should -Match 'Available Pester versions before bootstrap: 4\.10\.0'
        $output | Should -Match 'Install-Module Pester -Scope CurrentUser -RequiredVersion 5\.0\.0 -Force -AllowClobber'
        $output | Should -Match 'simulated install failure'
    }
}

Describe 'Provider verification' {
    It 'allows launcher env forwarding' {
        $root = New-TestRoot 'provider-launcher'
        Write-ProviderVerificationFixture -Root $root
        Set-Content -LiteralPath (Join-Path $root 'scripts\launch.ps1') -Value @'
param([string]$ApiKey)
if ($ApiKey) {
    [Environment]::SetEnvironmentVariable('OPENAI_API_KEY', $ApiKey, 'Process')
    [Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', $ApiKey, 'Process')
    [Environment]::SetEnvironmentVariable('AZURE_OPENAI_API_KEY', $ApiKey, 'Process')
}
'@ -Encoding ASCII
        $result = Invoke-ProviderVerificationForTest -Root $root
        $result.ExitCode | Should -Be 0
        ($result.Output -join "`n") | Should -Match 'Provider verification passed'
    }

    It 'fails on a direct provider SDK import' {
        $root = New-TestRoot 'provider-direct'
        Write-ProviderVerificationFixture -Root $root
        $providerPackage = 'open' + 'ai'
        Set-Content -LiteralPath (Join-Path $root 'src\sample.mjs') -Value @"
import OpenAI from "$providerPackage";
export const client = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
"@ -Encoding ASCII
        $result = Invoke-ProviderVerificationForTest -Root $root
        $result.ExitCode | Should -Not -Be 0
        ($result.Output -join "`n") | Should -Match 'disallowed direct provider usage'
    }

    It 'fails on a copied launcher with direct provider usage' {
        $root = New-TestRoot 'provider-launch-copy'
        Write-ProviderVerificationFixture -Root $root
        $providerPackage = 'open' + 'ai'
        Set-Content -LiteralPath (Join-Path $root 'scripts\launch copy 2.ps1') -Value @"
# import OpenAI from "$providerPackage";
"@ -Encoding ASCII
        $result = Invoke-ProviderVerificationForTest -Root $root
        $result.ExitCode | Should -Not -Be 0
        ($result.Output -join "`n") | Should -Match 'disallowed direct provider usage'
    }

    It 'fails on a Python provider literal' {
        $root = New-TestRoot 'provider-python'
        Write-ProviderVerificationFixture -Root $root
        Set-Content -LiteralPath (Join-Path $root 'train.py') -Value @'
provider_name = "openai"
'@ -Encoding ASCII
        $result = Invoke-ProviderVerificationForTest -Root $root
        $result.ExitCode | Should -Not -Be 0
        ($result.Output -join "`n") | Should -Match 'disallowed direct provider usage'
    }

    It 'fails on provider key names in checked-in source files' {
        $root = New-TestRoot 'provider-config'
        Write-ProviderVerificationFixture -Root $root
        Set-Content -LiteralPath (Join-Path $root 'src\sample.ps1') -Value @'
param([string]$ApiKey)
if ($ApiKey) {
    [Environment]::SetEnvironmentVariable('OPENAI_API_KEY', $ApiKey, 'Process')
}
'@ -Encoding ASCII
        $result = Invoke-ProviderVerificationForTest -Root $root
        $result.ExitCode | Should -Not -Be 0
        ($result.Output -join "`n") | Should -Match 'disallowed provider configuration'
    }

    It 'ignores local .env files' {
        $root = New-TestRoot 'provider-env'
        Write-ProviderVerificationFixture -Root $root
        Set-Content -LiteralPath (Join-Path $root '.env') -Value @'
OPENAI_API_KEY=local-secret
ANTHROPIC_API_KEY=local-secret
AZURE_OPENAI_API_KEY=local-secret
'@ -Encoding ASCII
        $result = Invoke-ProviderVerificationForTest -Root $root
        $result.ExitCode | Should -Be 0
        ($result.Output -join "`n") | Should -Match 'Provider verification passed'
    }
}
