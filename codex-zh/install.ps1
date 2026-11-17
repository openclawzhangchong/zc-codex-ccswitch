#Requires -Version 5.1
<#
.SYNOPSIS
  Codex 桌面版本地化安装器（开源通用版）
.DESCRIPTION
  - 自动检测 Codex 安装：
      * Microsoft Store 版（MSIX，目录受保护） -> 复制可写副本后打补丁
      * 官网安装版（EXE/MSI，目录可写）      -> 直接对安装目录打补丁（自动备份）
  - 通过补丁规则库开启官方多语言（默认中文；语言可在应用内设置切换，中英自由切换）
  - 支持自动更新适配：记录版本与补丁信息，更新后由启动器自动重新打补丁
  - 全程无需管理员权限；绝不修改 WindowsApps 原安装
.PARAMETER InstallPath  手动指定 app 目录或安装根目录（自动检测失败时使用）
.PARAMETER Language     目标语言代码，默认 zh-CN（用于快捷方式/启动参数与提示）
.PARAMETER CopyMode     强制"复制副本"模式（默认自动：受保护目录用副本，可写目录直接补丁）
.PARAMETER NoShortcut   不创建桌面快捷方式
.PARAMETER Silent       静默模式（供启动器自动调用）
.PARAMETER DryRun       只检测并报告，不执行复制/补丁
.PARAMETER Force        强制重新复制/补丁（忽略版本与哈希比较）
.PARAMETER Root         本地化副本根目录（默认 %USERPROFILE%\.codex\codex-localized；可用环境变量 CODEX_LOCALIZE_ROOT 覆盖）
#>
[CmdletBinding()]
param(
    [string]$InstallPath,
    [string]$Language = 'zh-CN',
    [switch]$CopyMode,
    [switch]$NoShortcut,
    [switch]$Silent,
    [switch]$DryRun,
    [switch]$Force,
    [string]$Root   # 本地化副本根目录（默认 %USERPROFILE%\.codex\codex-localized；可用环境变量 CODEX_LOCALIZE_ROOT 覆盖）
)

$ErrorActionPreference = 'Stop'

function Write-Info { param([string]$m) Write-Host "[信息] $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "[成功] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "[警告] $m" -ForegroundColor Yellow }
function Write-Err  { param([string]$m) Write-Host "[错误] $m" -ForegroundColor Red }

$userProfile = [Environment]::GetFolderPath('UserProfile')
if ([string]::IsNullOrWhiteSpace($userProfile)) { $userProfile = $env:USERPROFILE }
$localizeRoot = $Root
if ([string]::IsNullOrWhiteSpace($localizeRoot)) { $localizeRoot = $env:CODEX_LOCALIZE_ROOT }
if ([string]::IsNullOrWhiteSpace($localizeRoot)) { $localizeRoot = Join-Path $userProfile '.codex\codex-localized' }
$localizeRoot = [System.IO.Path]::GetFullPath($localizeRoot)
$legacyRoot   = Join-Path $userProfile '.codex\zh-cn-patched'
$configFile   = Join-Path $localizeRoot 'install.json'
$versionFile  = Join-Path $localizeRoot 'version.txt'
$logFile      = Join-Path $localizeRoot 'install.log'
$scriptDir    = $PSScriptRoot

# 简单日志
function Write-Log { param([string]$m) try { Add-Content -LiteralPath $logFile -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 } catch {} }

# ---------- 工具 ----------
. (Join-Path $scriptDir 'asar-util.ps1')

