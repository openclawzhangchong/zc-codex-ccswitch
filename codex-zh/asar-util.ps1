#Requires -Version 5.1
# asar 解包/打包工具（纯 .NET，PowerShell 5.1 兼容，无第三方依赖）

function Get-AsarProp {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Read-AsarHeader {
    param([string]$AsarPath)
    $fs = [System.IO.File]::OpenRead($AsarPath)
    try {
        $br = New-Object System.IO.BinaryReader($fs)
        $u0 = $br.ReadUInt32(); $u1 = $br.ReadUInt32(); $u2 = $br.ReadUInt32(); $u3 = $br.ReadUInt32()
        foreach ($len in @($u3, $u2, $u1)) {
            if ($len -le 0 -or $len -gt 256MB) { continue }
            $fs.Seek(16, [System.IO.SeekOrigin]::Begin) | Out-Null
            $jsonBytes = $br.ReadBytes([int]$len)
            $json = [System.Text.Encoding]::UTF8.GetString($jsonBytes)
            try {
                $obj = $json | ConvertFrom-Json
                return @{ JsonLen = [long]$len; Json = $obj; DataOffset = [long](16 + $len) }
            } catch { }
        }
        throw "无法解析 asar 头部: $AsarPath"
    } finally { $fs.Dispose() }
}

function Expand-Asar {
    param([string]$AsarPath, [string]$OutDir, [switch]$Force)
    if (Test-Path -LiteralPath $OutDir) {
        if ($Force) {
            $full = [System.IO.Path]::GetFullPath($OutDir).TrimEnd('\')
            $root = [System.IO.Path]::GetPathRoot($full).TrimEnd('\')
            if ([string]::IsNullOrWhiteSpace($full) -or $full -eq $root -or $full -ieq $env:USERPROFILE -or $full -like '*\WindowsApps\*') {
                throw "拒绝删除危险路径: $full"
            }
            Remove-Item -LiteralPath $full -Recurse -Force
        } else {
            throw "目标已存在: $OutDir（用 -Force 覆盖）"
        }
    }
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $hdr = Read-AsarHeader -AsarPath $AsarPath
    $fs = [System.IO.File]::OpenRead($AsarPath)
    try {
        $script:expandedFiles = 0
        $script:expandedBytes = [long]0
        $script:expandedUnpacked = 0

        function Walk-Node {
            param($Node, [string]$Rel, $Stream, [long]$DataOffset, [string]$OutRoot)
            $files = Get-AsarProp $Node 'files'
            if ($null -ne $files) {
                foreach ($p in $files.PSObject.Properties) {
                    Walk-Node -Node $p.Value -Rel $(if ([string]::IsNullOrEmpty($Rel)) { $p.Name } else { Join-Path $Rel $p.Name }) -Stream $Stream -DataOffset $DataOffset -OutRoot $OutRoot
                }
                return
            }
            $unpacked = Get-AsarProp $Node 'unpacked'
            if ($unpacked) { $script:expandedUnpacked++; return }
            $offset = [long](Get-AsarProp $Node 'offset')
            $size = [long](Get-AsarProp $Node 'size')
            $outPath = Join-Path $OutRoot $Rel
            $dir = Split-Path $outPath
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $Stream.Seek($DataOffset + $offset, [System.IO.SeekOrigin]::Begin) | Out-Null
            $out = [System.IO.File]::Create($outPath)
            try {
                $buf = New-Object byte[] (8MB)
                $remaining = $size
                while ($remaining -gt 0) {
                    $toRead = [int][Math]::Min($remaining, $buf.Length)
                    $r = $Stream.Read($buf, 0, $toRead)
                    if ($r -le 0) { throw "读取失败 @ $Rel" }
                    $out.Write($buf, 0, $r)
                    $remaining -= $r
                    $script:expandedBytes += $r
                }
                $script:expandedFiles++
            } finally { $out.Dispose() }
        }

        Walk-Node -Node $hdr.Json -Rel '' -Stream $fs -DataOffset $hdr.DataOffset -OutRoot $OutDir
        Write-Output ("解包完成: 文件 {0} 个, 字节 {1:N1} MB, unpacked 标记 {2} 个" -f $script:expandedFiles, ($script:expandedBytes/1MB), $script:expandedUnpacked)
    } finally { $fs.Dispose() }
}
