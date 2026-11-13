#!/bin/zsh
# 切换画质/流畅度档位
# 用法: ./preset.sh sharp|balanced|smooth|compact|fast|status
#
# 切档只写 .preset 并调用 run.sh restart，由 run.sh 统一负责：
# 重编(若源码更新)、重签稳定身份、干净停虚拟屏、按 .preset 设置
# SECDISPLAY_PRESET 再启动。旧版本用 pkill 裸启，曾撞「残留虚拟屏占位置」。
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
        echo "当前档位: $(cat .preset 2>/dev/null || echo balanced)"
    fi
    ;;
sharp|balanced|smooth|compact|fast)
    echo "$P" > .preset
    echo "已写入档位 $P，重启发送端以应用..."
    ./run.sh restart
    ;;
*)
    echo "用法: $0 sharp|balanced|smooth|compact|fast|status"
    exit 1
    ;;
esac