# ---------- 查找 Codex 安装 ----------
function Find-CodexInstall {
    param([string]$Override)
    $candidates = @()
    if ($Override) {
        foreach ($p in @($Override, (Join-Path $Override 'app'))) {
            if ((Test-Path -LiteralPath (Join-Path $p 'resources\app.asar')) -and ((Test-Path -LiteralPath (Join-Path $p 'ChatGPT.exe')) -or (Test-Path -LiteralPath (Join-Path $p 'codex.exe')))) {
                $full = (Get-Item -LiteralPath $p).FullName
                $kind = if ($full -like '*\WindowsApps\*') { 'store' } else { 'exe' }
                return @{ AppDir = $full; Kind = $kind }
            }
        }
    }
    # 1) Store 版（MSIX）
    try {
        $pkg = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'OpenAI.*Codex|^Codex$' } | Select-Object -First 1
        if (-not $pkg) { try { $pkg = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'OpenAI.*Codex|^Codex$' } | Select-Object -First 1 } catch {} }
        if ($pkg -and $pkg.InstallLocation) {
            foreach ($p in @((Join-Path $pkg.InstallLocation 'app'), $pkg.InstallLocation)) {
                if ((Test-Path -LiteralPath (Join-Path $p 'resources\app.asar')) -and (Test-Path -LiteralPath (Join-Path $p 'ChatGPT.exe'))) {
                    return @{ AppDir = (Get-Item -LiteralPath $p).FullName; Kind = 'store' }
                }
            }
        }
    } catch {}
    try {
        $dirs = Get-ChildItem -LiteralPath "$env:ProgramFiles\WindowsApps" -Directory -Filter 'OpenAI.Codex*' -ErrorAction SilentlyContinue
        foreach ($d in $dirs) {
            foreach ($p in @((Join-Path $d.FullName 'app'), $d.FullName)) {
                if ((Test-Path -LiteralPath (Join-Path $p 'resources\app.asar')) -and (Test-Path -LiteralPath (Join-Path $p 'ChatGPT.exe'))) {
                    return @{ AppDir = (Get-Item -LiteralPath $p).FullName; Kind = 'store' }
                }
            }
        }
    } catch {}
    # 2) 官网安装版（EXE/MSI，卸载注册表）
    try {
        $uninst = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
        foreach ($root in $uninst) {
            Get-ItemProperty $root -ErrorAction SilentlyContinue | Where-Object { ($_.DisplayName -match 'Codex') -and ($_.InstallLocation -or $_.DisplayIcon) } | ForEach-Object {
                $base = $null
                if ($_.InstallLocation) { $base = $_.InstallLocation }
                elseif ($_.DisplayIcon -and (Test-Path -LiteralPath $_.DisplayIcon)) { $base = Split-Path $_.DisplayIcon -Parent }
                if ($base) {
                    foreach ($p in @($base, (Join-Path $base 'app'), (Join-Path $base 'resources'))) {
                        if ((Test-Path -LiteralPath (Join-Path $p 'resources\app.asar')) -and (Test-Path -LiteralPath (Join-Path $p 'ChatGPT.exe'))) {
                            return @{ AppDir = (Get-Item -LiteralPath $p).FullName; Kind = 'exe' }
                        }
                    }
                }
            }
        }
    } catch {}
    return $null
}

function Get-CodexVersion {
    param([string]$AppDir)
    $leaf = Split-Path (Split-Path $AppDir -Parent) -Leaf
    if ($leaf -match 'OpenAI\.Codex_([0-9][0-9.]*)') { return $Matches[1] }
    $pkg = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'OpenAI.*Codex|^Codex$' } | Select-Object -First 1
    if ($pkg -and $pkg.Version) { return $pkg.Version }
    return 'unknown'
}

# ---------- 目录是否可写 ----------
function Test-DirWritable {
    param([string]$Dir)
    try {
        $probe = Join-Path $Dir ('.wtest-' + [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($probe, 'x')
        Remove-Item -LiteralPath $probe -Force
        return $true
    } catch { return $false }
}

# ---------- 字节流递归复制（EFS 安全）----------
function Copy-TreeBytes {
    param([string]$Src, [string]$Dst)
    if (-not (Test-Path -LiteralPath $Dst)) { New-Item -ItemType Directory -Path $Dst -Force | Out-Null }
    foreach ($dir in [System.IO.Directory]::EnumerateDirectories($Src)) {
        Copy-TreeBytes -Src $dir -Dst (Join-Path $Dst ([System.IO.Path]::GetFileName($dir)))
    }
    foreach ($file in [System.IO.Directory]::EnumerateFiles($Src)) {
        $name = [System.IO.Path]::GetFileName($file)
        $target = Join-Path $Dst $name
        $in = [System.IO.File]::OpenRead($file)
        try {
            $out = [System.IO.File]::Create($target)
            try {
                $buf = New-Object byte[] (8MB)
                while (($r = $in.Read($buf, 0, $buf.Length)) -gt 0) { $out.Write($buf, 0, $r) }
            } finally { $out.Dispose() }
        } finally { $in.Dispose() }
    }
}

function Copy-FileBytes {
    param([string]$Src, [string]$Dst)
    $in = [System.IO.File]::OpenRead($Src)
    try {
        $out = [System.IO.File]::Create($Dst)
        try {
            $buf = New-Object byte[] (8MB)
            while (($r = $in.Read($buf, 0, $buf.Length)) -gt 0) { $out.Write($buf, 0, $r) }
        } finally { $out.Dispose() }
    } finally { $in.Dispose() }
}

# ---------- 关闭目标目录下的 Codex 进程（路径校验后）----------
function Stop-CodexProcesses {
    param([string[]]$Roots)
    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -in @('ChatGPT', 'Codex') }
    $victims = @()
    foreach ($p in $procs) {
        try {
            $pp = $p.Path
            if (-not $pp) { continue }
            foreach ($r in $Roots) {
                if ($pp.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)) { $victims += $p; break }
            }
        } catch {}
    }
    if ($victims.Count -eq 0) { return }
    Write-Info ("检测到 {0} 个 Codex 进程，准备关闭..." -f $victims.Count)
    foreach ($p in $victims) { try { $p.CloseMainWindow() | Out-Null } catch {} }
    Start-Sleep -Seconds 3
    foreach ($p in $victims) {
        try { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } } catch {}
    }
    Start-Sleep -Seconds 1
}

