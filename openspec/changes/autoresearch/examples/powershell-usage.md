# PowerShell Usage Examples

These examples define the expected user-facing launcher flows. The implementation must keep paths quoted and must support paths containing spaces.

## Normal Launch

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\myTech.Today\autoresearch-karpathy\scripts\launch.ps1"
```

## Launch With Runtime Overrides

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\myTech.Today\autoresearch-karpathy\scripts\launch.ps1" -MaxRuntimeMinutes 5 -MaxRuntimePerHourMinutes 5
```

## Update Wrapper and Upstream Clone

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\myTech.Today\autoresearch-karpathy\scripts\launch.ps1" -Update
```

## Remove Scheduled Task and Shortcut

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\myTech.Today\autoresearch-karpathy\scripts\launch.ps1" -Remove
```

## Print Version Information

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\myTech.Today\autoresearch-karpathy\scripts\launch.ps1" -Version
```

## Enable Debug Logging

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\myTech.Today\autoresearch-karpathy\scripts\launch.ps1" -Debug
```

## Bootstrap Without Manual Download

Replace `<owner>` and `<repo>` with the public wrapper repository before publishing this command.

```powershell
$script = Invoke-RestMethod -Uri "https://raw.githubusercontent.com/<owner>/<repo>/main/scripts/launch.ps1"
$temp = Join-Path $env:TEMP "autoresearch-launch.ps1"
Set-Content -Path $temp -Value $script -Encoding UTF8
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $temp
```