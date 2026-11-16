# One-click installer for the Codex + CC GUI + CC Switch stack.
#
# Tested on Windows 11 (x64) with PowerShell 5.1.
# Run from a normal (non-elevated) PowerShell window:
#
#   powershell -ExecutionPolicy Bypass -File .\scripts\install.ps1
#
# Optional flags:
#   -InstallRoot <path>   where the portable apps live (default: %LOCALAPPDATA%\zc-codex-ccswitch)
#   -SkipCcGui            do not download CC GUI
#   -SkipCcSwitch         do not download CC Switch
#   -SkipCodex            do not install the Codex CLI
#   -Force                re-download and overwrite existing files

[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'zc-codex-ccswitch'),
    [switch]$SkipCcGui,
    [switch]$SkipCcSwitch,
    [switch]$SkipCodex,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is far faster without the bar

# --------------------------------------------------------------------------
# Pinned versions. Bump these together with the hashes in checksums.psd1.
# --------------------------------------------------------------------------
$Versions = @{
    CodexNpm    = '0.169.0'
    CcGui       = '1.2.4'
    CcSwitch    = '4.0.32'
}

$Urls = @{
    CcGui    = "https://github.com/zhukunpenglinyutong/desktop-cc-gui/releases/download/v$($Versions.CcGui)/CC.GUI_$($Versions.CcGui)_x64-setup.exe"
    CcSwitch = "https://github.com/farion1231/cc-switch/releases/download/v$($Versions.CcSwitch)/CC-Switch-v$($Versions.CcSwitch)-Windows-Portable.zip"
}

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    [ok] $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "    [!!] $msg" -ForegroundColor Yellow }
function Write-Info($msg) { Write-Host "    $msg" -ForegroundColor Gray }

