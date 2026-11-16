# Test: tray and logon autostart
#
# Verify the tray starts from any cwd (simulated logon), brings up
# bridge and WebUI, and writes a PID file matching the port owner.
#
# Note: this stops and restarts the tray; bridge config is unchanged.
#
#   powershell -ExecutionPolicy Bypass -File .\test\test-tray.ps1

[CmdletBinding()]
param(
    [string]$TrayDir = 'C:\Users\Administrator\.zcode\workspace\draft-c9b55466-d599-41e8-a0f9-1e2e853b591d\_bridge\api2codex',
    [string]$Pythonw = 'C:\Users\Administrator\AppData\Local\Programs\Python\Python312\pythonw.exe',
    [int]$WaitSec = 25
)

$ErrorActionPreference = 'Stop'
function Ok($m)   { Write-Host "  [PASS] $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }
function Info($m) { Write-Host "         $m" -ForegroundColor Gray }
$script:fail = 0

Write-Host "`n== Tray and autostart test ==`n" -ForegroundColor Cyan

$trayScript = Join-Path $TrayDir 'tray.py'
$pidFile = Join-Path $TrayDir '.bridge.pid'

if (-not (Test-Path $trayScript)) { Bad "tray script not found: $trayScript"; exit 1 }
if (-not (Test-Path $Pythonw))    { Bad "pythonw not found: $Pythonw"; exit 1 }

# 1. Stop existing tray
Write-Host "1. Stop existing tray"
Get-CimInstance Win32_Process -Filter "Name like '%python%'" |
  Where-Object { $_.CommandLine -like '*tray.py*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
Ok "cleaned"

# 2. Launch from C:\ (simulate logon cwd)
Write-Host "2. Launch tray from C:\"
Start-Process -FilePath $Pythonw -ArgumentList @($trayScript) -WorkingDirectory 'C:\' -WindowStyle Hidden
Start-Sleep -Seconds $WaitSec
$trayProcs = @(Get-CimInstance Win32_Process -Filter "Name like '%python%'" |
               Where-Object { $_.CommandLine -like '*tray.py*' })
if ($trayProcs.Count -ge 1) { Ok "tray alive (PID $($trayProcs[0].ProcessId))" }
else { Bad "tray did not start"; exit 1 }

# 3. PID file
Write-Host "3. PID file"
if (-not (Test-Path $pidFile)) { Bad "PID file missing: $pidFile" }
else {
    $pid = [int](Get-Content $pidFile -Raw).Trim()
    $conn = Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue
    if ($conn -and $conn.OwningProcess -eq $pid) { Ok "PID $pid matches port 8787 owner" }
    else { Bad "PID mismatch: file=$pid port=$($conn.OwningProcess)" }
}

# 4. Ports
Write-Host "4. Service ports"
foreach ($p in @(8787, 8789)) {
    if (Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue) { Ok "port $p listening" }
    else { Bad "port $p not listening" }
}

# 5. WebUI bridge restart
Write-Host "5. WebUI bridge restart"
$oldPid = [int](Get-Content $pidFile -Raw).Trim()
try {
    $r = Invoke-RestMethod -Uri 'http://127.0.0.1:8789/api/restart' -Method Post -TimeoutSec 90
    Start-Sleep -Seconds 8
    $newPid = [int](Get-Content $pidFile -Raw).Trim()
    if ($newPid -ne $oldPid -and $r.running) { Ok "restart ok: $oldPid -> $newPid" }
    else { Bad "restart abnormal: $oldPid -> $newPid running=$($r.running)" }
} catch { Bad "restart request failed: $($_.Exception.Message)" }

# 6. Autostart registry
Write-Host "6. Autostart entry"
try {
    $run = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction Stop).CodexBridgeTray
    if ($run -match 'pythonw.exe' -and $run -match 'tray.py') { Ok "registry entry present: $run" }
    else { Bad "registry entry unexpected: $run" }
} catch { Bad "registry entry missing" }

Write-Host ""
if ($script:fail -eq 0) { Write-Host "Result: all passed`n" -ForegroundColor Green; exit 0 }
else { Write-Host "Result: $script:fail failed`n" -ForegroundColor Red; exit 1 }
