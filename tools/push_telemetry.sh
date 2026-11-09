#!/bin/zsh
# 把一份 JSON 指标文件提交并推送到当前仓库的 telemetry/ 目录。
#
# 用法:
#   ./push_telemetry.sh <json文件> <mac|win>
#
# 设计要点:
#   * 只 add 目标 json 文件，绝不整仓 add
#   * 设备标识用仓库外的稳定随机 ID，绝不把主机名带进公开仓
#   * 指标未变化（忽略时间戳/commit）时不提交，避免空提交洪水
#   * 上传前 pull --rebase；冲突只 abort，不动用户暂存区
#   * 无网络 / 无变更时静默退出，不阻塞定时任务
#   * mkdir 原子锁（macOS 无 flock），带陈旧锁回收
set -u
cd "$(dirname "$0")/.."
REPO="$(pwd)"

JSON="${1:-}"
SUBDIR="${2:-misc}"
if [ -z "$JSON" ] || [ ! -f "$JSON" ]; then
    echo "用法: $0 <json文件> <mac|win>" >&2
    exit 1
fi
case "$SUBDIR" in
    mac|win) ;;
    *) SUBDIR="misc" ;;
esac

# 稳定设备 ID：存在用户主目录（仓库外），首次运行生成一次。
# 主机名常含用户名，公开仓不能出现，因此用随机 ID。
IDF="$HOME/.secdisplay-device-id"
LABEL=""
[ -f "$IDF" ] && LABEL="$(tr -cd 'A-Za-z0-9' < "$IDF" 2>/dev/null | cut -c1-12)"
if [ -z "$LABEL" ]; then
    if command -v openssl >/dev/null 2>&1; then
        LABEL="$(openssl rand -hex 4)"
    else
        LABEL="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' | cut -c1-8)"
    fi
    [ -z "$LABEL" ] && LABEL="dev$$"
    printf '%s' "$LABEL" > "$IDF" && chmod 600 "$IDF" 2>/dev/null
fi

# 原子锁：mkdir 是原子操作，比 macOS 缺失的 flock 可靠。
# 超过 10 分钟视为陈旧锁并回收，防止上次异常退出后永久卡死。
LOCKD="${TMPDIR:-/tmp}/secdisplay-telemetry.lock.d"
if ! mkdir "$LOCKD" 2>/dev/null; then
    if [ ! -f "$LOCKD/t" ] || [ -n "$(find "$LOCKD/t" -mmin +10 2>/dev/null)" ]; then
        rm -rf "$LOCKD"
        mkdir "$LOCKD" 2>/dev/null || exit 0
    else
        exit 0
    fi
fi
: > "$LOCKD/t"
trap 'rm -rf "$LOCKD" 2>/dev/null' EXIT

DEST="telemetry/$SUBDIR/$LABEL.json"
mkdir -p "$(dirname "$DEST")"

# 比较时忽略时间戳和 commit：指标没变就不产生新提交。
# 用 Python 做结构化比较，不依赖 JSON 是单行还是多行（grep 逐行过滤会误删整行）。
if [ -f "$DEST" ] && python3 - "$JSON" "$DEST" <<'PYEOF'
import json, sys
def load(p):
    try:
        d = json.load(open(p, encoding="utf-8"))
        d.pop("generated_utc", None)
        d.pop("commit", None)
        return d
    except Exception:
        return None
sys.exit(0 if load(sys.argv[1]) == load(sys.argv[2]) else 1)
PYEOF
then
    exit 0
fi

cp "$JSON" "$DEST"

git -C "$REPO" pull --rebase --autostash origin main >/dev/null 2>&1 || {
    # rebase --abort 本身安全；绝不做 git reset，那会撤出用户已暂存的内容
    git -C "$REPO" rebase --abort >/dev/null 2>&1
    exit 0
}

git -C "$REPO" add -- "$DEST" >/dev/null 2>&1 || exit 0
if git -C "$REPO" diff --cached --quiet -- "$DEST"; then
    exit 0
fi

git -C "$REPO" commit -q -m "telemetry($SUBDIR/$LABEL): auto update" >/dev/null 2>&1 || exit 0
git -C "$REPO" push -q origin main >/dev/null 2>&1 || exit 0

echo "pushed $DEST"
