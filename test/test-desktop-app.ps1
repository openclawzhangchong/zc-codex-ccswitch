# Test: official ChatGPT/Codex desktop app detection
#
# Verifies:
#   1. the Store package OpenAI.Codex is installed
#   2. the app process can run (or at least the package exists)
#   3. the bridge it depends on (127.0.0.1:8787) is healthy
#
# ASCII-only output on purpose (PS 5.1 reads BOM-less .ps1 as GBK).
#
#   powershell -ExecutionPolicy Bypass -File .\test\test-desktop-app.ps1

[CmdletBinding()]
param(
    [string]$BridgePort = '8787'
)

$ErrorActionPreference = 'Continue'
$script:fail = 0
function Ok($m)  { Write-Host "  [PASS] $m" -ForegroundColor Green }
function Bad($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }
function Info($m){ Write-Host "         $m" -ForegroundColor Gray }

Write-Host "`n== Official ChatGPT/Codex desktop app test ==`n" -ForegroundColor Cyan

# 1. Store package
Write-Host "1. Store package OpenAI.Codex"
$pkg = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'OpenAI.Codex*' }
if ($pkg) {
    Ok ("installed, version " + $pkg.Version)
    Info ("location: " + $pkg.InstallLocation)
} else {
    Bad "not installed - run 'codex app' to open the Store installer"
}

# 2. App process
Write-Host "2. App process"
$proc = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(ChatGPT|Codex)$' }
if ($proc) { Ok ("running, PID(s): " + (($proc | ForEach-Object { $_.Id }) -join ', ')) }
else { Info "not running now (that is fine - only the package must exist)" }

# 3. Codex CLI can see the app subcommand
Write-Host "3. 'codex app' subcommand"
$help = (& codex app --help 2>&1 | Out-String)
if ($help -match 'Desktop app') { Ok "subcommand available" }
else { Bad "unexpected: 'codex app --help' does not mention Desktop app" }

# 4. Bridge dependency
Write-Host "4. Bridge dependency (the app reads the same config.toml)"
try {
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$BridgePort/health" -TimeoutSec 10
    if ($r.status -eq 'ok') { Ok "bridge healthy on 127.0.0.1:$BridgePort" }
    else { Bad "bridge health status: $($r.status)" }
} catch { Bad "bridge unreachable - the desktop app will fail without it" }

Write-Host ""
Write-Host "Known limitation: ChatGPT's 'Computer use' is region/account gated" -ForegroundColor Gray
Write-Host "('Disabled by your organization or unavailable in your region') -" -ForegroundColor Gray
Write-Host "unrelated to the bridge; local Codex features are unaffected." -ForegroundColor Gray
Write-Host ""

if ($script:fail -eq 0) { Write-Host "Result: all checks passed`n" -ForegroundColor Green; exit 0 }
else { Write-Host "Result: $script:fail check(s) failed`n" -ForegroundColor Red; exit 1 }
