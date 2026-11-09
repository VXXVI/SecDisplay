# telemetry_win_loop.ps1
# Windows 端无人值守遥测循环：定时从运行中的接收端日志提取脱敏指标并 push。
# 由「任务计划程序」每 5 分钟调用一次；单次运行，不常驻、不抢全屏、不动光标。
# 设备 ID 由 push_telemetry.ps1 用仓库外的随机值生成，主机名不进公开仓。
param(
    [string]$RepoRoot = ""
)

$ErrorActionPreference = "SilentlyContinue"
if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
}
$winDir = Split-Path -Parent $PSCommandPath
$tools = Join-Path $RepoRoot "tools"

# 只挑含状态行的日志（--log 输出），避免选中无「附加延迟」的其它日志
$log = Get-ChildItem -LiteralPath (Join-Path $winDir "logs") -Filter "*.log" -File -ErrorAction SilentlyContinue |
       Where-Object { (Get-Content -LiteralPath $_.FullName -Tail 40 -ErrorAction SilentlyContinue) -match "附加延迟|SecDisplay 接收端" } |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $log) { exit 0 }

$stage = Join-Path $env:TEMP ("secdisplay-tel-" + [guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    $out = Join-Path $stage "win.json"
    $commit = (git -C $RepoRoot rev-parse --short HEAD 2>$null)
    if (-not $commit) { $commit = "unknown" }

    $done = $false
    # Python 优先，但必须真的产出文件（防 WindowsApps python3 存根空跑）
    $py = Get-Command python3 -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python -ErrorAction SilentlyContinue }
    if ($py) {
        & $py.Source (Join-Path $tools "extract_telemetry.py") `
            --platform win --log $log.FullName --out $out --commit $commit 2>$null | Out-Null
        if (($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $out)) { $done = $true }
    }
    if (-not $done) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tools "extract_telemetry.ps1") `
            -Log $log.FullName -Out $out -Commit $commit 2>$null | Out-Null
    }
    if (-not (Test-Path -LiteralPath $out)) { exit 0 }

    # samples=0 不上传，避免空日志覆盖有效数据
    $samples = 0
    try { $samples = (Get-Content -LiteralPath $out -Raw | ConvertFrom-Json).samples } catch {}
    if ($samples -lt 1) { exit 0 }

    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tools "push_telemetry.ps1") `
        -Json $out -Platform win -RepoRoot $RepoRoot 2>$null | Out-Null
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
