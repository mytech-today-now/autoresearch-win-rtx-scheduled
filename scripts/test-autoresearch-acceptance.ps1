#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$script:RequiredPesterVersion = [version]'5.0.0'
$HarnessRoot = Split-Path -Parent $PSScriptRoot
$LaunchPath = Join-Path $PSScriptRoot "launch.ps1"
$PreviousDotSourceOnly = $env:AUTORESEARCH_DOT_SOURCE_ONLY
$env:AUTORESEARCH_DOT_SOURCE_ONLY = "1"
. $LaunchPath

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function New-TestRoot {
    param([string]$Name)
    $path = Join-Path $env:TEMP ("autoresearch-$Name-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function New-DirectoryIfMissing {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-ProviderVerificationFixture {
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

function Invoke-LauncherForTest {
    param(
        [string[]]$Arguments,
        [hashtable]$Environment = @{},
        [string]$ScriptPath = $LaunchPath
    )
    if (-not $Environment.ContainsKey("AUTORESEARCH_DOT_SOURCE_ONLY")) {
        $Environment["AUTORESEARCH_DOT_SOURCE_ONLY"] = "0"
    }
    $previous = @{}
    foreach ($key in $Environment.Keys) {
        $previous[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
        [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], "Process")
    }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output) }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        foreach ($key in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($key, $previous[$key], "Process")
        }
    }
}

