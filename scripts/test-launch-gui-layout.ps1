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

function Get-LaunchGuiControl {
    param(
        [Parameter(Mandatory)][System.Windows.FrameworkElement]$Scope,
        [Parameter(Mandatory)][string]$Name
    )

    $control = $Scope.FindName($Name)
    Assert-True ($null -ne $control) "Missing launcher control '$Name'."
    return $control
}

function Get-LaunchGuiBounds {
    param(
        [Parameter(Mandatory)][System.Windows.FrameworkElement]$Element,
        [Parameter(Mandatory)][System.Windows.UIElement]$Ancestor
    )

    $origin = $Element.TranslatePoint([System.Windows.Point]::new(0, 0), $Ancestor)
    return [System.Windows.Rect]::new($origin.X, $origin.Y, $Element.ActualWidth, $Element.ActualHeight)
}

function Assert-LaunchGuiBoundsWithin {
    param(
        [Parameter(Mandatory)][System.Windows.Rect]$Bounds,
        [Parameter(Mandatory)][System.Windows.Rect]$Container,
        [Parameter(Mandatory)][string]$Message
    )

    $epsilon = 0.75
    Assert-True (
        $Bounds.Left -ge (-$epsilon) -and
        $Bounds.Top -ge (-$epsilon) -and
        $Bounds.Right -le ($Container.Right + $epsilon) -and
        $Bounds.Bottom -le ($Container.Bottom + $epsilon)
    ) $Message
}

function Assert-LaunchGuiLabeledControl {
    param(
        [Parameter(Mandatory)][System.Windows.FrameworkElement]$Scope,
        [Parameter(Mandatory)][string]$ControlName,
        [Parameter(Mandatory)][string]$LabelName,
        [Parameter(Mandatory)][string]$HelpText
    )

    $control = Get-LaunchGuiControl -Scope $Scope -Name $ControlName
    $label = Get-LaunchGuiControl -Scope $Scope -Name $LabelName
    $labeledBy = [System.Windows.Automation.AutomationProperties]::GetLabeledBy($control)
    Assert-True ([object]::ReferenceEquals($labeledBy, $label)) "$ControlName must be labeled by $LabelName."
    Assert-True ([System.Windows.Automation.AutomationProperties]::GetHelpText($control) -eq $HelpText) "$ControlName must expose the expected help text."
}

function Assert-LaunchGuiNamedControl {
    param(
        [Parameter(Mandatory)][System.Windows.FrameworkElement]$Scope,
        [Parameter(Mandatory)][string]$ControlName,
        [Parameter(Mandatory)][string]$ExpectedName,
        [Parameter(Mandatory)][string]$HelpText
    )

    $control = Get-LaunchGuiControl -Scope $Scope -Name $ControlName
    Assert-True ([System.Windows.Automation.AutomationProperties]::GetName($control) -eq $ExpectedName) "$ControlName must expose the expected automation name."
    Assert-True ([System.Windows.Automation.AutomationProperties]::GetHelpText($control) -eq $HelpText) "$ControlName must expose the expected help text."
}