# ---------- 补丁（等长原位：改 1 字节 + 离线同步 integrity，不解包/不重打包）----------
function Patch-App {
    param([string]$AppDir)
    $asar = Join-Path $AppDir 'resources\app.asar'
    $exe  = Join-Path $AppDir 'ChatGPT.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "ChatGPT.exe missing: $exe" }
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { throw "python not found on PATH (patch_inplace.py requires Python 3)" }
    # 备份原始 asar（仅首次，保持与 Store 版哈希比较有效）
    $bak = Join-Path $AppDir 'resources\app.asar.bak'
    if (-not (Test-Path -LiteralPath $bak)) { Copy-FileBytes -Src $asar -Dst $bak }
    $script = Join-Path $scriptDir 'patch_inplace.py'
    Write-Info "原位补丁：改 1 字节 + 离线同步 asar/exe 哈希（不解包/不重打包）..."
    & python $script $asar $exe
    if ($LASTEXITCODE -ne 0) { throw "patch_inplace.py failed (exit $LASTEXITCODE)" }
    Write-Ok "补丁完成（等长原位，无需启动报错回填哈希）"
}
# ---------- 写/读配置 ----------
function Write-InstallConfig {
    param([hashtable]$Config)
    $json = $Config | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($configFile, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-InstallConfig {
    if (-not (Test-Path -LiteralPath $configFile)) { return $null }
    try { return (Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# ---------- 主流程 ----------
Write-Info "=== Codex 本地化安装器（开源通用版）==="
Write-Log "启动安装器"
New-Item -ItemType Directory -Force -Path $localizeRoot | Out-Null

$found = Find-CodexInstall -Override $InstallPath
if (-not $found) {
    Write-Err "未找到 Codex。请确认已安装（Microsoft Store 或官网版），或用 -InstallPath 手动指定 app 目录。"
    Write-Log "未找到 Codex 安装"
    exit 1
}
$appDir = $found.AppDir
$kind = $found.Kind
$version = Get-CodexVersion -AppDir $appDir
Write-Ok "检测到 Codex：$appDir（形态：$(if($kind -eq 'store'){'Store/MSIX 受保护'}else{'官网版/可写'})，版本 $version）"
Write-Log "检测到 $appDir kind=$kind version=$version"

# 决定补丁目标目录
$writable = Test-DirWritable -Dir $appDir
$useCopy = $CopyMode -or (-not $writable)
if ($useCopy) {
    $targetApp = Join-Path $localizeRoot 'app'
    # 平滑迁移：若旧副本 zh-cn-patched\app 存在且版本一致，直接复用
    if (-not (Test-Path -LiteralPath (Join-Path $targetApp 'ChatGPT.exe'))) {
        $legacyApp = Join-Path $legacyRoot 'app'
        if ((Test-Path -LiteralPath (Join-Path $legacyApp 'ChatGPT.exe')) -and (Test-Path -LiteralPath (Join-Path $legacyApp 'resources\app.asar'))) {
            $lv = Get-CodexVersion -AppDir $legacyApp
            if ($lv -eq $version) {
                Write-Info "检测到旧版汉化副本（$legacyRoot），版本一致，将复用并迁移。"
                New-Item -ItemType Directory -Force -Path $localizeRoot | Out-Null
                Move-Item -LiteralPath $legacyApp -Destination $targetApp -Force
            }
        }
    }
    $mode = 'store-copy'
} else {
    $targetApp = $appDir
    $mode = 'direct'
}
Write-Info ("补丁模式：{0}" -f $(if($mode -eq 'store-copy'){'复制副本（推荐，不影响原版）'}else{'直接补丁安装目录（目录可写）'}))
Write-Info "目标目录：$targetApp"
Write-Log "模式=$mode 目标=$targetApp"

if ($DryRun) {
    $need = -not ((Test-Path -LiteralPath (Join-Path $targetApp 'ChatGPT.exe')) -and (Test-Path -LiteralPath (Join-Path $targetApp 'resources\app.asar')))
    Write-Info ("DryRun：{0}" -f $(if($need){'需要安装/更新'}else{'副本已存在'}))
    exit 0
}

# 关闭目标目录下进程
Stop-CodexProcesses -Roots @($targetApp, $appDir)

# 是否需要复制（仅 copy 模式）
$needCopy = $false
if ($mode -eq 'store-copy') {
    $storeAsar = Join-Path $appDir 'resources\app.asar'
    $copyAsar  = Join-Path $targetApp 'resources\app.asar'
    $bakAsar   = Join-Path $targetApp 'resources\app.asar.bak'
    $needCopy = $Force -or (-not (Test-Path -LiteralPath (Join-Path $targetApp 'ChatGPT.exe')))
    if (-not $needCopy) {
        $ref = $null
        if (Test-Path -LiteralPath $bakAsar) { $ref = $bakAsar }
        elseif (Test-Path -LiteralPath $copyAsar) { $ref = $copyAsar }
        if ($ref) {
            try {
                $h1 = (Get-FileHash -LiteralPath $storeAsar -Algorithm SHA256).Hash
                $h2 = (Get-FileHash -LiteralPath $ref -Algorithm SHA256).Hash
                if ($h1 -ne $h2) { $needCopy = $true }
            } catch { $needCopy = $true }
        }
    }
    if ($needCopy) {
        if (-not $Silent) {
            $ans = Read-Host "将复制 Codex 到 $targetApp（约 1-2GB，仅首次），继续？[y/N]"
            if ($ans -notmatch '^[yY]') { Write-Warn "已取消"; exit 0 }
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Write-Info "复制 Codex 到 $targetApp ..."
        Copy-TreeBytes -Src $appDir -Dst $targetApp
        $sw.Stop()
        Write-Ok ("复制完成，耗时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds)
        # 刷新 pristine 备份为本次复制的原版，保证升级后“与 Store 一致就跳过复制”判断正确
        Copy-FileBytes -Src (Join-Path $targetApp 'resources\app.asar') -Dst (Join-Path $targetApp 'resources\app.asar.bak')
    } else {
        Write-Info "副本与 Store 版一致，跳过复制。"
    }
}

# 是否需要补丁
$asarPath = Join-Path $targetApp 'resources\app.asar'
$needPatch = $Force -or (-not (Test-Path -LiteralPath $asarPath))
if (-not $needPatch) {
    $cfg = Read-InstallConfig
    $needPatch = -not ($cfg -and $cfg.version -eq $version -and (Test-Path -LiteralPath (Join-Path $targetApp 'ChatGPT.exe')))
}
if ($needPatch) {
    Patch-App -AppDir $targetApp
} else {
    Write-Info "已是最新，跳过补丁。"
}

# 写配置与版本
Write-InstallConfig -Config @{
    schemaVersion = 2
    mode          = $mode
    sourcePath    = $appDir
    installPath   = $targetApp
    version       = $version
    language      = $Language
    patchedAt     = (Get-Date).ToString('s')
}
Set-Content -LiteralPath $versionFile -Value $version -Encoding UTF8
Write-Log "安装完成 version=$version"

# 复制启动脚本到 localizeRoot（自包含）
foreach ($f in @('install.ps1', 'launch.ps1', 'asar-util.ps1', 'patch_inplace.py')) {
    $srcF = Join-Path $scriptDir $f
    if (Test-Path -LiteralPath $srcF) {
        Copy-Item -LiteralPath $srcF -Destination (Join-Path $localizeRoot $f) -Force -ErrorAction SilentlyContinue
    }
}
$cmdContent = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0launch.ps1`"`r`nif errorlevel 1 pause`r`n"
Set-Content -LiteralPath (Join-Path $localizeRoot 'launch.cmd') -Value $cmdContent -Encoding ASCII

# 桌面快捷方式（新建，不替换原有）
if (-not $NoShortcut) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $exePath = Join-Path $targetApp 'ChatGPT.exe'
    $lnkPath = Join-Path $desktop 'Codex 本地化版.lnk'
    if (-not (Test-Path -LiteralPath $exePath)) {
        $codexExe = Join-Path $targetApp 'resources\codex.exe'
        if (Test-Path -LiteralPath $codexExe) { $exePath = $codexExe }
    }
    if (Test-Path -LiteralPath $exePath) {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnkPath)
        $sc.TargetPath = Join-Path $localizeRoot 'launch.cmd'
        $sc.IconLocation = ($exePath + ',0')
        $sc.Description = '启动 Codex 本地化版（保留原版，自动适配更新）'
        $sc.Save()
        Write-Ok "已创建桌面快捷方式：$lnkPath"
    }
}

Write-Ok "安装完成！以后请通过桌面『Codex 本地化版』快捷方式启动（会自动适配更新）。"
Write-Ok "语言切换：启动后在 设置→General→Language 选择中文或 English 即可自由切换。"
if (-not $Silent) {
    $r = Read-Host "现在立即启动本地化版 Codex？[y/N]"
    if ($r -match '^[yY]') { & (Join-Path $localizeRoot 'launch.cmd') }
}
exit 0