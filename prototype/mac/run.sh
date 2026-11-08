#!/bin/zsh
# 后台运行 Mac 发送端，日志写入 logs/sender_日期.log
#
# 用法:
#   ./run.sh              启动（若已在运行则提示）
#   ./run.sh stop         停止
#   ./run.sh status       查看状态
#   ./run.sh log          实时看日志
#   ./run.sh restart      重启

set -u
cd "$(dirname "$0")"

BIN=./screensender
LOGDIR=logs
PIDFILE=/tmp/secdisplay-sender.pid

mkdir -p "$LOGDIR"

find_pid() {
    if [ -f "$PIDFILE" ]; then
        local p
        p=$(cat "$PIDFILE" 2>/dev/null)
        if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
            echo "$p"
            return
        fi
    fi
    pgrep -f "screensender" | head -1
}

case "${1:-start}" in
start)
    pid=$(find_pid)
    if [ -n "$pid" ]; then
        echo "已在运行，pid=$pid"
        exit 0
    fi
    # 源码比二进制新就重编，避免跑到旧版本
    need_build=0
    if [ ! -x "$BIN" ]; then
        need_build=1
    elif [ Sources/ScreenSender.swift -nt "$BIN" ]; then
        need_build=1
        echo "源码已更新，重新编译"
    fi
    if [ "$need_build" = "1" ]; then
        echo "编译中..."
        swiftc -O Sources/ScreenSender.swift -o screensender || exit 1
    fi
    log="$LOGDIR/sender_$(date +%Y%m%d_%H%M%S).log"
    echo "启动，日志: $log"
    nohup "$BIN" > "$log" 2>&1 &
    echo $! > "$PIDFILE"
    sleep 2
    if kill -0 "$(cat $PIDFILE)" 2>/dev/null; then
        echo "已启动 pid=$(cat $PIDFILE)"
        echo "--- 前几行日志 ---"
        head -6 "$log"
    else
        echo "启动失败，日志内容："
        cat "$log"
        exit 1
    fi
    ;;
stop)
    pid=$(find_pid)
    if [ -z "$pid" ]; then
        echo "未在运行"
        exit 0
    fi
    echo "停止 pid=$pid"
    kill -TERM "$pid"
    # 等它清理虚拟屏
    for i in {1..30}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    rm -f "$PIDFILE"
    echo "已停止"
    ;;
status)
    pid=$(find_pid)
    if [ -n "$pid" ]; then
        echo "运行中 pid=$pid"
        latest=$(ls -t $LOGDIR/sender_*.log 2>/dev/null | head -1)
        if [ -n "$latest" ]; then
            echo "--- 最近日志 ---"
            tail -5 "$latest"
        else
            echo "（日志文件在 $LOGDIR 下尚未生成）"
        fi
    else
        echo "未运行"
    fi
    ;;
log)
    latest=$(ls -t $LOGDIR/sender_*.log 2>/dev/null | head -1)
    if [ -z "$latest" ]; then
        echo "还没有日志文件，先运行 $0 start"
        exit 1
    fi
    tail -f "$latest"
    ;;
restart)
    "$0" stop
    sleep 1
    "$0" start
    ;;
*)
    echo "用法: $0 [start|stop|status|log|restart]"
    exit 1
    ;;
esac
