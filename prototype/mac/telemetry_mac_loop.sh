#!/bin/zsh
# Mac 端无人值守遥测循环：定时从运行中的 screensender 日志提取脱敏指标并 push。
# 由 launchd 每 5 分钟调用一次；单次运行，不常驻、不抢屏幕、不移动光标。
# 设备 ID 由 push_telemetry.sh 用仓库外的随机值生成，主机名不进公开仓。

set -u
# 脚本在 prototype/mac/ 下，logs/ 与 screensender 都在这里。
MACDIR="$(cd "$(dirname "$0")" && pwd)"
cd "$MACDIR"
REPO="$(cd "$MACDIR/../.." && pwd)"
TOOLS="$REPO/tools"

LOG="$(ls -t logs/sender_*.log 2>/dev/null | head -1)"
[ -z "$LOG" ] && exit 0           # 没运行就什么都不做

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/secdisplay-tel.XXXXXX")" || exit 0
trap 'rm -rf "$STAGE"' EXIT
python3 "$TOOLS/extract_telemetry.py" --platform mac \
    --log "$LOG" --out "$STAGE/mac.json" \
    --commit "$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)" \
    >/dev/null 2>&1 || exit 0

# 空日志（无统计行）不上传，避免覆盖掉已有的有效指标
SAMPLES="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("samples",0))' "$STAGE/mac.json" 2>/dev/null)"
[ "${SAMPLES:-0}" -lt 1 ] && exit 0

"$TOOLS/push_telemetry.sh" "$STAGE/mac.json" mac >/dev/null 2>&1 || true
