# End-to-end check that the Codex -> CC Switch -> gateway chain works.
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1
#   powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1 -Model deepseek-v4.1-flash -Expect PONG
#
# Exit code 0 means every check passed.

[CmdletBinding()]
param(
    [string]$Model = 'deepseek-v4.1-flash',
    [string]$Expect = 'VERIFY_OK',
    [string]$ProxyBase = 'http://127.0.0.1:15721/v1',
    [int]$TimeoutSec = 120
)

$ErrorActionPreference = 'Stop'
$script:failures = 0

function Write-Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Pass($m)       { Write-Host "    [PASS] $m" -ForegroundColor Green }
function Fail($m)       { Write-Host "    [FAIL] $m" -ForegroundColor Red; $script:failures++ }
function Info($m)       { Write-Host "    $m" -ForegroundColor Gray }

# --------------------------------------------------------------------------
Write-Step "1. Codex CLI present"
if (Get-Command codex -ErrorAction SilentlyContinue) {
    $v = (& codex --version) 2>&1
    Pass $v
} else {
    Fail "codex not found on PATH"
}

# --------------------------------------------------------------------------
Write-Step "2. CC Switch proxy listening on 15721"
$listening = Get-NetTCPConnection -LocalPort 15721 -State Listen -ErrorAction SilentlyContinue
if ($listening) {
    Pass "listening (pid $($listening[0].OwningProcess))"
} else {
    Fail "nothing listening on 127.0.0.1:15721 - start CC Switch and enable Routing"
}

# --------------------------------------------------------------------------
Write-Step "3. Proxy answers a Responses request"
$body = @{
    model  = $Model
    input  = "Reply with exactly: $Expect"
    stream = $false
} | ConvertTo-Json -Depth 5

try {
    $resp = Invoke-RestMethod -Uri "$ProxyBase/responses" -Method Post `
        -ContentType 'application/json' `
        -Headers @{ Authorization = 'Bearer PROXY_MANAGED' } `
        -Body $body -TimeoutSec $TimeoutSec

    $text = ($resp.output | Where-Object { $_.type -eq 'message' } |
             ForEach-Object { $_.content } |
             Where-Object { $_.type -eq 'output_text' } |
             ForEach-Object { $_.text }) -join ''

    if ($text -match [regex]::Escape($Expect)) {
        Pass "model replied: $text"
    } else {
        Fail "got a response but it did not contain '$Expect': $text"
    }
} catch {
    $msg = $_.Exception.Message
    Fail "request failed: $msg"
    if ($msg -match '404') {
        Info "404 usually means the provider's upstream format is still 'Responses (native)'."
        Info "Set Advanced options -> Upstream format -> Chat Completions."
    }
}

# --------------------------------------------------------------------------
Write-Step "4. Codex CLI round trip"
$workDir = Join-Path $env:TEMP "ccswitch-verify-$([guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
try {
    # `codex exec` appends whatever arrives on stdin as a `<stdin>` block and
    # blocks waiting for EOF when it thinks a pipe is attached. Redirect stdin
    # from NUL so the process is unambiguously non-interactive.
    $outFile = Join-Path $env:TEMP "codex-verify-$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
    # `codex` on PATH is a .cmd shim, which Start-Process cannot execute
    # directly - route through cmd.exe. Redirecting from an empty file gives the
    # child EOF on stdin so it does not hang waiting for piped input.
    # Quote the prompt: cmd.exe splits unquoted arguments on whitespace.
    $cmdLine = '/c codex exec --skip-git-repo-check "Reply with exactly: ' + $Expect + '"'
    $p = Start-Process -FilePath $env:ComSpec `
        -ArgumentList $cmdLine `
        -RedirectStandardOutput $outFile `
        -RedirectStandardError "$outFile.err" `
        -NoNewWindow -PassThru -Wait
    $out = ''
    if (Test-Path $outFile)       { $out += Get-Content $outFile -Raw }
    if (Test-Path "$outFile.err") { $out += Get-Content "$outFile.err" -Raw }
    Remove-Item $outFile, "$outFile.err" -Force -ErrorAction SilentlyContinue

    if ($out -match [regex]::Escape($Expect)) {
        Pass "codex exec returned $Expect"
    } else {
        Fail "codex exec did not return $Expect (exit $($p.ExitCode))"
        Info (($out.Trim() -split "`n" | Select-Object -Last 6) -join "`n")
    }
} catch {
    Fail "codex exec threw: $($_.Exception.Message)"
} finally {
    Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------
Write-Step "Result"
if ($script:failures -eq 0) {
    Write-Host "    All checks passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "    $script:failures check(s) failed." -ForegroundColor Red
    exit 1
}
