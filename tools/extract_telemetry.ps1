# extract_telemetry.ps1
# Windows 端（无 Python 时）从 diag / fullscreen 日志提取脱敏指标 JSON。
# 输出 schema 与 tools/extract_telemetry.py 的 --platform win 完全一致，
# CI 会用同一份样本日志对比两者，防止两份正则漂移。
#
# 用法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File extract_telemetry.ps1 `
#       -Log logs\diag.log -Out telemetry\_stage\win.json [-Commit abc1234]
param(
    [Parameter(Mandatory=$true)][string]$Log,
    [Parameter(Mandatory=$true)][string]$Out,
    [string]$Commit = "unknown"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Log)) {
    Write-Error "日志文件不存在: $Log"
    exit 1
}
$text = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Log), [System.Text.Encoding]::UTF8)
$lines = $text -split "`r?`n"

function Collect-Doubles([object[]]$lines, [string]$pattern) {
    $res = New-Object System.Collections.ArrayList
    foreach ($ln in $lines) {
        foreach ($m in [regex]::Matches($ln, $pattern)) {
            [void]$res.Add([double]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture))
        }
    }
    return ,$res.ToArray()
}
function Collect-Ints([object[]]$lines, [string]$pattern) {
    $res = New-Object System.Collections.ArrayList
    foreach ($ln in $lines) {
        foreach ($m in [regex]::Matches($ln, $pattern)) {
            [void]$res.Add([int64]::Parse($m.Groups[1].Value))
        }
    }
    return ,$res.ToArray()
}
function Round2([double]$x) { return [math]::Round($x, 2) }
function Get-Agg([double[]]$arr) {
    if ($null -eq $arr -or $arr.Length -eq 0) { return $null }
    $s = @($arr | Sort-Object)
    $n = $s.Length
    $i95 = [math]::Min($n - 1, [math]::Floor(0.95 * ($n - 1)))
    $mid = [math]::Floor($n / 2)
    if ($n % 2 -eq 1) { $median = [double]$s[$mid] }
    else { $median = ([double]$s[$mid - 1] + [double]$s[$mid]) / 2.0 }
    return [ordered]@{
        min = Round2 ([double]$s[0])
        median = Round2 $median
        p95 = Round2 ([double]$s[$i95])
        max = Round2 ([double]$s[$n - 1])
    }
}
function Last-Val([double[]]$arr) {
    if ($null -eq $arr -or $arr.Length -eq 0) { return $null }
    return Round2 ([double]$arr[$arr.Length - 1])
}

# 只统计状态行，避免别的日志里的数字混进来
$stat = @($lines | Where-Object { $_ -match "附加延迟" })
$blobLines = @($stat)

$packets  = Collect-Doubles $blobLines "包\s+(\d+)"
$decoded  = Collect-Doubles $blobLines "解码\s+(\d+)\(\+\d+\)"
$decInc   = Collect-Doubles $blobLines "解码\s+\d+\(\+(\d+)\)"
$mbps     = Collect-Doubles $blobLines "([\d.]+)\s*Mbps"
$extra    = Collect-Doubles $blobLines "附加延迟\s+([\d.]+)\s*ms"
$fails    = Collect-Doubles $blobLines "解码失败\s+(\d+)"
# 356f99d 起统计行新增三字段；旧日志无这些字段时数组为空，Get-Agg/Last-Val 返回 null
$peakFps  = Collect-Doubles $blobLines "峰值\s+([\d.]+)\s*fps"
$cursorInc= Collect-Doubles $blobLines "光标\+\s*(\d+)"
$inputLast= Collect-Doubles $blobLines "输入\s+(\d+)"

$lw = $lh = $pw = $ph = $null
$m = [regex]::Match($text, "坐标基准:\s*逻辑\s*(\d+)x(\d+)（物理\s*(\d+)x(\d+)")
if ($m.Success) {
    $lw = [int]$m.Groups[1].Value; $lh = [int]$m.Groups[2].Value
    $pw = [int]$m.Groups[3].Value; $ph = [int]$m.Groups[4].Value
}
$coordSource = $null
if ($text -match "命令行指定") { $coordSource = "explicit" }
elseif ($text -match "自动 2x") { $coordSource = "auto2x" }

$presentMode = $null
if ($text -match "呈现方式:\s*垂直同步") { $presentMode = "vsync" }
elseif ($text -match "呈现方式:\s*免同步") { $presentMode = "tearing" }

$decoderHw = $null
$m = [regex]::Match($text, "解码器就绪\s*\d+x\d+（(硬件|软件)）")
if ($m.Success) { $decoderHw = ($m.Groups[1].Value -eq "硬件") }

$clientW = $clientH = $null
$m = [regex]::Match($text, "窗口客户区\s*(\d+)x(\d+)")
if ($m.Success) { $clientW = [int]$m.Groups[1].Value; $clientH = [int]$m.Groups[2].Value }

$fullscreen = ($text -match "已切换到全屏") -or ($text -match "全屏目标尺寸")

$warnings = New-Object System.Collections.ArrayList
if ($fails.Length -gt 0 -and ($fails | Measure-Object -Maximum).Maximum -gt 0) {
    [void]$warnings.Add("decode_fail")
}
if ($text -match "没有解码器接受 D3D 管理器" -or $text -match "退回软件解码") {
    [void]$warnings.Add("software_decode")
}
if ($text -match "窗口创建失败") { [void]$warnings.Add("window_create_failed") }
if ($text -match "连接失败") { [void]$warnings.Add("connect_failed") }

$doc = [ordered]@{
    schema        = 1
    platform      = "win"
    generated_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    commit        = $Commit.Substring(0, [math]::Min(12, $Commit.Length))
    coord         = [ordered]@{
        logical_w = $lw; logical_h = $lh
        physical_w = $pw; physical_h = $ph; source = $coordSource
    }
    status        = [ordered]@{
        present_mode = $presentMode; decoder_hw = $decoderHw
        client_w = $clientW; client_h = $clientH; fullscreen = $fullscreen
    }
    samples       = $stat.Length
    metrics       = [ordered]@{
        packets_last       = Last-Val $packets
        decoded_last       = Last-Val $decoded
        decoded_per_sample = Get-Agg $decInc
        decode_fail_last   = Last-Val $fails
        mbps               = Get-Agg $mbps
        extra_latency_ms   = Get-Agg $extra
        peak_fps           = Get-Agg $peakFps
        cursor_pkts_total  = if ($cursorInc.Length -gt 0) { [int64](($cursorInc | Measure-Object -Sum).Sum) } else { 0 }
        input_pkts_last    = Last-Val $inputLast
    }
    warnings      = @($warnings.ToArray())
}

$absOut = [System.IO.Path]::GetFullPath($Out)
$outDir = [System.IO.Path]::GetDirectoryName($absOut)
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
$json = $doc | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($absOut, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("wrote " + $Out + " samples=" + $stat.Length)
