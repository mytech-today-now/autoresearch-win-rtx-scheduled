#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Get-LaunchGuiXaml {
    $launch = Get-Content -Path (Join-Path $PSScriptRoot "launch.ps1") -Raw
    $match = [regex]::Match($launch, '(?s)\[xml\]\$xaml = @"\s*(<Window.*?</Window>)\s*"@')
    Assert-True ($match.Success) "Unable to locate the launcher XAML block."
    return $match.Groups[1].Value
}

function New-LaunchGuiWindow {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $reader = New-Object System.Xml.XmlNodeReader ([xml](Get-LaunchGuiXaml))
    return [Windows.Markup.XamlReader]::Load($reader)
}

function Test-LaunchGuiLayout {
    $window = New-LaunchGuiWindow
    Assert-True ([string]$window.ResizeMode -eq "CanResize") "Launcher window must be resizable."
    Assert-True ([string]$window.SizeToContent -eq "Manual") "Launcher window must not size to content."
    Assert-True ($window.MinWidth -ge 600) "Launcher window needs a minimum width."
    Assert-True ($window.MinHeight -ge 320) "Launcher window needs a minimum height."

    $root = [System.Windows.Controls.Grid]$window.Content
    Assert-True ($root.RowDefinitions.Count -eq 2) "Launcher root must reserve a bottom row for buttons."
    Assert-True ($root.Children.Count -eq 2) "Launcher root must contain the scrollable body and button row."

    $scroll = @($root.Children | Where-Object { $_ -is [System.Windows.Controls.ScrollViewer] } | Select-Object -First 1)
    Assert-True ($scroll.Count -eq 1) "Launcher body must be wrapped in a ScrollViewer."
    $scroll = $scroll[0]
    Assert-True ([string]$scroll.VerticalScrollBarVisibility -eq "Auto") "Launcher body must scroll vertically."
    Assert-True ([string]$scroll.HorizontalScrollBarVisibility -eq "Disabled") "Launcher body must not scroll horizontally."

    $expectedTabOrder = @(
        "ActPreflight","ActRunNow","ActRegister","ActRegisterRun","ActUnregister","ActUpdate",
        "PrvOllama","PrvOpenAI","PrvAnthropic","PrvAzure",
        "CbModel","CbHost","PbApiKey","TxtAzEp","TxtAzDp",
        "PolInteractive","PolIdleOnly","PolUnattended",
        "CbFreq","CbTime","ChkHistory",
        "BtnDefaults","BtnCancel","BtnOK"
    )
    for ($i = 0; $i -lt $expectedTabOrder.Count; $i++) {
        $control = $window.FindName($expectedTabOrder[$i])
        Assert-True ($null -ne $control) "Missing control $($expectedTabOrder[$i])."
        Assert-True ($control.TabIndex -eq $i) "Tab order mismatch for $($expectedTabOrder[$i])."
    }

    foreach ($name in @("CbModel","CbHost","PbApiKey","TxtAzEp","TxtAzDp","CbFreq","CbTime")) {
        $control = $window.FindName($name)
        Assert-True ([string]$control.HorizontalAlignment -eq "Stretch") "$name must stretch horizontally."
    }
    Assert-True ($window.FindName("LblTime").GetType().Name -eq "TextBlock") "LblTime must be a wrapping text block."
    Assert-True ([string]$window.FindName("LblTime").TextWrapping -eq "Wrap") "LblTime must wrap."
    Assert-True ($window.FindName("LblAzEp").GetType().Name -eq "TextBlock") "LblAzEp must be a wrapping text block."
    Assert-True ($window.FindName("LblAzDp").GetType().Name -eq "TextBlock") "LblAzDp must be a wrapping text block."
    Assert-True ($window.FindName("TxtPolicySummary").GetType().Name -eq "TextBlock") "Policy summary must be a text block."
    Assert-True ([string]$window.FindName("TxtPolicySummary").TextWrapping -eq "Wrap") "Policy summary must wrap."
    Assert-True ($window.FindName("PrvOllama").Parent.GetType().Name -eq "WrapPanel") "Provider choices must wrap."
    Assert-True ($window.FindName("BtnCancel").IsCancel) "Cancel button must handle Esc."
    Assert-True ($window.FindName("BtnOK").IsDefault) "OK button must remain the default action."
}

function Test-LaunchWindowBounds {
    $launch = Get-Content -Path (Join-Path $PSScriptRoot "launch.ps1") -Raw
    Assert-True ($launch.Contains('$window.MaxWidth = [SystemParameters]::WorkArea.Width')) "Launcher must cap width to the work area."
    Assert-True ($launch.Contains('$window.MaxHeight = [SystemParameters]::WorkArea.Height')) "Launcher must cap height to the work area."
    Assert-True ($launch.Contains('KeyboardNavigation.TabNavigation="Cycle"')) "Launcher must keep tab navigation cycling within the dialog."
    Assert-True ($launch.Contains('KeyboardNavigation.DirectionalNavigation="Contained"')) "Launcher must keep directional navigation contained."
    Assert-True ($launch.Contains('ActRunNow.Focus()')) "Launcher must set initial keyboard focus to the primary action."
}

Write-Host "Checking PowerShell parser..."
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot "launch.ps1"),
    [ref]$tokens,
    [ref]$errors
) | Out-Null
Assert-True ($errors.Count -eq 0) "scripts/launch.ps1 has parser errors."

Write-Host "Checking launcher GUI layout..."
Test-LaunchGuiLayout
Test-LaunchWindowBounds

Write-Host "Launcher GUI layout smoke passed."
