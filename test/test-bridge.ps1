# Test: bridge health check
#
# Read-only probes for the api2codex bridge (default 127.0.0.1:8787).
# Output is ASCII-only on purpose: Windows PowerShell 5.1 reads .ps1 as GBK
# when there is no BOM, and non-ASCII output strings can break parsing.
# Chinese explanations live in README.md instead.
#
#   powershell -ExecutionPolicy Bypass -File .\test\test-bridge.ps1
#   powershell -ExecutionPolicy Bypass -File .\test\test-bridge.ps1 -Port 8788 -Model glm-5.3

[CmdletBinding()]
param(
    [int]$Port = 8787,
    [string]$BindHost = '127.0.0.1',
    [string]$Model = 'deepseek-v4.1-flash',
    [string]$Expect = 'BRIDGE_TEST_OK',
    [int]$TimeoutSec = 60
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$fail = 0
function Ok($m)   { Write-Host "  [PASS] $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }

$base = "http://$BindHost`:$Port"

Write-Host "`n== Bridge health ($base) ==`n" -ForegroundColor Cyan

Write-Host "1. /health"
try {
    $r = Invoke-RestMethod -Uri "$base/health" -TimeoutSec 10
    if ($r.status -eq 'ok') { Ok "status=ok version=$($r.version)" } else { Bad "status=$($r.status)" }
} catch { Bad "unreachable: $($_.Exception.Message)" }

Write-Host "2. /v1/models"
try {
    $r = Invoke-RestMethod -Uri "$base/v1/models" -TimeoutSec 15
    $ids = @($r.data | ForEach-Object { $_.id })
    Ok "model count: $($ids.Count)"
    if ($ids -contains $Model) { Ok "target model present: $Model" }
    else { Bad "model not listed: $Model" }
} catch { Bad "model list failed: $($_.Exception.Message)" }

Write-Host "3. /v1/responses (translation + chat)"
$body = @{ model = $Model; input = "Reply with exactly: $Expect"; stream = $false } | ConvertTo-Json
try {
    $r = Invoke-RestMethod -Uri "$base/v1/responses" -Method Post `
        -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSec
    $text = ($r.output | Where-Object { $_.type -eq 'message' } |
             ForEach-Object { $_.content } |
             Where-Object { $_.type -eq 'output_text' } |
             ForEach-Object { $_.text }) -join ''
    if ($text -match [regex]::Escape($Expect)) { Ok "reply: $text" }
    else { Bad "unexpected reply: $text" }
} catch { Bad "chat failed: $($_.Exception.Message)" }

Write-Host ""
if ($fail -eq 0) { Write-Host "Result: all checks passed`n" -ForegroundColor Green; exit 0 }
else { Write-Host "Result: $fail check(s) failed`n" -ForegroundColor Red; exit 1 }