function Invoke-ProviderVerificationForTest {
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

function ConvertTo-SingleQuotedLiteral {
    param([Parameter(Mandatory)][string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

function New-FakeGitCommand {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$LogPath,
        [switch]$DirtyStatus
    )
    $bin = Join-Path $Root "bin"
    New-Item -ItemType Directory -Path $bin -Force | Out-Null
    $statusEcho = if ($DirtyStatus) { "echo  M tracked.txt`r`necho ?? untracked.sentinel" } else { 'echo.' }
    $content = @"
@echo off
setlocal
echo %*>>"$LogPath"
if /i "%1"=="clone" exit /b 81
echo %* | findstr /i "status" >nul
if not errorlevel 1 (
    $statusEcho
)
exit /b 0
"@
    Set-Content -LiteralPath (Join-Path $bin "git.cmd") -Value $content -Encoding ASCII
    return $bin
}

function Invoke-LauncherDotSourceForTest {
    param(
        [string[]]$Arguments,
        [hashtable]$Environment = @{},
        [string]$ScriptPath = $LaunchPath
    )
    if (-not $Environment.ContainsKey("AUTORESEARCH_DOT_SOURCE_ONLY")) {
        $Environment["AUTORESEARCH_DOT_SOURCE_ONLY"] = "1"
    }
    $previous = @{}
    foreach ($key in $Environment.Keys) {
        $previous[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
        [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], "Process")
    }
    try {
        $quotedArgs = @()
        foreach ($arg in $Arguments) {
            $quotedArgs += (ConvertTo-SingleQuotedLiteral $arg)
        }
        $argText = if ($quotedArgs.Count -gt 0) { ' ' + ($quotedArgs -join ' ') } else { '' }
        $command = @"
`$ErrorActionPreference = 'Stop'
. $(ConvertTo-SingleQuotedLiteral $ScriptPath)$argText
if (-not (Get-Command Invoke-Bootstrap -ErrorAction SilentlyContinue)) {
    throw 'Invoke-Bootstrap was not loaded.'
}
"@
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -Command $command 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output) }
    }
    finally {
        foreach ($key in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($key, $previous[$key], "Process")
        }
    }
}

function Test-ProviderAndManifests {
    Write-Host "Acceptance: provider manifests"
    $package = Get-Content -LiteralPath (Join-Path $HarnessRoot "package.json") -Raw | ConvertFrom-Json
    $lockText = Get-Content -LiteralPath (Join-Path $HarnessRoot "package-lock.json") -Raw
    Assert-True (-not [string]::IsNullOrWhiteSpace($package.dependencies."ai-powered")) "package.json must include ai-powered."
    Assert-True ($lockText.Contains('"":') -and $lockText.Contains('"ai-powered"')) "package-lock.json must include ai-powered at the root."
    Push-Location $HarnessRoot
    try {
        & node scripts/verify-ai-provider.mjs
        Assert-True ($LASTEXITCODE -eq 0) "Provider verification failed."
    }
    finally { Pop-Location }
}

function Test-ImportOnlyBootstrapBoundary {
    Write-Host "Acceptance: import-only bootstrap boundary"
    $root = New-TestRoot "import-only-bootstrap"
    $fakeGitLog = Join-Path $root "git-invocations.log"
    $fakeGitBin = New-FakeGitCommand -Root $root -LogPath $fakeGitLog
    $checkout = Join-Path $root "checkout"
    New-DirectoryIfMissing $checkout
    $scriptCopy = Join-Path $checkout "launch.ps1"
    Copy-Item -LiteralPath $LaunchPath -Destination $scriptCopy
    $result = Invoke-LauncherDotSourceForTest -Environment @{ PATH = "$fakeGitBin;$env:PATH" } -ScriptPath $scriptCopy
    Assert-True ($result.ExitCode -eq 0) "Import-only dot-source should succeed."
    Assert-True (-not (Test-Path -LiteralPath $fakeGitLog)) "Import-only dot-source must not invoke git."
}

function Test-DirtyCanonicalBootstrapRefusal {
    Write-Host "Acceptance: dirty canonical bootstrap refusal"
    $root = New-TestRoot "dirty-canonical"
    $fakeGitLog = Join-Path $root "git-invocations.log"
    $fakeGitBin = New-FakeGitCommand -Root $root -LogPath $fakeGitLog -DirtyStatus
    # The launcher uses this fixed canonical directory name in every checkout.
    $repoName = 'autoresearch-win-rtx-scheduled'
    $canonicalRepo = Join-Path (Join-Path $root "myTech.Today") $repoName
    New-DirectoryIfMissing $canonicalRepo
    New-DirectoryIfMissing (Join-Path $canonicalRepo ".git")
    $trackedSentinel = Join-Path $canonicalRepo "tracked.txt"
    $untrackedSentinel = Join-Path $canonicalRepo "untracked.sentinel"
    $ignoredSentinel = Join-Path $canonicalRepo "ignored.sentinel"
    Set-Content -LiteralPath $trackedSentinel -Value "tracked user edit" -Encoding ASCII
    Set-Content -LiteralPath $untrackedSentinel -Value "untracked user data" -Encoding ASCII
    Set-Content -LiteralPath $ignoredSentinel -Value "ignored user data" -Encoding ASCII
    $checkout = Join-Path $root "checkout"
    New-DirectoryIfMissing $checkout
    $scriptCopy = Join-Path $checkout "launch.ps1"
    Copy-Item -LiteralPath $LaunchPath -Destination $scriptCopy
    $envMap = @{
        HOMEDRIVE = $root
        PATH      = "$fakeGitBin;$env:PATH"
    }
    $result = Invoke-LauncherForTest -Arguments @("-NoGui") -Environment $envMap -ScriptPath $scriptCopy
    Assert-True ($result.ExitCode -ne 0) "Dirty canonical install should be refused."
    Assert-True ((Get-Content -LiteralPath $trackedSentinel -Raw) -eq "tracked user edit`r`n") "Tracked user edit was not preserved."
    Assert-True ((Get-Content -LiteralPath $untrackedSentinel -Raw) -eq "untracked user data`r`n") "Untracked user data was not preserved."
    Assert-True ((Get-Content -LiteralPath $ignoredSentinel -Raw) -eq "ignored user data`r`n") "Ignored user data was not preserved."
    $output = $result.Output -join "`n"
    Assert-True ($output -match '(?s)Refusing to bootstrap canonical install at .*because it has local changes') "Refusal message missing."
    Assert-True ($output -match 'tracked.txt') "Tracked status entry missing."
    Assert-True ($output -match 'untracked.sentinel') "Untracked status entry missing."
    $logText = if (Test-Path -LiteralPath $fakeGitLog) { Get-Content -LiteralPath $fakeGitLog -Raw } else { '' }
    Assert-True ($logText -match '\bstatus\b') "Bootstrap safety check did not query git status."
    Assert-True ($logText -notmatch '\bpull\b') "Dirty install must not pull."
    Assert-True ($logText -notmatch '\bclone\b') "Dirty install must not clone."
}

function Test-ProviderVerificationFixtures {
    Write-Host "Acceptance: provider verification fixtures"

    $launcherRoot = New-TestRoot "provider-launcher"
    Write-ProviderVerificationFixture -Root $launcherRoot
    Set-Content -LiteralPath (Join-Path $launcherRoot "scripts\launch.ps1") -Value @'
param([string]$ApiKey)
if ($ApiKey) {
    [Environment]::SetEnvironmentVariable('OPENAI_API_KEY', $ApiKey, 'Process')
    [Environment]::SetEnvironmentVariable('ANTHROPIC_API_KEY', $ApiKey, 'Process')
    [Environment]::SetEnvironmentVariable('AZURE_OPENAI_API_KEY', $ApiKey, 'Process')
}
'@ -Encoding ASCII
    $launcherResult = Invoke-ProviderVerificationForTest -Root $launcherRoot
    Assert-True ($launcherResult.ExitCode -eq 0) "Launcher env forwarding should pass verification."
    Assert-True (($launcherResult.Output -join "`n") -match 'Provider verification passed') "Launcher verification should report success."

    $directRoot = New-TestRoot "provider-direct"
    Write-ProviderVerificationFixture -Root $directRoot
    $providerPackage = "open" + "ai"
    Set-Content -LiteralPath (Join-Path $directRoot "src\sample.mjs") -Value @"
import OpenAI from "$providerPackage";
export const client = new OpenAI({ apiKey: process.env.OPENAI_API_KEY });
"@ -Encoding ASCII
    $directResult = Invoke-ProviderVerificationForTest -Root $directRoot
    Assert-True ($directResult.ExitCode -ne 0) "Direct provider imports must fail verification."
    Assert-True (($directResult.Output -join "`n") -match 'disallowed direct provider usage') "Direct provider failure message missing."

    $copyRoot = New-TestRoot "provider-launch-copy"
    Write-ProviderVerificationFixture -Root $copyRoot
    $providerPackage = "open" + "ai"
    Set-Content -LiteralPath (Join-Path $copyRoot "scripts\launch copy 2.ps1") -Value @"
# import OpenAI from "$providerPackage";
"@ -Encoding ASCII
    $copyResult = Invoke-ProviderVerificationForTest -Root $copyRoot
    Assert-True ($copyResult.ExitCode -ne 0) "Copied launchers must be scanned for direct provider usage."
    Assert-True (($copyResult.Output -join "`n") -match 'disallowed direct provider usage') "Copied launcher failure message missing."

    $pythonRoot = New-TestRoot "provider-python"
    Write-ProviderVerificationFixture -Root $pythonRoot
    Set-Content -LiteralPath (Join-Path $pythonRoot "train.py") -Value @'
provider_name = "openai"
'@ -Encoding ASCII
    $pythonResult = Invoke-ProviderVerificationForTest -Root $pythonRoot
    Assert-True ($pythonResult.ExitCode -ne 0) "Python provider literals must fail verification."
    Assert-True (($pythonResult.Output -join "`n") -match 'disallowed direct provider usage') "Python provider failure message missing."

    $envRoot = New-TestRoot "provider-env"
    Write-ProviderVerificationFixture -Root $envRoot
    Set-Content -LiteralPath (Join-Path $envRoot ".env") -Value @'
OPENAI_API_KEY=local-secret
ANTHROPIC_API_KEY=local-secret
AZURE_OPENAI_API_KEY=local-secret
'@ -Encoding ASCII
    $envResult = Invoke-ProviderVerificationForTest -Root $envRoot
    Assert-True ($envResult.ExitCode -eq 0) "Local .env files should not fail verification."
    Assert-True (($envResult.Output -join "`n") -match 'Provider verification passed') "Local .env verification should report success."
}

function Test-LaunchGuiPolicyLayout {
    Write-Host "Acceptance: launcher GUI policy layout"
    $guiTestPath = Join-Path $PSScriptRoot "test-launch-gui-layout.ps1"
    Assert-True (Test-Path -LiteralPath $guiTestPath) "GUI layout smoke test is missing."
    & $guiTestPath
}

function Test-LaunchPesterSuite {
    Write-Host "Acceptance: launch.ps1 Pester suite"
    $pesterPath = Join-Path $HarnessRoot "tests\launch.Tests.ps1"
    Assert-True (Test-Path -LiteralPath $pesterPath) "launch.Tests.ps1 is missing."
    Import-Module Pester -RequiredVersion $script:RequiredPesterVersion -ErrorAction Stop
    $result = Invoke-Pester -Path $pesterPath -PassThru
    Assert-True ($result.FailedCount -eq 0) "launch.Tests.ps1 reported failing tests."
}

function Get-AcceptanceScenarioNames {
    return @(
        'Test-ProviderAndManifests'
        'Test-ProviderVerificationFixtures'
        'Test-ImportOnlyBootstrapBoundary'
        'Test-DirtyCanonicalBootstrapRefusal'
        'Test-LaunchPesterSuite'
        'Test-LaunchGuiPolicyLayout'
    )
}

function Assert-AcceptanceScenarioCoverage {
    param([Parameter(Mandatory)][string[]]$ScenarioNames)

    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    Assert-True (-not [string]::IsNullOrWhiteSpace($scriptPath)) "Unable to resolve the acceptance harness path."

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) "Acceptance harness has parser errors."
    $scriptText = Get-Content -LiteralPath $scriptPath -Raw
    # Build the stale identity at runtime so this guard does not match itself.
    $staleRepoIdentity = @('autoresearch', 'karpathy') -join '-'
    Assert-True ($scriptText -notmatch [regex]::Escape($staleRepoIdentity)) "Acceptance harness still contains stale repo identity strings."

    $definedScenarios = @(
        $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -like 'Test-*'
        }, $true) | ForEach-Object { $_.Name }
    )
    $missingFromRunner = @($definedScenarios | Where-Object { $_ -notin $ScenarioNames })
    $missingDefinitions = @($ScenarioNames | Where-Object { $_ -notin $definedScenarios })

    Assert-True ($missingFromRunner.Count -eq 0) "Acceptance harness defines scenario function(s) that are not reachable from the main entry point: $($missingFromRunner -join ', ')."
    Assert-True ($missingDefinitions.Count -eq 0) "Acceptance harness lists scenario function(s) that are not defined: $($missingDefinitions -join ', ')."
}

try {
    $scenarios = @(Get-AcceptanceScenarioNames)
    Assert-AcceptanceScenarioCoverage -ScenarioNames $scenarios
    foreach ($scenario in $scenarios) {
        & $scenario
    }
    Write-Host "Acceptance validation passed."
}
finally {
    $env:AUTORESEARCH_DOT_SOURCE_ONLY = $PreviousDotSourceOnly
}
