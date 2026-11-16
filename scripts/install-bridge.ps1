# Install the api2codex bridge, patched to rewrite the Codex identifying prompt.
#
# Why this exists: CC Switch's routing translates Responses -> Chat Completions
# but forwards the Codex system prompt verbatim. Gateways that fingerprint that
# prompt (error 11128) block the request. This bridge does the same translation
# and can neutralise the identifying wording.
#
# ONLY run the prompt rewrite against a gateway you control or are authorised to
# use this way. It exists to make a self-hosted setup work, not to evade a
# restriction someone else put in place.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\scripts\install-bridge.ps1 `
#       -BaseUrl http://127.0.0.1:7863/v1 -ApiKey sk-xxx -Model deepseek-v4.1-flash
#
#   -Port 8787        port to listen on
#   -NoSanitize       install without the prompt rewrite (plain translation)
#   -Force            re-clone and re-patch an existing install
#   -Start            launch the bridge in a background window when done

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$ApiKey,
    [Parameter(Mandatory = $true)][string]$Model,
    [int]$Port = 8787,
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'zc-codex-ccswitch'),
    [switch]$NoSanitize,
    [switch]$Force,
    [switch]$Start
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$UpstreamRepo = 'https://github.com/talkcozy/api2codex.git'
$bridgeDir = Join-Path $InstallRoot 'bridge'
$python = $null

function Write-Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "    [ok] $m" -ForegroundColor Green }
function Write-Warn2($m){ Write-Host "    [!!] $m" -ForegroundColor Yellow }
function Write-Info($m) { Write-Host "    $m" -ForegroundColor Gray }

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
Write-Step "Preflight checks"

$pythonCmd = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonCmd) {
    throw "Python 3.10+ is required for the bridge but 'python' was not found.`n" +
          "Download: https://www.python.org/downloads/"
}
$pyVersion = (& python --version 2>&1).ToString()
if ($pyVersion -notmatch 'Python 3\.(\d+)') { throw "unexpected python --version output: $pyVersion" }
if ([int]$Matches[1] -lt 10) { throw "Python 3.10 or newer is required, found $pyVersion" }
Write-Ok $pyVersion

if (-not (Test-Path $InstallRoot)) { New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null }
Write-Ok "install root: $InstallRoot"

if (Test-Path $bridgeDir) {
    if (-not $Force) {
        throw "$bridgeDir already exists. Re-run with -Force to re-clone and re-patch."
    }
    Remove-Item $bridgeDir -Recurse -Force
}

# --------------------------------------------------------------------------
# Clone upstream
# --------------------------------------------------------------------------
Write-Step "Fetching api2codex"
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "git is required to fetch the bridge. Install: https://git-scm.com/download/win"
}
& git clone --depth 1 $UpstreamRepo $bridgeDir
if ($LASTEXITCODE -ne 0) { throw "git clone failed with exit code $LASTEXITCODE" }

$upstreamCommit = (& git -C $bridgeDir rev-parse --short HEAD).Trim()
Write-Ok "cloned at $upstreamCommit"

$entry = Join-Path $bridgeDir 'api2codex.py'
if (-not (Test-Path $entry)) { throw "api2codex.py missing from the clone - upstream layout changed" }

# --------------------------------------------------------------------------
# Apply the prompt-rewrite patch
# --------------------------------------------------------------------------
function Get-TextSha256([string]$s) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($s)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

$helperBlock = @'


# ── Prompt sanitisation (added by zc-codex-ccswitch) ───────────────────────
# Some gateways fingerprint the official Codex system prompt and reject
# requests that carry it ("Illegal API invocation from an unapproved channel").
# This rewrites the identifying sentences so the upstream sees a generic
# assistant prompt. Behaviour is otherwise unchanged. Enable with
# SANITIZE_PROMPT=1.
_CODEX_FINGERPRINTS = (
    ("You are a coding agent running in the Codex CLI, a terminal-based coding assistant. "
     "Codex CLI is an open source project led by OpenAI.",
     "You are a precise, safe and helpful software engineering assistant working in a local "
     "development environment."),
    ("You are Codex,", "You are a software engineering assistant,"),
    ("running in the Codex CLI", "running in a local development environment"),
    ("Codex CLI is an open source project led by OpenAI",
     "This assistant operates in a local development environment"),
)


