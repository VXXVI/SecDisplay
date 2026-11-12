#!/bin/bash
# Phase1 自适应码率验收脚本
#
# 前置：发送端已在运行（./run.sh start），虚拟屏在线（vendor 0xeeee）
# 用法：./tools/phase1_check.sh [运动秒数]
#
# 流程：
#   1. 记录当前最新日志文件
#   2. 跑 motionloader 制造运动负载
#   3. 再等 30 秒静止，观察码率回升
#   4. 输出降档/回升摘要与结论

set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

MOTION_SECS="${1:-60}"
WAIT_AFTER=30
LOGDIR="prototype/mac/logs"

# 确认发送端在跑
if ! pgrep -f screensender >/dev/null 2>&1; then
    echo "错误：screensender 未运行，先 ./prototype/mac/run.sh start"
    exit 2
fi
if ! lsof -nP -iTCP:9922 -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then
    echo "错误：9922 未监听"
    exit 2
fi

LOG=$(ls -t "$LOGDIR"/sender_*.log 2>/dev/null | head -1)
if [ -z "$LOG" ]; then
    echo "错误：找不到发送端日志"
    exit 2
fi
echo "日志：$LOG"
BASE_LINES=$(wc -l < "$LOG")
echo "起始行号：$BASE_LINES"

echo "开始运动负载 ${MOTION_SECS}s..."
./tools/motionloader "$MOTION_SECS" >/tmp/phase1_motion.out 2>&1 &
MOTION_PID=$!
wait "$MOTION_PID" 2>/dev/null

echo "运动结束，静止等待 ${WAIT_AFTER}s 观察回升..."
sleep "$WAIT_AFTER"

echo
echo "===== 本轮新增日志（码率相关）====="
tail -n +$((BASE_LINES + 1)) "$LOG" | grep -aE "健康度|码率|静止回升|编码延迟" | tail -40

echo
echo "===== 结论 ====="
ADDED=$(tail -n +$((BASE_LINES + 1)) "$LOG")
DOWN=$(echo "$ADDED" | grep -ac "码率下调")
UP=$(echo "$ADDED" | grep -ac "静止回升\|码率回升")
echo "下调次数：$DOWN"
echo "回升次数：$UP"
if [ "$DOWN" -eq 0 ]; then
    echo "提示：本轮未触发下调，可能是负载不足或健康度未过 1.15"
fi
if [ "$UP" -eq 0 ]; then
    echo "提示：静止后未见回升，检查 captureFps 是否 < 10"
fi
echo
echo "人工核对项："
echo "  1. 两次下调间隔应 >= 10 秒（冷却）"
echo "  2. 单次降幅约 10%"
echo "  3. 静止后每 6 秒回升约 10%"
echo "  4. 默认码率应在 30~40 Mbps（1600x1000@60 估算约 34）"
