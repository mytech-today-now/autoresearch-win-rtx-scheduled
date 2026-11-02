#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('RunLoop', 'Abandon')][string]$Mode = 'RunLoop',
    [Parameter(Mandatory)][string]$LaunchScriptPath,
    [Parameter(Mandatory)][string]$RepoRootPath,
    [Parameter(Mandatory)][string]$LogDirPath,
    [Parameter(Mandatory)][string]$RunId,
    [Parameter(Mandatory)][string]$AiCallsPath,
    [Parameter(Mandatory)][string]$GitMutationsPath,
    [Parameter(Mandatory)][string]$ResultsPath,
    [Parameter(Mandatory)][string]$ReadyPath,
    [Parameter(Mandatory)][string]$ReleasePath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Script:RepoRoot = $RepoRootPath
$Script:AutoresearchLoopLock = $null
$Script:LogDir = $LogDirPath
$Script:RunLogPath = $null

$wanted = @(
    'Invoke-Git',
    'Get-AutoresearchLoopLockIdentity',
    'Read-AutoresearchLoopLockOwner',
    'Format-AutoresearchLoopLockBusyMessage',
    'Enter-AutoresearchLoopLock',
    'Exit-AutoresearchLoopLock',
    'Invoke-AutoresearchLoop'
)
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $LaunchScriptPath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "Could not parse launcher source for the loop worker: $($parseErrors[0].Message)"
}
$definitions = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $node.Name
}, $true))
foreach ($name in $wanted) {
    if (-not ($definitions | Where-Object { $_.Name -ceq $name })) {
        throw "Launcher function '$name' was not found for the loop worker."
    }
}
foreach ($definition in $definitions) {
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Write-Json {
    param([string]$Level, [string]$Message, [hashtable]$Extra = $null)
    if ($Message -like '*stale autoresearch repository lock owner*') {
        $previousPid = if ($null -ne $Extra) { $Extra.staleOwnerProcessId } else { $null }
        [Console]::Out.WriteLine("STALE_OWNER_PID=$previousPid")
    }
}

if ($Mode -eq 'Abandon') {
    $lock = Enter-AutoresearchLoopLock -RepoRootPath $RepoRootPath
    if (-not $lock.Acquired) { exit 2 }
    [Console]::Out.WriteLine("ABANDONED_PID=$PID")
    [Console]::Out.Flush()
    [Environment]::Exit(86)
}

function Invoke-AutoresearchLoopCore {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $Script:RunLogPath = Join-Path $LogDirPath 'run.log'
    New-Item -ItemType File -Path $Script:RunLogPath -Force | Out-Null

    $startRecord = [pscustomobject]@{
        ownerId  = $RunId
        ownerPid = [int]$PID
        phase    = 'edit-started'
    }
    [System.IO.File]::WriteAllText(
        $Script:RunLogPath,
        (($startRecord | ConvertTo-Json -Compress) + [Environment]::NewLine),
        $utf8
    )
    [System.IO.File]::AppendAllText($AiCallsPath, "$RunId|$PID$([Environment]::NewLine)", $utf8)
    [System.IO.File]::WriteAllText($ReadyPath, "$RunId|$PID", $utf8)

    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not [System.IO.File]::Exists($ReleasePath)) {
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Test loop $RunId timed out at its edit barrier."
        }
        Start-Sleep -Milliseconds 25
    }

    $branch = "autoresearch/lock-test-$RunId"
    $gitOutput = & git -C $RepoRootPath branch $branch 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "Temporary fixture Git mutation failed for ${RunId}: $($gitOutput.Trim())"
    }
    [System.IO.File]::AppendAllText($GitMutationsPath, "$RunId|branch|$PID$([Environment]::NewLine)", $utf8)
    [System.IO.File]::AppendAllText(
        $ResultsPath,
        "$RunId`t0.100000`t1.0`tkeep`t$RunId$([Environment]::NewLine)",
        $utf8
    )

    $finishRecord = [pscustomobject]@{
        ownerId  = $RunId
        ownerPid = [int]$PID
        phase    = 'loop-finished'
    }
    [System.IO.File]::AppendAllText(
        $Script:RunLogPath,
        (($finishRecord | ConvertTo-Json -Compress) + [Environment]::NewLine),
        $utf8
    )
    return 0
}

$loopResult = Invoke-AutoresearchLoop
[Console]::Out.WriteLine("LOOP_RESULT=$loopResult")
exit ([int]$loopResult)
