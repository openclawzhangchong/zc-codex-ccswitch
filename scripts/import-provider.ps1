# Configure the Codex provider inside CC Switch without clicking through the UI.
#
# CC Switch keeps its state in a SQLite database under the user profile:
#   %USERPROFILE%\.cc-switch\cc-switch.db
#
# This script seeds one Codex provider that points at a chat-completions-only
# gateway, with the upstream format preset to "Chat Completions" - that setting
# is what makes CC Switch translate Responses -> Chat Completions.
#
# IMPORTANT: CC Switch rewrites this database when it exits and may hold the file
# open while running. Run this script with CC Switch CLOSED, then start it.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\scripts\import-provider.ps1 `
#       -BaseUrl http://127.0.0.1:7863/v1 -ApiKey sk-xxx -Model deepseek-v4.1-flash
#
#   -DryRun   print the SQL and the resulting provider instead of writing
#   -KeepCurrentProvider   leave the existing "current provider" selection alone

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$ApiKey,
    [Parameter(Mandatory = $true)][string]$Model,
    [string]$ProviderName = 'Local Gateway',
    [string]$CcSwitchDataDir = (Join-Path $env:USERPROFILE '.cc-switch'),
    [switch]$DryRun,
    [switch]$KeepCurrentProvider
)

$ErrorActionPreference = 'Stop'

function Write-Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "    [ok] $m" -ForegroundColor Green }
function Write-Warn2($m){ Write-Host "    [!!] $m" -ForegroundColor Yellow }
function Write-Info($m) { Write-Host "    $m" -ForegroundColor Gray }

$dbPath = Join-Path $CcSwitchDataDir 'cc-switch.db'
if (-not (Test-Path $dbPath)) {
    throw "CC Switch database not found at $dbPath.`n" +
          "Launch CC Switch once so it creates its schema, quit it completely, then re-run this script."
}

if ((Get-Process -Name 'cc-switch' -ErrorAction SilentlyContinue) -and -not $DryRun) {
    throw "CC Switch is running. Quit it completely (tray icon -> Quit) and re-run.`n" +
          "It rewrites this database on exit and would clobber the changes."
}

# --------------------------------------------------------------------------
# Make sure we have a sqlite3.exe to talk to the database with.
# --------------------------------------------------------------------------
function Get-SqliteExe {
    $cmd = Get-Command sqlite3.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $toolsDir = Join-Path $env:LOCALAPPDATA 'zc-codex-ccswitch\_tools'
    $cached = Join-Path $toolsDir 'sqlite3.exe'
    if (Test-Path $cached) { return $cached }

    Write-Step "Fetching sqlite3.exe (one time)"
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    $zip = Join-Path $toolsDir 'sqlite-tools.zip'

    # Resolve the current tools bundle from the official download index.
    $index = Invoke-WebRequest -Uri 'https://www.sqlite.org/download.html' -UseBasicParsing
    $match = [regex]::Match($index.Content, 'sqlite-tools-win-x64-\d+\.zip')
    if (-not $match.Success) { throw "Could not find a sqlite-tools-win-x64 bundle on sqlite.org/download.html" }

    $url = "https://www.sqlite.org/2026/$($match.Value)"
    Write-Info "downloading $($match.Value)"
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -fsSL --retry 3 -o $zip $url
        if ($LASTEXITCODE -ne 0) { throw "download failed (exit $LASTEXITCODE)" }
    } else {
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    }

    Expand-Archive -Path $zip -DestinationPath $toolsDir -Force
    $found = Get-ChildItem -Path $toolsDir -Filter 'sqlite3.exe' -Recurse | Select-Object -First 1
    if (-not $found) { throw "sqlite3.exe not present in the downloaded bundle" }
    if ($found.FullName -ne $cached) { Copy-Item $found.FullName $cached -Force }
    Write-Ok "sqlite3 cached at $cached"
    return $cached
}

$sqlite = Get-SqliteExe