function Test-CommandExists([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-FileSha256([string]$Path) {
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-RemoteFile([string]$Url, [string]$Destination) {
    Write-Info "downloading $(Split-Path $Url -Leaf)"
    $partial = "$Destination.part"
    if (Test-Path $partial) { Remove-Item $partial -Force }
    # curl.exe ships with Windows 10 1803+ and is much faster/more reliable than
    # Invoke-WebRequest for large GitHub release assets.
    if (Test-CommandExists 'curl.exe') {
        & curl.exe -fL --retry 3 --retry-delay 2 -o $partial $Url
        if ($LASTEXITCODE -ne 0) { throw "curl failed with exit code $LASTEXITCODE for $Url" }
    } else {
        Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing
    }
    Move-Item -Path $partial -Destination $Destination -Force
    Write-Ok "saved $(Split-Path $Destination -Leaf)"
}

function Assert-Checksum([string]$Path, [string]$Expected, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Expected)) {
        Write-Warn2 "$Label has no pinned checksum in checksums.psd1 - skipping verification"
        return
    }
    $actual = Get-FileSha256 $Path
    if ($actual -ne $Expected.ToLowerInvariant()) {
        throw "$Label checksum mismatch.`n  expected: $Expected`n  actual:   $actual"
    }
    Write-Ok "$Label checksum verified"
}

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------
Write-Step "Preflight checks"

$isWindows = $true
if ($PSVersionTable.PSEdition -eq 'Core') { $isWindows = $IsWindows }
if (-not $isWindows) { throw "This installer targets Windows only." }

Write-Ok "Windows detected"

if (-not $SkipCodex) {
    if (-not (Test-CommandExists 'node')) {
        throw "Node.js is required to install the Codex CLI but 'node' was not found on PATH.`n" +
              "Install Node.js 22 LTS or newer from https://nodejs.org/ and re-run."
    }
    $nodeVersion = (& node --version).TrimStart('v')
    $nodeMajor = [int]($nodeVersion.Split('.')[0])
    if ($nodeMajor -lt 22) {
        throw "Node.js 22 or newer is required, found v$nodeVersion.`nDownload: https://nodejs.org/"
    }
    Write-Ok "Node.js v$nodeVersion"
}

if (-not (Test-Path $InstallRoot)) {
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
}
Write-Ok "Install root: $InstallRoot"

$downloadDir = Join-Path $InstallRoot '_downloads'
if (-not (Test-Path $downloadDir)) {
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
}

# --------------------------------------------------------------------------
# Checksums
# --------------------------------------------------------------------------
$checksumPath = Join-Path $PSScriptRoot 'checksums.psd1'
$Checksums = @{}
if (Test-Path $checksumPath) {
    $Checksums = Import-PowerShellDataFile -Path $checksumPath
} else {
    Write-Warn2 "checksums.psd1 not found next to this script; downloads will not be verified"
}

# --------------------------------------------------------------------------
# 1. Codex CLI
# --------------------------------------------------------------------------
if ($SkipCodex) {
    Write-Step "Skipping Codex CLI (-SkipCodex)"
} else {
    Write-Step "Installing Codex CLI @$($Versions.CodexNpm)"

    $installedCodex = $null
    if (Test-CommandExists 'codex') {
        try { $installedCodex = (& codex --version 2>$null) } catch { $installedCodex = $null }
    }

    if ($installedCodex -and -not $Force) {
        Write-Ok "already installed: $installedCodex"
        Write-Info "use -Force to reinstall"
    } else {
        & npm install -g "@openai/codex@$($Versions.CodexNpm)"
        if ($LASTEXITCODE -ne 0) { throw "npm install failed with exit code $LASTEXITCODE" }

        # npm's global bin directory is not always on PATH in a fresh shell.
        $npmPrefix = (& npm prefix -g).Trim()
        $codexCmd = Join-Path $npmPrefix 'codex.cmd'
        if (-not (Test-Path $codexCmd)) {
            throw "Codex installed but '$codexCmd' is missing."
        }
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($userPath -notlike "*$npmPrefix*") {
            [Environment]::SetEnvironmentVariable('Path', "$userPath;$npmPrefix", 'User')
            Write-Warn2 "added $npmPrefix to your user PATH - open a new terminal to pick it up"
        }
        Write-Ok "installed $(& codex --version)"
    }
}

# --------------------------------------------------------------------------
# 2. CC GUI
# --------------------------------------------------------------------------
$ccGuiExe = Join-Path $InstallRoot 'cc-gui\ccgui-next.exe'
if ($SkipCcGui) {
    Write-Step "Skipping CC GUI (-SkipCcGui)"
} elseif ((Test-Path $ccGuiExe) -and -not $Force) {
    Write-Step "CC GUI already installed"
    Write-Ok $ccGuiExe
} else {
    Write-Step "Installing CC GUI @$($Versions.CcGui)"

    $installer = Join-Path $downloadDir "CC.GUI_$($Versions.CcGui)_x64-setup.exe"
    if (-not (Test-Path $installer) -or $Force) {
        Get-RemoteFile -Url $Urls.CcGui -Destination $installer
        Assert-Checksum -Path $installer -Expected $Checksums.CcGuiInstaller -Label 'CC GUI installer'
    } else {
        Write-Ok "using cached installer"
    }

    $ccGuiDir = Join-Path $InstallRoot 'cc-gui'
    New-Item -ItemType Directory -Path $ccGuiDir -Force | Out-Null
    Write-Info "running silent installer (NSIS /S)"
    $proc = Start-Process -FilePath $installer -ArgumentList '/S', "/D=$ccGuiDir" -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "CC GUI installer exited with code $($proc.ExitCode)" }

    if (-not (Test-Path $ccGuiExe)) {
        throw "CC GUI installer finished but $ccGuiExe is missing."
    }
    Write-Ok "installed to $ccGuiDir"
}

