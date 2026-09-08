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
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:CanonicalScript = (Resolve-Path -LiteralPath $LaunchScriptPath).Path
    $script:Provider = 'ollama'
    $script:Model = 'qwen2.5-coder:latest'
    $script:OllamaHost = 'http://127.0.0.1:11434'
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
        'Update-SessionPath',
        'Start-OllamaServer',
        'Sync-OllamaModel',
        'Add-RunLogReason',
        'Get-RunLogMetadata',
        'Get-RunLogRetentionPlan',
        'Limit-RunLogs',
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
        [switch]$DirtyStatus
    )
    $bin = Join-Path $Root 'bin'
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    $statusEcho = if ($DirtyStatus) { 'echo M dirty.txt' } else { 'echo.' }
    $content = @"
@echo off
setlocal
echo %*>>"$LogPath"
echo %* | findstr /i "status" >nul
if not errorlevel 1 (
    $statusEcho
)
exit /b 0
"@
    Set-Content -LiteralPath (Join-Path $bin 'git.cmd') -Value $content -Encoding ASCII
    return $bin
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
        $summary.pruning.deletedCount | Should -Be 2
        @($summary.pruning.deleted) | Should -HaveCount 2
        $result.Summary.deletedCount | Should -Be 2
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
        Assert-MockCalled Start-OllamaServer -Times 1
        Assert-MockCalled Sync-OllamaModel -Times 1
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
        Assert-MockCalled Start-OllamaServer -Times 0
        Assert-MockCalled Sync-OllamaModel -Times 0
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
        $result = Invoke-PowershellCommandForTest -Command $command -Environment @{ PATH = "$fakeGitBin;$env:PATH" }
        $result.ExitCode | Should -Be 0
        $output = $result.Output -join "`n"
        $output | Should -Match '(-NoBootstrap was supplied|Import-only mode enabled via AUTORESEARCH_DOT_SOURCE_ONLY)'
        Test-Path -LiteralPath $fakeGitLog | Should -BeFalse
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
