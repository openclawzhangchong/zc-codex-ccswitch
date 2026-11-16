# Test: end-to-end chain
#
# Verify: bridge -> Codex CLI -> tool call -> WebUI API.
# The full acceptance test; all checks must pass.
#
#   powershell -ExecutionPolicy Bypass -File .\test\test-e2e.ps1
#   powershell -ExecutionPolicy Bypass -File .\test\test-e2e.ps1 -Model hy4flash-free

[CmdletBinding()]
param(
    [string]$Model = 'hy4flash-free',
    [string]$BridgePort = '8787',
    [string]$WebUIPort = '8789',
    [string]$Expect = 'E2E_OK'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:fail = 0
function Ok($m)   { Write-Host "  [PASS] $m" -ForegroundColor Green }
function Bad($m)  { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }

Write-Host "`n== End-to-end test ==`n" -ForegroundColor Cyan

# 1. Codex CLI
Write-Host "1. Codex CLI"
if (Get-Command codex -ErrorAction SilentlyContinue) { Ok (& codex --version) }
else { Bad "codex not on PATH"; exit 1 }

# 2. Bridge chat
Write-Host "2. Bridge /v1/responses"
$body = @{ model = $Model; input = "Reply with exactly: $Expect"; stream = $false } | ConvertTo-Json
try {
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$BridgePort/v1/responses" -Method Post `
        -ContentType 'application/json' -Body $body -TimeoutSec 90
    $text = ($r.output | ForEach-Object { $_.content } | Where-Object { $_.type -eq 'output_text' } | ForEach-Object { $_.text }) -join ''
    if ($text -match [regex]::Escape($Expect)) { Ok "reply: $text" } else { Bad "unexpected reply: $text" }
} catch { Bad "bridge chat failed: $($_.Exception.Message)" }

# 3. Codex CLI e2e (via cmd /c for .cmd and stdin)
Write-Host "3. Codex CLI chat"
$tmp = Join-Path $env:TEMP "e2e-$(Get-Random).txt"
$cmd = "/c codex exec --skip-git-repo-check -m $Model `"Reply with exactly: $Expect`""
$p = Start-Process -FilePath $env:ComSpec -ArgumentList $cmd `
    -RedirectStandardOutput $tmp -RedirectStandardError "$tmp.err" -NoNewWindow -PassThru -Wait
$out = (Get-Content $tmp -Raw -ErrorAction SilentlyContinue) + (Get-Content "$tmp.err" -Raw -ErrorAction SilentlyContinue)
Remove-Item $tmp, "$tmp.err" -Force -ErrorAction SilentlyContinue
if ($out -match [regex]::Escape($Expect)) { Ok "CLI replied: $Expect" }
else { Bad "CLI did not return expected value (exit $($p.ExitCode))" }

# 4. WebUI state
Write-Host "4. WebUI management API"
try {
    $state = Invoke-RestMethod -Uri "http://127.0.0.1:$WebUIPort/api/state" -TimeoutSec 15
    Ok "active: $($state.active), bridge running: $($state.bridge.running)"
    if ($state.bridge.running) { Ok "PID: $($state.bridge.pid)" } else { Bad "bridge not running" }
} catch { Bad "WebUI unavailable: $($_.Exception.Message)" }

Write-Host ""
if ($script:fail -eq 0) { Write-Host "Result: chain OK`n" -ForegroundColor Green; exit 0 }
else { Write-Host "Result: $script:fail failed`n" -ForegroundColor Red; exit 1 }