# --------------------------------------------------------------------------
# 3. CC Switch (portable)
# --------------------------------------------------------------------------
$ccSwitchExe = Join-Path $InstallRoot 'cc-switch\cc-switch.exe'
if ($SkipCcSwitch) {
    Write-Step "Skipping CC Switch (-SkipCcSwitch)"
} elseif ((Test-Path $ccSwitchExe) -and -not $Force) {
    Write-Step "CC Switch already installed"
    Write-Ok $ccSwitchExe
} else {
    Write-Step "Installing CC Switch @$($Versions.CcSwitch) (portable)"

    $zip = Join-Path $downloadDir "CC-Switch-v$($Versions.CcSwitch)-Windows-Portable.zip"
    if (-not (Test-Path $zip) -or $Force) {
        Get-RemoteFile -Url $Urls.CcSwitch -Destination $zip
        Assert-Checksum -Path $zip -Expected $Checksums.CcSwitchPortable -Label 'CC Switch portable zip'
    } else {
        Write-Ok "using cached archive"
    }

    $ccSwitchDir = Join-Path $InstallRoot 'cc-switch'
    if (Test-Path $ccSwitchDir) { Remove-Item $ccSwitchDir -Recurse -Force }
    New-Item -ItemType Directory -Path $ccSwitchDir -Force | Out-Null
    Expand-Archive -Path $zip -DestinationPath $ccSwitchDir -Force

    if (-not (Test-Path $ccSwitchExe)) {
        throw "extracted archive does not contain cc-switch.exe"
    }
    # portable.ini is what makes CC Switch keep its state out of the registry.
    $portableIni = Join-Path $ccSwitchDir 'portable.ini'
    if (-not (Test-Path $portableIni)) {
        Set-Content -Path $portableIni -Value "# CC Switch portable build marker`nportable=true" -Encoding ASCII
    }
    Write-Ok "extracted to $ccSwitchDir"
}

# --------------------------------------------------------------------------
# 4. Codex provider config
# --------------------------------------------------------------------------
Write-Step "Writing Codex provider config"

$codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
if (-not (Test-Path $codexHome)) { New-Item -ItemType Directory -Path $codexHome -Force | Out-Null }

$templatePath = Join-Path $PSScriptRoot '..\config\codex-config.toml.template'
$targetConfig = Join-Path $codexHome 'config.toml'

if (-not (Test-Path $templatePath)) {
    Write-Warn2 "config template missing at $templatePath - leaving config.toml alone"
} elseif ((Test-Path $targetConfig) -and -not $Force) {
    Write-Warn2 "$targetConfig already exists - leaving it untouched"
    Write-Info "CC Switch rewrites this file itself once routing is on."
    Write-Info "Re-run with -Force to overwrite it from the template."
    $targetConfig = "$targetConfig (unchanged)"
} else {
    $apiBase = Read-Host "    Upstream base URL [http://127.0.0.1:7863/v1]"
    if ([string]::IsNullOrWhiteSpace($apiBase)) { $apiBase = 'http://127.0.0.1:7863/v1' }

    $apiModel = Read-Host "    Model name [deepseek-v4.1-flash]"
    if ([string]::IsNullOrWhiteSpace($apiModel)) { $apiModel = 'deepseek-v4.1-flash' }

    $rendered = (Get-Content -Path $templatePath -Raw) `
        -replace '__UPSTREAM_BASE_URL__', $apiBase `
        -replace '__MODEL__', $apiModel

    if (Test-Path $targetConfig) {
        $backup = "$targetConfig.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item -Path $targetConfig -Destination $backup
        Write-Info "existing config backed up to $backup"
    }
    # Write without a BOM: PowerShell 5.1's -Encoding UTF8 prepends one, and
    # Codex's TOML loader chokes on a leading U+FEFF.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($targetConfig, $rendered, $utf8NoBom)
    Write-Ok "$targetConfig"
}

# --------------------------------------------------------------------------
# Done
# --------------------------------------------------------------------------
Write-Step "Finished"
Write-Host @"
    Codex CLI    : $(if (Test-CommandExists 'codex') { (& codex --version) } else { 'not installed' })
    CC GUI       : $ccGuiExe
    CC Switch    : $ccSwitchExe
    Codex config : $targetConfig

    Next steps:
      1. Launch CC Switch:  $ccSwitchExe
      2. Codex tab -> Routing -> Start routing
      3. Setting 'Upstream format' must be 'Chat Completions' for chat-only gateways
      4. Launch CC GUI:     $ccGuiExe
"@ -ForegroundColor Gray
