# push_telemetry.ps1
# 把一份 JSON 指标文件提交并推送到当前仓库的 telemetry/ 目录。
# 与 tools/push_telemetry.sh 行为一致：只 add 目标文件、先 pull --rebase、
# 设备 ID 用仓库外的稳定随机值、忽略时间戳比较避免空提交洪水、
# 无变更/无网络静默退出、单实例锁。
#
# 用法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File push_telemetry.ps1 `
#       -Json <json路径> -Platform win [-RepoRoot <仓库根>]
param(
    [Parameter(Mandatory=$true)][string]$Json,
    [Parameter(Mandatory=$true)][ValidateSet("mac","win")][string]$Platform,
    [string]$RepoRoot = ""
)

$ErrorActionPreference = "SilentlyContinue"

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}
if (-not (Test-Path -LiteralPath $Json)) { exit 0 }

# 单实例锁（文件锁，跨进程）
$lockPath = Join-Path $env:TEMP "secdisplay-telemetry.lock"
try {
    $lock = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate,
                                   [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
} catch { exit 0 }

try {
    # 稳定设备 ID：%APPDATA% 下（仓库外），主机名常含用户名，不能进公开仓
    $idFile = Join-Path $env:APPDATA "secdisplay-device-id.txt"
    $label = $null
    if (Test-Path -LiteralPath $idFile) {
        $label = (Get-Content -LiteralPath $idFile -Raw) -replace "[^A-Za-z0-9]", ""
    }
    if (-not $label) {
        $label = [guid]::NewGuid().ToString("N").Substring(0, 8)
        [System.IO.File]::WriteAllText($idFile, $label)
    }
    if ($label.Length -gt 12) { $label = $label.Substring(0, 12) }

    $rel = "telemetry/$Platform/$label.json"
    $dest = Join-Path $RepoRoot $rel
    $destDir = Split-Path -Parent $dest
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    # 忽略 generated_utc / commit 后比较，指标没变就不提交
    function Norm([string]$p) {
        if (-not (Test-Path -LiteralPath $p)) { return "" }
        $o = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        $o.PSObject.Properties.Remove("generated_utc")
        $o.PSObject.Properties.Remove("commit")
        return ($o | ConvertTo-Json -Depth 8 -Compress)
    }
    if ((Test-Path -LiteralPath $dest) -and ((Norm $dest) -eq (Norm $Json))) {
        exit 0
    }
    Copy-Item -LiteralPath $Json -Destination $dest -Force

    Push-Location $RepoRoot
    git pull --rebase --autostash origin main 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        git rebase --abort 2>$null | Out-Null
        # 绝不做 git reset，那会撤出用户已暂存的内容
        Pop-Location
        exit 0
    }
    git add -- $rel 2>$null | Out-Null
    git diff --cached --quiet -- $rel
    if ($LASTEXITCODE -eq 0) { Pop-Location; exit 0 }
    git commit -q -m "telemetry($Platform/$label): auto update" 2>$null | Out-Null
    git push -q origin main 2>$null | Out-Null
    Pop-Location
    Write-Output "pushed $rel"
} finally {
    try { $lock.Dispose() } catch {}
}
