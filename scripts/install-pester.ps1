#Requires -Version 5.1
<#
.SYNOPSIS
    Ensures Pester 5.0.0 is installed for the current user.

.DESCRIPTION
    The PowerShell tests in this repository are run directly from
    tests/launch.Tests.ps1. That file calls this bootstrap script when the
    required Pester version is missing so contributors do not have to guess
    which shell family or module path needs to be primed first.

    Run the script from the same PowerShell host you plan to use for the
    tests:

      powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-pester.ps1
      pwsh       -NoProfile -ExecutionPolicy Bypass -File scripts/install-pester.ps1

    The script installs Pester 5.0.0 into the current user's module path and
    leaves the module ready for Import-Module by the test file.
#>

[CmdletBinding()]
param(
    [version]$RequiredVersion = [version]'5.0.0'
)

$ErrorActionPreference = 'Stop'

function Get-InstalledPesterVersions {
    @(Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | ForEach-Object { $_.Version })
}

function Format-PesterVersionList {
    param([version[]]$Versions)

    if ($Versions.Count -eq 0) {
        return 'none'
    }

    return ($Versions | ForEach-Object { $_.ToString() }) -join ', '
}

if ($PSVersionTable.PSEdition -eq 'Desktop') {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        # The install command still has a chance to succeed without this.
    }
}

$installed = Get-InstalledPesterVersions
if ($installed -contains $RequiredVersion) {
    return
}

try {
    Install-Module -Name Pester -Scope CurrentUser -RequiredVersion $RequiredVersion -Force -AllowClobber -SkipPublisherCheck -ErrorAction Stop
} catch {
    $available = Format-PesterVersionList (Get-InstalledPesterVersions)
    $message = @"
Pester $RequiredVersion is required to run the PowerShell tests.

Bootstrap could not install it.
Available Pester versions before bootstrap: $available

Run one of these commands, then rerun the test file with the same shell family:
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-pester.ps1
  pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/install-pester.ps1

If you need to install it manually:
  Install-Module Pester -Scope CurrentUser -RequiredVersion $RequiredVersion -Force -AllowClobber -SkipPublisherCheck

Underlying install error: $($_.Exception.Message)
"@
    throw $message
}

$installed = Get-InstalledPesterVersions
if ($installed -contains $RequiredVersion) {
    return
}

throw @"
Pester $RequiredVersion is still missing after bootstrap.
Available Pester versions: $(Format-PesterVersionList $installed)

Run:
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts/install-pester.ps1
or:
  pwsh -NoProfile -ExecutionPolicy Bypass -File scripts/install-pester.ps1
Then rerun:
  pwsh -NoProfile -File tests/launch.Tests.ps1
"@
