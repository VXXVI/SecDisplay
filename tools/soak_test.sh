#!/bin/bash
# soak_test.sh — SecDisplay 长期稳定性测试
#
# 每 INTERVAL 秒采一次两端指标，写 CSV，结束时输出摘要。
# 不修改任何配置，只读进程、日志、连接状态。
#
# 用法:
#   ./tools/soak_test.sh [时长秒数] [采样间隔秒数]
#   ./tools/soak_test.sh 7200 30        # 2 小时，30 秒一采
#
# 后台运行:
#   nohup ./tools/soak_test.sh 7200 30 >/dev/null 2>&1 &
#
# 看进度:
#   tail -f logs/soak/soak_*.log
#
# 停止:
#   pkill -f soak_test.sh

set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DURATION="${1:-7200}"
INTERVAL="${2:-30}"
OUTDIR="$REPO/logs/soak"
mkdir -p "$OUTDIR"
STAMP="$(date +%Y%m%d_%H%M%S)"
CSV="$OUTDIR/soak_$STAMP.csv"
CONSOLE="$OUTDIR/soak_$STAMP.log"

echo "ts,elapsed,mac_pid,mac_rss_mb,mac_cpu,mac_conn,mac_fps,mac_enc_ms,mac_inflight,mac_drop,mac_sent,win_pid,win_rss_mb,win_conn,win_recon,win_fps,win_pdrop,win_dfail,win_lat_ms,win_cursor" > "$CSV"

win_ssh() {
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=3 \
        secdisplay-win "$1" 2>/dev/null | tr -d '\r'
}

