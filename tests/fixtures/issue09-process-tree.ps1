param(
    [Parameter(Mandatory)][ValidateSet('root','child','grandchild','short')][string]$Role,
    [Parameter(Mandatory)][string]$MarkerPath,
    [Parameter(Mandatory)][string]$RuntimePath,
    [string]$OutputPath,
    [string]$ErrorPath,
    [string]$Score = '0.123456'
)

[System.IO.File]::AppendAllText($MarkerPath, ("{0},{1}" -f $Role, $PID) + [Environment]::NewLine)

if ($Role -in @('root','short')) {
    [System.IO.File]::AppendAllText($OutputPath, ("val_bpb: {0}`r`n" -f $Score))
    $peakVramMb = if ($Role -eq 'short') { 1536 } else { 2048 }
    [System.IO.File]::AppendAllText($ErrorPath, ("peak_vram_mb: {0}`r`n" -f $peakVramMb))
}

if ($Role -eq 'short') { exit 0 }

if ($Role -eq 'root' -or $Role -eq 'child') {
    $nextRole = if ($Role -eq 'root') { 'child' } else { 'grandchild' }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Role ' + $nextRole +
        ' -MarkerPath "' + $MarkerPath + '" -RuntimePath "' + $RuntimePath + '"'
    [void](Start-Process -FilePath $RuntimePath -ArgumentList $arguments -PassThru -WindowStyle Hidden)
}

while ($true) { Start-Sleep -Seconds 1 }
