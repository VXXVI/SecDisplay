#!/bin/zsh
# 后台运行 Mac 发送端，日志写入 logs/sender_日期.log
#
# 用法:
#   ./run.sh              启动（若已在运行则提示）
#   ./run.sh stop         停止
#   ./run.sh status       查看状态
#   ./run.sh log          实时看日志
#   ./run.sh restart      重启
#   ./run.sh sign         仅重签身份（不启动）
#
# 辅助功能授权：二进制用稳定签名身份 com.secdisplay.screensender，
# 重编后授权不会失效。首次需手动授权一次，见 ./run.sh doctor。

set -u
cd "$(dirname "$0")"

BIN=./screensender
LOGDIR=logs
PIDFILE=/tmp/secdisplay-sender.pid
SIGN_ID=com.secdisplay.screensender

mkdir -p "$LOGDIR"

# 用固定 designated requirement 重签二进制。
# 背景：swiftc 默认产出 ad-hoc 签名，DR=cdhash，每次重编 cdhash 都变，
# TCC(辅助功能)把授权绑在 DR 上，于是每次重编都要重新授权。
# 改成 identifier 型 DR 后，TCC 存的是固定的 identifier，与代码内容无关，
# 重编多少次授权都保持有效。不需要 Apple 开发者证书，纯本地可用。
sign_binary() {
    codesign --force --sign - \
        --identifier "$SIGN_ID" \
        -r="designated => identifier \"$SIGN_ID\"" \
        "$BIN" >/dev/null 2>&1 || {
        echo "签名失败，辅助功能授权会在重编后失效" >&2
        return 1
    }
    return 0
}

# 校验二进制当前是否具备稳定身份
sign_ok() {
    codesign -d -r- "$BIN" 2>/dev/null | grep -q "identifier \"$SIGN_ID\""
}

# 是否还有 SecDisplay 虚拟屏残留在线（按 EDID 三元组识别，不误伤 Sidecar）。
# 用一个签了稳定身份的小探针查询，探针只在存在时编译一次并缓存。
VDPROBE="$LOGDIR/.vdprobe"
vd_stale() {
    if [ ! -x "$VDPROBE" ]; then
        cat > "$VDPROBE.swift" <<'SWIFT'
import CoreGraphics
var n:UInt32=0; CGGetOnlineDisplayList(0,nil,&n)
var ids=[CGDirectDisplayID](repeating:0,count:Int(n)); CGGetOnlineDisplayList(n,&ids,&n)
for id in ids.prefix(Int(n)) {
    if CGDisplayVendorNumber(id)==0xEEEE && CGDisplayModelNumber(id)==0x5344 {
        print("STALE"); exit(0)
    }
}
print("CLEAN")
SWIFT
        swiftc -O "$VDPROBE.swift" -o "$VDPROBE" 2>/dev/null || return 1
        rm -f "$VDPROBE.swift"
    fi
    [ "$("$VDPROBE" 2>/dev/null)" = "STALE" ]
}

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
        sign_binary || exit 1
        echo "已重签稳定身份: $SIGN_ID"
    elif ! sign_ok; then
        # 二进制是旧的 ad-hoc 签名（或首次拉仓库没编过），补一次稳定签名
        sign_binary || exit 1
        echo "已补稳定身份: $SIGN_ID"
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
    # 等进程退出（signal handler -> 主循环 -> CDVirtualDisplayDestroy）
    for i in {1..60}; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    # 再等虚拟屏从在线列表消失；WindowServer 同步销毁是异步的，
    # 只等进程退出就 restart 会撞「残留屏占住位置」。
    for i in {1..40}; do
        vd_stale || break
        sleep 0.1
    done
    rm -f "$PIDFILE"
    if vd_stale; then
        echo "已停止，但检测到残留虚拟屏（进程被强杀时 WindowServer 可能保留）"
        echo "  下次 start 若报「创建被拒绝」，注销并重新登录即可清除"
    else
        echo "已停止，虚拟屏已清理"
    fi
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
sign)
    sign_binary && echo "已重签稳定身份: $SIGN_ID" || exit 1
    ;;
doctor)
    echo "=== 签名身份"
    if sign_ok; then
        echo "  稳定身份 OK: $SIGN_ID（重编不会丢授权）"
    else
        echo "  缺少稳定身份，正在补签..."
        sign_binary && echo "  已补签: $SIGN_ID"
    fi
    codesign -d -r- "$BIN" 2>/dev/null | tail -1 | sed 's/^/  /'
    echo ""
    echo "=== 辅助功能授权"
    # 直接读 TCC 数据库里这个身份的授权记录，最可靠。
    # 数据库受 SIP 保护，读不到时退回看最近启动日志有无告警。
    tccdb="/Library/Application Support/com.apple.TCC/TCC.db"
    granted=$(sqlite3 "$tccdb" \
        "select auth_value from access where service='kTCCServiceAccessibility' and client='$SIGN_ID' limit 1;" 2>/dev/null)
    logwarn=$(ls -t "$LOGDIR"/sender_*.log 2>/dev/null | head -1 | xargs grep -l "未获得辅助功能权限" 2>/dev/null)
    if [ "$granted" = "2" ]; then
        echo "  已授权（副屏点击/滚轮可用）"
    elif [ -z "$granted" ] && [ -z "$logwarn" ]; then
        echo "  无法确认（TCC 库读不到且无日志），按下面步骤授权一次即可"
    else
        echo "  未授权：副屏上的点击/滚轮不会生效"
    fi
    echo ""
    echo "  首次授权（之后重编不用再授权，身份固定）："
    echo "    1. 系统设置 → 隐私与安全性 → 辅助功能"
    echo "    2. 点 + ，Cmd+Shift+G 粘贴："
    echo "       $(cd "$(dirname "$0")" && pwd)/screensender"
    echo "    3. 打开并确认开关为开"
    echo "    4. 完全重启服务：./run.sh restart"
    echo "  命令行重置授权：tccutil reset Accessibility $SIGN_ID"
    ;;
restart)
    "$0" stop
    sleep 1
    "$0" start
    ;;
*)
    echo "用法: $0 [start|stop|status|log|sign|doctor|restart]"
    exit 1
    ;;
esac
