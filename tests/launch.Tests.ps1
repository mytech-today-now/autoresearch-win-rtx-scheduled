#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

$HarnessRoot = Split-Path -Parent $PSScriptRoot

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) { throw $Message }
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
        'ConvertTo-WeekdayMask',
        'Get-ComputerIdleState',
        'Get-PwshExePath',
        'Get-ScheduleTriggerSpec',
        'Get-ScheduleTimeOptions',
        'Get-ScheduleTimeDefault',
        'Get-SchedulerPolicyInfo',
        'Get-ScheduledTaskDescription',
        'Get-TaskLauncherPlan',
        'Get-TaskXml',
        'Test-ScheduleTime',
        'Get-TaskTrigger',
        'Invoke-IdlePolicyGate',
        'Write-Json',
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
}

function script:New-TestRoot {
    param([string]$Name)
    $path = Join-Path $env:TEMP ("autoresearch-$Name-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
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
    foreach ($key in $Environment.Keys) {
        $previous[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
        [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], "Process")
    }
    try {
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -Command $Command 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output) }
    }
    finally {
        foreach ($key in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($key, $previous[$key], "Process")
        }
    }
}

function script:Invoke-ProviderVerificationForTest {
    param([Parameter(Mandatory)][string]$Root)
    Push-Location $Root
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & node (Join-Path $HarnessRoot 'scripts/verify-ai-provider.mjs') 2>&1
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

function script:Decode-EncodedCommand {
    param([Parameter(Mandatory)][string]$Arguments)
    $match = [regex]::Match($Arguments, '-EncodedCommand\s+(?<value>[A-Za-z0-9+/=]+)')
    if (-not $match.Success) { return $null }
    return [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($match.Groups['value'].Value))
}

function script:Get-LaunchGuiXaml {
    $launch = Get-Content -Path $scriptPath -Raw
    $match = [regex]::Match($launch, '(?s)\[xml\]\$xaml = @"\s*(<Window.*?</Window>)\s*"@')
    Assert-True ($match.Success) "Unable to locate the launcher XAML block."
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
        $decoded = Decode-EncodedCommand ($xml.SelectSingleNode('//t:Actions/t:Exec/t:Arguments', $ns).InnerText)
        $decoded | Should -Match '-RunLoop'
        $decoded | Should -Match '-SchedulerPolicy'
        $decoded | Should -Match 'IdleOnly'
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
    It 'forwards the scheduler policy into the detached launch arguments' {
        $script:SchedulerPolicy = 'Unattended'
        $script:ScheduleFrequency = 'Weekly'
        $script:ScheduleTime = 'Wednesday'
        $script:Provider = 'ollama'
        $script:Model = 'qwen2.5-coder:latest'
        $script:MaxLoopMinutes = 0
        $script:PerRunTimeoutMinutes = 10
        $plan = Get-TaskLauncherPlan
        $plan.InnerArgList | Should -Contain '-SchedulerPolicy'
        $plan.InnerArgList | Should -Contain 'Unattended'
        $plan.InnerArgList | Should -Contain '-RunLoop'
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
