#!/bin/bash
# 开发进度守护：每 60 秒记录一次关键状态，变化时额外标注。
# 用法：nohup ./tools/dev_watch.sh >/dev/null 2>&1 &
# 日志：logs/dev_watch.log（仓库根目录）
#
# 监控项：
#   虚拟屏是否在线（vendor 0xeeee）
#   screensender 进程数
#   9922 是否 LISTEN
#   git 是否落后远端（Windows 侧回传）
#   是否有新的 RESULT/任务状态变化

set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
LOG="$REPO/logs/dev_watch.log"
mkdir -p "$REPO/logs"

prev=""
while true; do
    ts=$(date '+%Y-%m-%d %H:%M:%S')

    # 虚拟屏：优先用 CG 枚举，失败退回 system_profiler
    vd=$(/usr/sbin/system_profiler SPDisplaysDataType 2>/dev/null | grep -c "SecDisplay")
    proc=$(pgrep -f "screensender" 2>/dev/null | wc -l | tr -d ' ')
    port=$(lsof -nP -iTCP:9922 -sTCP:LISTEN 2>/dev/null | grep -c LISTEN)

    # git：落后远端几条（Windows 侧可能有新派发或回传）
    git fetch -q origin 2>/dev/null || true
    behind=$(git rev-list --count HEAD..origin/main 2>/dev/null || echo "?")
    ahead=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo "?")
    head=$(git log -1 --format='%h %s' 2>/dev/null | cut -c1-60)

    # 任务单状态快照（只取未完成的）
    tasks=$(grep -l "状态：待执行\|状态：进行中" research/TASK-*.md 2>/dev/null | wc -l | tr -d ' ')
    results=$(ls research/RESULT-*.md 2>/dev/null | wc -l | tr -d ' ')

    line="$ts vd=$vd proc=$proc port=$port behind=$behind ahead=$ahead tasks_open=$tasks results=$results head=$head"

    if [ "$line" != "$prev" ]; then
        echo "$line" >> "$LOG"
        prev="$line"
    else
        # 状态未变也每 10 分钟留一条心跳，避免日志看不出进程还活着
        if [ $(( $(date +%s) % 600 )) -lt 60 ]; then
            echo "$line (heartbeat)" >> "$LOG"
        fi
    fi

    sleep 60
done