def sanitize_prompt(text: str) -> str:
    """Replace sentences that identify the client as Codex."""
    for src, dst in _CODEX_FINGERPRINTS:
        text = text.replace(src, dst)
    return text


def _maybe_sanitize_messages(req: dict) -> None:
    if os.environ.get("SANITIZE_PROMPT", "").lower() not in ("1", "true", "yes"):
        return
    for msg in req.get("messages", []):
        if msg.get("role") == "system" and isinstance(msg.get("content"), str):
            msg["content"] = sanitize_prompt(msg["content"])
'@

if (-not $NoSanitize) {
    Write-Step "Applying prompt-rewrite patch"

    $text = [System.IO.File]::ReadAllText($entry)

    # 1. Helper block, inserted just before build_chat_request so the functions
    #    exist by the time it is called.
    $anchor = 'def build_chat_request(body: dict) -> dict:'
    if ($text -notmatch [regex]::Escape($anchor)) {
        throw "anchor '$anchor' not found - upstream api2codex.py changed shape.`n" +
              "Inspect $entry and update the anchor in this script."
    }
    if ($text -match '_maybe_sanitize_messages') {
        Write-Warn2 "patch looks already applied - skipping insertion"
    } else {
        $text = $text.Replace($anchor, $helperBlock.TrimEnd() + "`n`n`n" + $anchor)
    }

    # 2. Call site: the single `return req` at the end of build_chat_request.
    #    Anchor on the preceding line to stay unambiguous.
    $callAnchor = @"
        if tools:
            req["tools"] = tools

    return req
"@ -replace "`r`n", "`n"

    $textNorm = $text -replace "`r`n", "`n"
    if ($textNorm -notmatch [regex]::Escape($callAnchor)) {
        throw "call-site anchor not found in build_chat_request - upstream changed.`n" +
              "Inspect $entry around its final 'return req'."
    }
    if ($textNorm -match '_maybe_sanitize_messages\(req\)') {
        Write-Warn2 "call site already patched - skipping"
    } else {
        $replacement = @"
        if tools:
            req["tools"] = tools

    _maybe_sanitize_messages(req)

    return req
"@ -replace "`r`n", "`n"
        $text = $textNorm.Replace($callAnchor, $replacement)
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($entry, $text, $utf8NoBom)

    # 3. Verify the patch actually parses and the symbols exist.
    $check = & python -c "import ast,sys; src=open(r'$entry',encoding='utf-8').read(); ast.parse(src); print('sanitize_prompt' in src and '_maybe_sanitize_messages' in src)"
    if ($LASTEXITCODE -ne 0) { throw "patched file does not parse as valid Python" }
    if ($check.Trim() -ne 'True') { throw "patch applied but expected symbols are missing" }
    Write-Ok "patch applied and verified"
} else {
    Write-Step "Skipping prompt-rewrite patch (-NoSanitize)"
}

# --------------------------------------------------------------------------
# Virtualenv + dependencies
# --------------------------------------------------------------------------
Write-Step "Installing dependencies"
$venv = Join-Path $bridgeDir '.venv'
& python -m venv $venv
if ($LASTEXITCODE -ne 0) { throw "python -m venv failed" }

$venvPython = Join-Path $venv 'Scripts\python.exe'
& $venvPython -m pip install --quiet --upgrade pip
& $venvPython -m pip install --quiet fastapi "uvicorn" httpx
if ($LASTEXITCODE -ne 0) { throw "pip install failed" }
Write-Ok "fastapi, uvicorn, httpx installed"

# --------------------------------------------------------------------------
# .env
# --------------------------------------------------------------------------
Write-Step "Writing .env"
$envPath = Join-Path $bridgeDir '.env'
$sanitizeFlag = if ($NoSanitize) { '' } else { '1' }
$envContent = @"
UPSTREAM_BASE_URL=$BaseUrl
UPSTREAM_API_KEY=$ApiKey
DEFAULT_MODEL=$Model
HOST=127.0.0.1
PORT=$Port
SANITIZE_PROMPT=$sanitizeFlag
"@
# ASCII keeps the file readable by the bridge's simple parser on every system.
Set-Content -Path $envPath -Value $envContent -Encoding ASCII
Write-Ok "$envPath"
Write-Warn2 "this file holds your upstream API key - it is gitignored, keep it that way"

# --------------------------------------------------------------------------
# Launcher
# --------------------------------------------------------------------------
Write-Step "Writing launcher"
$launcher = Join-Path $bridgeDir 'start-bridge.cmd'
# api2codex reads plain os.environ and does NOT parse .env, so the launcher has
# to feed the variables in itself. `set -a; . .env` is bash-only; this is the
# cmd.exe equivalent: read each KEY=VALUE line and set it in the environment.
$launcherBody = @"
@echo off
rem Starts the patched api2codex bridge. Leave this window open.
cd /d "%~dp0"

setlocal EnableDelayedExpansion
if not exist ".env" (
  echo [error] .env not found in %CD%
  exit /b 1
)
for /f "usebackq eol=# tokens=1,* delims==" %%A in (".env") do (
  if not "%%~A"=="" set "%%~A=%%~B"
)

if "%UPSTREAM_BASE_URL%"=="" (
  echo [error] UPSTREAM_BASE_URL is empty - check .env
  exit /b 1
)

echo Bridge starting on %HOST%:%PORT%  upstream=%UPSTREAM_BASE_URL%  sanitize=%SANITIZE_PROMPT%
".venv\Scripts\python.exe" api2codex.py
"@
Set-Content -Path $launcher -Value $launcherBody -Encoding ASCII
Write-Ok "$launcher"

# --------------------------------------------------------------------------
# Point Codex at the bridge
# --------------------------------------------------------------------------
Write-Step "Updating ~/.codex/config.toml"
$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
if (-not (Test-Path $codexHome)) { New-Item -ItemType Directory -Path $codexHome -Force | Out-Null }
$targetConfig = Join-Path $codexHome 'config.toml'

$newConfig = @"
model = "$Model"
model_reasoning_effort = "high"
model_provider = "bridge"

[model_providers.bridge]
name = "api2codex bridge"
base_url = "http://127.0.0.1:$Port/v1"
wire_api = "responses"
"@

if ((Test-Path $targetConfig) -and -not $Force) {
    $backup = "$targetConfig.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -Path $targetConfig -Destination $backup
    Write-Info "existing config backed up to $(Split-Path $backup -Leaf)"
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($targetConfig, $newConfig, $utf8NoBom)
Write-Ok $targetConfig

# --------------------------------------------------------------------------
# Optionally start and smoke-test
# --------------------------------------------------------------------------
if ($Start) {
    Write-Step "Starting bridge on port $Port"
    Start-Process -FilePath $launcher -WorkingDirectory $bridgeDir -WindowStyle Minimized
    Start-Sleep -Seconds 8

    $healthy = $false
    for ($i = 0; $i -lt 10; $i++) {
        try {
            $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/v1/models" -UseBasicParsing -TimeoutSec 5
            if ($r.StatusCode -eq 200) { $healthy = $true; break }
        } catch { Start-Sleep -Seconds 2 }
    }
    if ($healthy) {
        Write-Ok "bridge responding on 127.0.0.1:$Port"
    } else {
        Write-Warn2 "bridge did not answer within ~30s - check the minimised window for errors"
    }
}

Write-Step "Finished"
Write-Host ""
Write-Host "    Bridge dir   : $bridgeDir"
Write-Host "    Start it with: $launcher"
Write-Host "    Listening on : http://127.0.0.1:$Port/v1"
Write-Host "    Sanitisation : $(if ($NoSanitize) { 'disabled' } else { 'enabled (SANITIZE_PROMPT=1)' })"
Write-Host ""
Write-Host "    Verify the whole chain:" -ForegroundColor Gray
Write-Host "      powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1 -ProxyBase http://127.0.0.1:$Port/v1 -Model $Model" -ForegroundColor Gray
Write-Host ""