function Save-LaunchGuiSnapshot {
    param(
        [Parameter(Mandatory)][System.Windows.Media.Imaging.BitmapSource]$Bitmap,
        [Parameter(Mandatory)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($env:CI_ARTIFACT_ROOT)) { return }

    $snapshotDir = Join-Path $env:CI_ARTIFACT_ROOT "launch-gui-layout"
    if (-not (Test-Path -LiteralPath $snapshotDir)) {
        New-Item -ItemType Directory -Path $snapshotDir -Force | Out-Null
    }

    $snapshotPath = Join-Path $snapshotDir "$Label.png"
    $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($Bitmap))
    $stream = [System.IO.FileStream]::new(
        $snapshotPath,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    try {
        $encoder.Save($stream)
    } finally {
        $stream.Dispose()
    }

    Write-Host "Saved launcher render snapshot: $snapshotPath"
}

function New-LaunchGuiBitmap {
    param(
        [Parameter(Mandatory)][System.Windows.Media.Visual]$Visual,
        [string]$Label
    )

    $width = [int][Math]::Ceiling($Visual.RenderSize.Width)
    $height = [int][Math]::Ceiling($Visual.RenderSize.Height)
    Assert-True ($width -gt 0 -and $height -gt 0) "Rendered launcher visual must have a non-zero size."

    $bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
        $width,
        $height,
        96,
        96,
        [System.Windows.Media.PixelFormats]::Pbgra32
    )
    $bitmap.Render($Visual)
    Assert-True ($bitmap.PixelWidth -eq $width -and $bitmap.PixelHeight -eq $height) "Rendered launcher bitmap size mismatch."

    if ($Label) {
        Save-LaunchGuiSnapshot -Bitmap $bitmap -Label $Label
    }

    return $bitmap
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

    Assert-LaunchGuiLabeledControl -Scope $window -ControlName 'CbModel' -LabelName 'LblModel' -HelpText 'Choose the model used by the selected provider.'
    Assert-LaunchGuiLabeledControl -Scope $window -ControlName 'CbHost' -LabelName 'LblHost' -HelpText 'Enter the Ollama base URL when Ollama is selected.'
    Assert-LaunchGuiLabeledControl -Scope $window -ControlName 'PbApiKey' -LabelName 'LblApiKey' -HelpText 'Enter the provider API key. It is used in memory only and is never persisted.'
    Assert-LaunchGuiLabeledControl -Scope $window -ControlName 'TxtAzEp' -LabelName 'LblAzEp' -HelpText 'Enter the Azure OpenAI endpoint URL.'
    Assert-LaunchGuiLabeledControl -Scope $window -ControlName 'TxtAzDp' -LabelName 'LblAzDp' -HelpText 'Enter the Azure OpenAI deployment name.'
    Assert-LaunchGuiLabeledControl -Scope $window -ControlName 'CbFreq' -LabelName 'LblFreq' -HelpText 'Choose how often the task runs. The time field below changes with this selection.'
    Assert-LaunchGuiLabeledControl -Scope $window -ControlName 'CbTime' -LabelName 'LblTime' -HelpText 'Choose the time, minute, or weekday value for the selected frequency.'
    Assert-LaunchGuiNamedControl -Scope $window -ControlName 'ChkHistory' -ExpectedName 'Enable Task Scheduler history' -HelpText 'Requires elevation to turn on the Task Scheduler Operational log.'
    Assert-LaunchGuiNamedControl -Scope $window -ControlName 'BtnDefaults' -ExpectedName 'Save as Defaults' -HelpText 'Save the current launcher selections without the API key.'
    Assert-LaunchGuiNamedControl -Scope $window -ControlName 'BtnCancel' -ExpectedName 'Cancel' -HelpText 'Close the launcher without saving changes.'
    Assert-LaunchGuiNamedControl -Scope $window -ControlName 'BtnOK' -ExpectedName 'OK' -HelpText 'Start with the current selections.'

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

function Test-LaunchGuiRenderedLayout {
    $window = New-LaunchGuiWindow
    $window.WindowStartupLocation = "Manual"
    $window.Left = -32000
    $window.Top = -32000
    $window.ShowActivated = $false
    $window.ShowInTaskbar = $false
    $window.Show()

    try {
        $window.UpdateLayout()

        $root = [System.Windows.Controls.Grid]$window.Content
        $scroll = @($root.Children | Where-Object { $_ -is [System.Windows.Controls.ScrollViewer] } | Select-Object -First 1)
        Assert-True ($scroll.Count -eq 1) "Launcher render smoke must include a ScrollViewer."
        $scroll = $scroll[0]

        $rootBounds = [System.Windows.Rect]::new(0, 0, $root.ActualWidth, $root.ActualHeight)
        $viewportBounds = [System.Windows.Rect]::new(0, 0, $scroll.ViewportWidth, $scroll.ViewportHeight)

        Assert-True ($rootBounds.Width -gt 0 -and $rootBounds.Height -gt 0) "Rendered launcher must have a client area."
        Assert-True ($viewportBounds.Width -gt 0 -and $viewportBounds.Height -gt 0) "Rendered launcher must have a usable scroll viewport."
        Assert-True ($scroll.ExtentWidth -le ($scroll.ViewportWidth + 0.75)) "Launcher body must not overflow horizontally in the runtime render."

        $buttonRow = @($root.Children | Where-Object { $_ -is [System.Windows.Controls.StackPanel] } | Select-Object -First 1)
        Assert-True ($buttonRow.Count -eq 1) "Launcher render smoke must keep the button row in the visual tree."
        $buttonBounds = Get-LaunchGuiBounds -Element $buttonRow[0] -Ancestor $root
        Assert-LaunchGuiBoundsWithin -Bounds $buttonBounds -Container $rootBounds -Message "Launcher buttons must stay visible when rendered."

        foreach ($name in 'BtnDefaults','BtnCancel','BtnOK') {
            $control = Get-LaunchGuiControl -Scope $window -Name $name
            Assert-True ($control.ActualWidth -gt 0 -and $control.ActualHeight -gt 0) "$name must render at a non-zero size."
        }

        $scroll.ScrollToVerticalOffset(0)
        $window.UpdateLayout()
        $null = New-LaunchGuiBitmap -Visual $root -Label "top"
        foreach ($name in 'ActRunNow','CbModel') {
            $control = Get-LaunchGuiControl -Scope $window -Name $name
            $bounds = Get-LaunchGuiBounds -Element $control -Ancestor $scroll
            Assert-LaunchGuiBoundsWithin -Bounds $bounds -Container $viewportBounds -Message "$name must stay readable in the top scroll position."
        }
        $cbHost = Get-LaunchGuiControl -Scope $window -Name 'CbHost'
        $cbHostBounds = Get-LaunchGuiBounds -Element $cbHost -Ancestor $scroll
        Assert-True ($cbHostBounds.Right -le ($viewportBounds.Right + 0.75)) "CbHost must not overflow horizontally in the top scroll position."

        $middleOffset = [Math]::Round($scroll.ScrollableHeight * 0.55, 1)
        $scroll.ScrollToVerticalOffset($middleOffset)
        $window.UpdateLayout()
        $null = New-LaunchGuiBitmap -Visual $root -Label "middle"
        foreach ($name in 'PbApiKey','PolInteractive','TxtPolicySummary') {
            $control = Get-LaunchGuiControl -Scope $window -Name $name
            $bounds = Get-LaunchGuiBounds -Element $control -Ancestor $scroll
            Assert-LaunchGuiBoundsWithin -Bounds $bounds -Container $viewportBounds -Message "$name must stay readable in the middle scroll position."
        }

        $scroll.ScrollToVerticalOffset($scroll.ScrollableHeight)
        $window.UpdateLayout()
        $null = New-LaunchGuiBitmap -Visual $root -Label "bottom"
        foreach ($name in 'CbFreq','CbTime','ChkHistory') {
            $control = Get-LaunchGuiControl -Scope $window -Name $name
            $bounds = Get-LaunchGuiBounds -Element $control -Ancestor $scroll
            Assert-LaunchGuiBoundsWithin -Bounds $bounds -Container $viewportBounds -Message "$name must stay readable in the bottom scroll position."
        }
        $buttonBounds = Get-LaunchGuiBounds -Element $buttonRow[0] -Ancestor $root
        Assert-LaunchGuiBoundsWithin -Bounds $buttonBounds -Container $rootBounds -Message "Launcher buttons must stay visible after scrolling to the bottom."
    } finally {
        $window.Close()
    }
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
Test-LaunchGuiRenderedLayout

Write-Host "Launcher GUI layout and accessibility smoke passed."