# PowerShell 走 EncodedCommand，避免 cmd 把引号吃掉。
PS_SCRIPT='
$p=Get-Process SecDisplayReceiver -ErrorAction SilentlyContinue
if($p){$a=1;$id=$p.Id;$rss=[int]($p.WorkingSet64/1MB)}else{$a=0;$id=0;$rss=0}
$log="C:\SecDisplay-Lab\prototype\windows\logs\ssh-receiver.log"
$last=""
if(Test-Path $log){$last=(Get-Content $log -Tail 1 -Encoding UTF8)}
$recon=0
if(Test-Path $log){$recon=(Get-Content $log -Tail 200 -Encoding UTF8)|Select-String -Pattern "2 秒后重连" -SimpleMatch|Measure-Object|Select-Object -ExpandProperty Count}
Write-Output ($a.ToString()+"|"+$id+"|"+$rss+"|"+$recon+"|"+$last)
'
PS_B64=$(printf '%s' "$PS_SCRIPT" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')

start=$(date +%s)
echo "start $(date '+%F %T') duration=${DURATION}s interval=${INTERVAL}s csv=$CSV"

while :; do
    now=$(date +%s)
    elapsed=$((now - start))
    [ "$elapsed" -ge "$DURATION" ] && break

    # ---------- Mac ----------
    mpid=$(pgrep -f "screensender" | head -1)
    if [ -n "${mpid:-}" ]; then
        mrss=$(ps -o rss= -p "$mpid" 2>/dev/null | awk '{printf "%d", $1/1024}')
        mcpu=$(ps -o %cpu= -p "$mpid" 2>/dev/null | tr -d ' ')
    else
        mpid=""; mrss=0; mcpu=0
    fi

    mconn=0
    lsof -nP -iTCP:9922 2>/dev/null | grep -q ESTABLISHED && mconn=1

    mlog=$(ls -t "$REPO/prototype/mac/logs"/sender_*.log 2>/dev/null | head -1)
    mline=$(grep -E "编码延迟" "$mlog" 2>/dev/null | tail -1)
    mfps=$(printf '%s' "$mline" | sed -n 's/.*发送 \([0-9]*\).*/\1/p')
    [ -n "$mfps" ] && mfps=$((mfps / 2))
    menc=$(printf '%s' "$mline" | sed -n 's/.*编码延迟 \([0-9.]*\) ms.*/\1/p')
    minflight=$(printf '%s' "$mline" | sed -n 's/.*在途 \([0-9]*\).*/\1/p')
    mdrop=$(printf '%s' "$mline" | sed -n 's/.*丢弃 \([0-9]*\).*/\1/p')
    msent=$(printf '%s' "$mline" | sed -n 's/.*发送 \([0-9]*\).*/\1/p')

    # ---------- Windows ----------
    # 一条 SSH 里跑 tasklist 和日志尾行。EncodedCommand 在这台 Windows 的
    # PowerShell 上没有输出，改回 cmd 原生命令，避免嵌套引号。
    win_raw=$(win_ssh 'tasklist /FI "IMAGENAME eq SecDisplayReceiver.exe" /FO CSV /NH & powershell -NoProfile -Command "Get-Content C:\SecDisplay-Lab\prototype\windows\logs\ssh-receiver.log -Tail 1 -Encoding UTF8"')

    win_proc=$(printf '%s' "$win_raw" | grep -i "SecDisplayReceiver" | head -1)
    win_line=$(printf '%s' "$win_raw" | grep -E "[0-9]\\.?[0-9]* fps" | tail -1)
    if [ -n "$win_proc" ]; then
        win_alive=1
        win_pid=$(printf '%s' "$win_proc" | cut -d',' -f2 | tr -d '"')
        # 内存字段是 "73,844 K"，含逗号，按引号切分取最后一个引号段。
        win_rss_kb=$(printf '%s' "$win_proc" | awk -F'"' '{print $10}' | tr -cd '0-9')
        win_rss=$((win_rss_kb / 1024))
    else
        win_alive=0; win_pid=0; win_rss=0
    fi
    win_conn=$win_alive
    win_recon=0
    if [ -n "$win_line" ]; then
        # 日志由 Windows ANSI 写盘，经 SSH 后中文标签会乱码，但字段位置固定，
        # 按空白分词取位置比匹配中文更稳。
        win_fps=$(printf '%s' "$win_line" | awk '{print $6}')
        win_pdrop=$(printf '%s' "$win_line" | awk '{print $14}' | tr -d '+')
        win_dfail=$(printf '%s' "$win_line" | awk '{print $38}')
        win_lat=$(printf '%s' "$win_line" | awk '{print $35}')
        win_cursor=$(printf '%s' "$win_line" | awk '{print $39}' | tr -cd '0-9')
    else
        win_fps=""; win_pdrop=""; win_dfail=""; win_lat=""; win_cursor=""
    fi

    line="$(date '+%F %T'),$elapsed,${mpid:-0},$mrss,$mcpu,$mconn,${mfps:-},${menc:-},${minflight:-},${mdrop:-},${msent:-},$win_pid,$win_rss,$win_conn,$win_recon,${win_fps:-},${win_pdrop:-},${win_dfail:-},${win_lat:-},${win_cursor:-}"
    echo "$line" >> "$CSV"
    echo "$line" >> "$CONSOLE"

    # 每 10 分钟在控制台打一行摘要
    if [ $((elapsed % 600)) -lt "$INTERVAL" ]; then
        echo "---- $(date '+%H:%M:%S') elapsed=${elapsed}s mac_conn=$mconn mac_fps=${mfps:-?} enc=${menc:-?}ms win_alive=$win_alive win_fps=${win_fps:-?} pdrop=${win_pdrop:-?} dfail=${win_dfail:-?} recon=$win_recon"
    fi

    sleep "$INTERVAL"
done

# ---------- 摘要 ----------
echo ""
echo "===== soak summary $(date '+%F %T') ====="
awk -F, 'NR>1 {
    n++;
    if ($6==1) mc++;
    if ($14==1) wc++;
    fps+=$7; enc+=$8; lat+=$19;
    drop=$10; pdrop=$17; dfail=$18; recon=$15;
    if ($4>mrss) mrss=$4;
    if ($13>wrss) wrss=$13;
    if (fpsn==0) { fps0=$7; rss0=$4; wrss0=$13 }
    fpsn++;
} END {
    if (n==0) { print "no samples"; exit }
    printf "samples=%d mac_alive=%.1f%% win_alive=%.1f%%\n", n, mc*100/n, wc*100/n;
    printf "mac_fps_avg=%.1f enc_avg=%.1fms\n", fps/n, enc/n;
    printf "win_lat_avg=%.1fms recon_near=%d pdrop_total=%d dfail_total=%d\n", lat/n, recon, pdrop, dfail;
    printf "mac_rss %d -> %d MB (max %d)\n", rss0, $4, mrss;
    printf "win_rss %d -> %d MB (max %d)\n", wrss0, $13, wrss;
}' "$CSV" | tee -a "$CONSOLE"

echo "csv=$CSV"
echo "console=$CONSOLE"
