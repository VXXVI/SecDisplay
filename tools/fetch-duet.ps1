# 在 Windows 上提取 Duet 静态线索，并把整个安装目录传回 Mac 供 REA 分析
# 用法（PowerShell）：
#   powershell -ExecutionPolicy Bypass -File fetch-duet.ps1
# 前置：Mac 端先跑 tools/recv-duet.py 等待接收（可选，不影响字符串输出）
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$root = 'C:\Program Files\Kairos\Duet Display'
$macIP = '10.10.10.1'
$macPort = 9933

if (-not (Test-Path $root)) {
    Write-Host "找不到 $root，请确认 Duet 装在这个路径" -ForegroundColor Red
    $alt = Get-ChildItem 'C:\Program Files','C:\Program Files (x86)' -Directory -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match 'duet|kairos' } | Select-Object -ExpandProperty FullName
    if ($alt) { Write-Host "可能的路径：`n$($alt -join "`n")" }
    exit 1
}

Write-Host "========== 1. 文件清单 =========="
Get-ChildItem $root -Recurse -File |
    Sort-Object Length -Descending |
    Select-Object -First 40 @{N='MB';E={[math]::Round($_.Length/1MB,2)}}, FullName |
    Format-Table -AutoSize | Out-String -Width 200

# 挑主要二进制做字符串提取
$targets = Get-ChildItem $root -Recurse -File |
    Where-Object { $_.Extension -in '.exe','.dll','.sys' } |
    Sort-Object Length -Descending | Select-Object -First 8

$kw = 'h264|h265|hevc|avc1|nvenc|quicksync|qsv|videotoolbox|bitrate|framerate|frame_rate|fps|resolution|gop|keyframe|idr|1920|2240|2560|2880|3840|cursor|pointer|mouse|hid|latency|buffer|queue|jitter|vsync|v-sync|tearing|present|swapchain|usb|tcp|udp|protocol|encode|decode|quality|preset|60fps|120hz'

Write-Host "========== 2. 关键字符串（把这一段整段贴给 Mac） =========="
foreach ($f in $targets) {
    Write-Host "`n----- $($f.Name) ($([math]::Round($f.Length/1MB,2)) MB) -----"
    try {
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        $text  = [System.Text.Encoding]::ASCII.GetString($bytes)
        [regex]::Matches($text, '[\x20-\x7E]{6,}') |
            ForEach-Object { $_.Value } |
            Where-Object { $_ -match $kw } |
            Sort-Object -Unique |
            Select-Object -First 60
    } catch { Write-Host "  读取失败: $_" }
}

Write-Host "`n========== 3. 传文件到 Mac =========="
$zip = Join-Path $env:TEMP 'duet-bin.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
try {
    Compress-Archive -Path (Join-Path $root '*') -DestinationPath $zip -CompressionLevel Fastest -ErrorAction Stop
    $data = [System.IO.File]::ReadAllBytes($zip)
    Write-Host "打包完成 $([math]::Round($data.Length/1MB,2)) MB，连接 $macIP`:$macPort ..."
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect($macIP, $macPort)
    $ns = $tcp.GetStream()
    $len = [BitConverter]::GetBytes([int64]$data.Length)
    if (-not [BitConverter]::IsLittleEndian) { [Array]::Reverse($len) }
    $ns.Write($len, 0, 8)
    $ns.Write($data, 0, $data.Length)
    $ns.Flush(); $tcp.Close()
    Write-Host "已发送，Mac 端会显示接收结果" -ForegroundColor Green
} catch {
    Write-Host "传输跳过（Mac 端没开接收器，或链路不通）：$_" -ForegroundColor Yellow
    Write-Host "字符串结果不受影响，先把第 2 段贴过来即可。"
}
