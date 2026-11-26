# 生成安装包完整性清单 manifest.json
# 用法：powershell -ExecutionPolicy Bypass -File .\build_manifest.ps1 -Dir <Release目录>
param(
    [Parameter(Mandatory = $true)]
    [string]$Dir
)

$ErrorActionPreference = "Stop"
$Dir = $Dir.TrimEnd('\', '/')
if (-not (Test-Path $Dir)) { throw "目录不存在：$Dir" }

$manifestPath = Join-Path $Dir "manifest.json"
if (Test-Path $manifestPath) { Remove-Item $manifestPath -Force }

$files = @()
Get-ChildItem -Path $Dir -Recurse -File -Force | ForEach-Object {
    if ($_.Name -eq "manifest.json") { return }
    $rel = $_.FullName.Substring($Dir.Length + 1).Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $files += [pscustomobject]@{
        path   = $rel
        sha256 = $hash
        size   = $_.Length
    }
}

if ($files.Count -eq 0) { throw "目录里没有可登记的文件：$Dir" }

$json = [pscustomobject]@{
    version   = '1.1'
    generated = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    files     = @($files)
} | ConvertTo-Json -Depth 5

$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($manifestPath, $json, $utf8)
Write-Host "==> 已生成清单：$manifestPath（$($files.Count) 个文件）"
