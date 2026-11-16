# Test: console-window flicker detection
#
# Sample desktop windows for tasklist/taskkill/cmd/conhost flashes.
# The tray polls with tasklist every 5s; without CREATE_NO_WINDOW
# Chinese Windows flashes a black console window periodically.
#
#   powershell -ExecutionPolicy Bypass -File .\test\test-no-flicker.ps1
#   powershell -ExecutionPolicy Bypass -File .\test\test-no-flicker.ps1 -Seconds 20

[CmdletBinding()]
param([int]$Seconds = 15)

Write-Host "`n== Console flicker check (${Seconds}s) ==`n" -ForegroundColor Cyan
Write-Host "Sampling every 500ms for tasklist/taskkill/cmd/conhost/SYSTEM32 windows.`n" -ForegroundColor Gray

$found = 0
$samples = $Seconds * 2
for ($i = 0; $i -lt $samples; $i++) {
    $windows = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.MainWindowHandle -ne 0 -and
        $_.MainWindowTitle -match 'tasklist|taskkill|cmd\.exe|conhost|SYSTEM32'
    }
    foreach ($w in $windows) {
        $found++
        Write-Host "  caught: $($w.ProcessName) | $($w.MainWindowTitle)" -ForegroundColor Yellow
    }
    Start-Sleep -Milliseconds 500
}

Write-Host ""
if ($found -eq 0) {
    Write-Host "Result: no console window in ${Seconds}s, OK.`n" -ForegroundColor Green
    exit 0
} else {
    Write-Host "Result: caught $found console-window flashes." -ForegroundColor Red
    Write-Host "Check: _run_hidden() in tray.py/webui.py must pass CREATE_NO_WINDOW.`n" -ForegroundColor Yellow
    exit 1
}
