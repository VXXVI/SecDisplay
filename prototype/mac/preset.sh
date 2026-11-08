#!/bin/zsh
# 切换画质/流畅度档位
# 用法: ./preset.sh sharp|balanced|smooth|fast|status
set -u
cd "$(dirname "$0")"
P="${1:-status}"

case "$P" in
status)
    if pgrep -f screensender >/dev/null; then
        echo "运行中 pid=$(pgrep -f screensender|head -1)"
        echo "当前档位: $(cat .preset 2>/dev/null || echo balanced)"
        tail -2 "$(ls -t logs/*.log 2>/dev/null | head -1)" 2>/dev/null
    else
        echo "未运行"
    fi
    ;;
sharp|balanced|smooth|fast)
    pkill -TERM -f screensender 2>/dev/null
    sleep 2
    echo "$P" > .preset
    mkdir -p logs
    SECDISPLAY_PRESET="$P" nohup ./screensender > "logs/sender_$(date +%Y%m%d_%H%M%S)_$P.log" 2>&1 &
    sleep 3
    echo "已切换到 $P"
    grep -E "预设档位|虚拟屏就绪|抓屏已启动" "$(ls -t logs/*.log|head -1)"
    ;;
*)
    echo "用法: $0 sharp|balanced|smooth|fast|status"
    exit 1
    ;;
esac
