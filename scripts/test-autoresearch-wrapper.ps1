#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

Write-Host "Checking PowerShell parser..."
$tokens = $null
$errors = $null
$launchPath = Join-Path $PSScriptRoot "launch.ps1"
$launchAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $launchPath,
    [ref]$tokens,
    [ref]$errors
)
Assert-True ($errors.Count -eq 0) "scripts/launch.ps1 has parser errors."

Write-Host "Checking launcher contract..."
$requiredParameters = @(
    @{ Name = "Provider"; Description = "AI provider selector" }
    @{ Name = "Model"; Description = "model selection" }
    @{ Name = "OllamaHost"; Description = "Ollama host URL" }
    @{ Name = "ApiKey"; Description = "provider credentials" }
    @{ Name = "AzureEndpoint"; Description = "Azure OpenAI endpoint" }
    @{ Name = "AzureDeployment"; Description = "Azure OpenAI deployment" }
    @{ Name = "RepoRoot"; Description = "repository root override" }
    @{ Name = "LogDir"; Description = "log directory override" }
    @{ Name = "ScheduleTime"; Description = "schedule slot" }
    @{ Name = "ScheduleFrequency"; Description = "schedule cadence" }
    @{ Name = "SchedulerPolicy"; Description = "scheduler policy" }
    @{ Name = "RegisterTask"; Description = "task registration switch" }
    @{ Name = "RunNow"; Description = "single-run execution switch" }
    @{ Name = "RunLoop"; Description = "looped execution switch" }
    @{ Name = "MaxLoopMinutes"; Description = "loop runtime limit" }
    @{ Name = "PerRunTimeoutMinutes"; Description = "per-run timeout" }
    @{ Name = "NoAiEdit"; Description = "skip AI edit switch" }
    @{ Name = "Unregister"; Description = "task removal switch" }
    @{ Name = "Update"; Description = "update switch" }
    @{ Name = "NoBootstrap"; Description = "bootstrap bypass switch" }
    @{ Name = "NoGui"; Description = "headless launcher switch" }
    @{ Name = "Debug"; Description = "debug logging switch" }
)
Assert-True ($null -ne $launchAst.ParamBlock) "scripts/launch.ps1 is missing a param block."
$parameterNames = @(
    $launchAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }
)
foreach ($required in $requiredParameters) {
    Assert-True ($parameterNames -contains $required.Name) "scripts/launch.ps1 is missing supported contract element: parameter '-$($required.Name)' ($($required.Description))."
}

$functionNames = @(
    $launchAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | ForEach-Object { $_.Name }
)
$requiredFunctions = @(
    @{ Name = "ConvertTo-WeekdayMask"; Description = "weekday mask helper" }
    @{ Name = "Get-ComputerIdleState"; Description = "idle-state helper" }
    @{ Name = "Get-PwshExePath"; Description = "PowerShell executable resolver" }
    @{ Name = "Get-ScheduleTriggerSpec"; Description = "schedule trigger spec helper" }
    @{ Name = "Get-ScheduleTimeOptions"; Description = "schedule time options helper" }
    @{ Name = "Get-ScheduleTimeDefault"; Description = "schedule time default helper" }
    @{ Name = "Get-SchedulerPolicyInfo"; Description = "scheduler policy metadata" }
    @{ Name = "Get-ScheduledTaskDescription"; Description = "scheduled task description helper" }
    @{ Name = "Get-TaskLauncherPlan"; Description = "task launcher plan helper" }
    @{ Name = "Get-TaskXml"; Description = "task XML builder" }
    @{ Name = "Get-TaskTrigger"; Description = "task trigger helper" }
    @{ Name = "Get-RegisteredLauncherTask"; Description = "registered task lookup" }
    @{ Name = "Enable-TaskHistoryLog"; Description = "task history toggle" }
    @{ Name = "Test-ScheduleTime"; Description = "schedule validation helper" }
    @{ Name = "Invoke-Bootstrap"; Description = "bootstrap handoff" }
    @{ Name = "Invoke-IdlePolicyGate"; Description = "idle gate enforcement" }
    @{ Name = "Invoke-Preflight"; Description = "preflight workflow" }
    @{ Name = "Invoke-Update"; Description = "update workflow" }
    @{ Name = "Invoke-Workload"; Description = "single-run workload" }
    @{ Name = "Invoke-AutoresearchLoop"; Description = "autoresearch loop" }
    @{ Name = "Register-LauncherTask"; Description = "scheduled task registration" }
    @{ Name = "Unregister-LauncherTask"; Description = "scheduled task removal" }
    @{ Name = "Write-Json"; Description = "structured JSON logging" }
    @{ Name = "Write-DebugLog"; Description = "debug logging" }
)
foreach ($required in $requiredFunctions) {
    Assert-True ($functionNames -contains $required.Name) "scripts/launch.ps1 is missing supported contract element: function '$($required.Name)' ($($required.Description))."
}

Write-Host "Checking relevant work markers..."
$workTokenOne = "TO" + "DO"
$workTokenTwo = "FIX" + "ME"
foreach ($path in @(
        (Join-Path $PSScriptRoot "launch.ps1"),
        (Join-Path $PSScriptRoot "test-autoresearch-wrapper.ps1"),
        (Join-Path $PSScriptRoot "test-autoresearch-acceptance.ps1"),
        (Join-Path $PSScriptRoot "verify-ai-provider.mjs"))) {
    $workMarkerHits = @(Select-String -Path $path -Pattern $workTokenOne, $workTokenTwo -SimpleMatch)
    Assert-True ($workMarkerHits.Count -eq 0) "$path contains unresolved work markers."
}

Write-Host "Checking provider exclusivity..."
Push-Location $RepoRoot
try {
    & node scripts/verify-ai-provider.mjs
    if ($LASTEXITCODE -ne 0) {
        throw "Provider verification failed."
    }
}
finally {
    Pop-Location
}

Write-Host "Wrapper validation passed."
