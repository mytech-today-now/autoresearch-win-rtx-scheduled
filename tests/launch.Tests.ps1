#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..\scripts\launch.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "launch.ps1 not found at $scriptPath"
    }

    # Extract only the helper function definitions from launch.ps1 so the
    # script's top-level main flow (preflight, GUI, task registration) does
    # not execute when the test file loads.
    $wanted = @(
        'Get-ScheduleTimeOptions',
        'Get-ScheduleTimeDefault',
        'Test-ScheduleTime',
        'Get-TaskTrigger'
    )
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath, [ref]$null, [ref]$null)
    $funcs = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | Where-Object { $wanted -contains $_.Name }
    foreach ($f in $funcs) {
        . ([scriptblock]::Create($f.Extent.Text))
    }

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