# --------------------------------------------------------------------------
# Build the provider row.
#
# `config` is the exact config.toml CC Switch materialises for this provider.
# `auth.OPENAI_API_KEY` is the real upstream key - CC Switch keeps it here and
# injects it into proxied requests, so ~/.codex/auth.json never holds it.
# --------------------------------------------------------------------------
$codexConfig = @"
model = "$Model"
model_reasoning_effort = "high"
model_provider = "custom"

[model_providers]

[model_providers.custom]
name = "custom"
wire_api = "responses"
requires_openai_auth = true
base_url = "$BaseUrl"
"@

$id = [guid]::NewGuid().ToString()
$now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

$settingsConfig = [ordered]@{
    auth = [ordered]@{ OPENAI_API_KEY = $ApiKey }
    config = $codexConfig
    modelCatalog = [ordered]@{
        models = @(
            [ordered]@{ model = $Model; displayName = $Model; contextWindow = 1000000 }
        )
    }
}

# apiFormat = openai_chat  ==  the "Upstream format: Chat Completions" setting.
$meta = [ordered]@{
    commonConfigEnabled = $true
    endpointAutoSelect  = $true
    apiFormat           = 'openai_chat'
    providerName        = $ProviderName
}

$settingsJson = ($settingsConfig | ConvertTo-Json -Depth 8 -Compress)
$metaJson     = ($meta           | ConvertTo-Json -Depth 8 -Compress)

# SQLite escapes a single quote by doubling it.
function SqlEscape([string]$s) { return $s.Replace("'", "''") }

$insert = @"
INSERT INTO providers
  (id, app_type, name, settings_config, website_url, category, created_at, sort_index,
   notes, icon, icon_color, meta, is_current, in_failover_queue, cost_multiplier,
   limit_daily_usd, limit_monthly_usd, provider_type)
VALUES
  ('$(SqlEscape $id)', 'codex', '$(SqlEscape $ProviderName)', '$(SqlEscape $settingsJson)',
   NULL, 'custom', $now, 0, NULL, NULL, NULL, '$(SqlEscape $metaJson)',
   1, 0, '1.0', NULL, NULL, NULL);
"@

$clearCurrent = "UPDATE providers SET is_current = 0 WHERE app_type = 'codex';"

Write-Step "Provider to create"
Write-Info "id     : $id"
Write-Info "name   : $ProviderName"
Write-Info "base   : $BaseUrl"
Write-Info "model  : $Model"
Write-Info "format : Chat Completions (translated)"

if ($DryRun) {
    Write-Step "Dry run - SQL that would be executed"
    if (-not $KeepCurrentProvider) { Write-Host $clearCurrent }
    Write-Host $insert
    return
}

# --------------------------------------------------------------------------
# Apply. Wrap in a transaction and back the database up first.
# --------------------------------------------------------------------------
$backup = "$dbPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item -Path $dbPath -Destination $backup
Write-Ok "database backed up to $(Split-Path $backup -Leaf)"

$sql = if ($KeepCurrentProvider) { $insert } else { "$clearCurrent`n$insert" }

$sqlFile = Join-Path $env:TEMP "ccswitch-import-$([guid]::NewGuid().ToString('N')).sql"
Set-Content -Path $sqlFile -Value $sql -Encoding UTF8

try {
    $output = & $sqlite $dbPath ".read `"$sqlFile`"" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "sqlite3 failed: $output" }
} finally {
    Remove-Item $sqlFile -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------
# Verify
# --------------------------------------------------------------------------
$check = & $sqlite $dbPath "SELECT id || ' | ' || name || ' | ' || is_current FROM providers WHERE app_type='codex';" 2>&1
Write-Step "Codex providers now in the database"
$check | ForEach-Object { Write-Info $_ }

$target = & $sqlite $dbPath "SELECT meta FROM providers WHERE id='$id';" 2>&1
if ($target -notmatch 'openai_chat') {
    throw "provider was written but meta does not contain openai_chat - check the database manually"
}
Write-Ok "provider written with upstream format = Chat Completions"

Write-Host @"

    Next: start CC Switch, open the Codex tab, confirm the provider shows
    "Routing", and make sure routing is started (Routing tab -> Start routing).

"@ -ForegroundColor Gray
