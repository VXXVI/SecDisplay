#!/bin/bash
# 清理 LaunchServices / 权限列表里的 SecDisplay 残留条目。
#
# 症状：Spotlight / 启动台 / 系统设置的隐私页里出现多个空白图标的 SecDisplay，
# 点进去打不开或指向已删除的路径。
#
# 原因：secdisplay 开发过程中，构建产物曾在仓库目录（prototype/mac/SecDisplay.app
# 和 prototype/_scratch/SecDisplay.app）里短暂存在过。只要 .app 在硬盘上出现过，
# LaunchServices 就会按路径登记一条记录；后来把 .app 删掉，登记记录不会跟着消失，
# 只能靠重建数据库清理。build_app.sh 现在改为在系统临时目录构建，从源头不再产生
# 新的仓库路径记录，但历史上已经写入的记录需要跑一次本脚本。
#
# 用法：
#   ./reset_launch_services.sh          # 清残留（会重建 LaunchServices / 启动台数据库）
#   ./reset_launch_services.sh --tcc    # 同时重置屏幕录制与辅助功能授权
#
# --tcc 会让 SecDisplay 下次启动时重新请求一次屏幕录制与辅助功能权限。
# 只有在「权限页里 hints 与真实路径对不上」或「反复授权仍无效」时才需要。

set -uo pipefail

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
SIGN_ID="com.secdisplay.screensender"

echo "=== 1. 检查硬盘上的 SecDisplay.app ==="
# 两种来源都要查：
#   mdfind 走 Spotlight 索引，快但可能漏掉未索引的目录（比如 .git 里的、刚拷进来的）
#   find 直接扫文件系统，慢一些但可靠
# 只保留 .app 目录本身，排除里面的可执行文件和嵌套路径。
FOUND=$(
    {
        mdfind -name "SecDisplay.app" 2>/dev/null
        find /Applications /Users/"$USER" -maxdepth 6 -name "SecDisplay.app" -type d 2>/dev/null
    } | grep -E '\.app$' | grep -v "^/Applications/SecDisplay.app$" | sort -u || true
)
if [ -n "$FOUND" ]; then
    echo "发现多余副本（建议删除）:"
    echo "$FOUND" | sed 's/^/  /'
    echo
    read -r -p "删除以上副本？[y/N] " ans
    if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
        while IFS= read -r p; do
            [ -n "$p" ] && rm -rf "$p" && echo "  已删 $p"
        done <<< "$FOUND"
    fi
else
    echo "未发现多余副本（硬盘上只有 /Applications/SecDisplay.app）"
fi
echo

echo "=== 2. 重建 LaunchServices 数据库 ==="
# -kill 停掉当前进程，-r 递归重建，-domain 三个域都覆盖。
# 这一步会重建整个数据库，耗时约十几秒，期间 Spotlight 可能短暂无响应。
"$LSREGISTER" -kill -r -domain local -domain system -domain user
echo "已重建 LaunchServices 数据库"
echo

echo "=== 3. 重建启动台数据库 ==="
defaults write com.apple.dock ResetLaunchPad -bool true
killall Dock 2>/dev/null || true
echo "已重建启动台数据库（Dock 会重启一次）"
echo

if [ "${1:-}" = "--tcc" ]; then
    echo "=== 4. 重置 TCC 授权 ==="
    # 只重置本应用的两项授权，不动其它应用。
    tccutil reset ScreenCapture "$SIGN_ID" 2>/dev/null || echo "  屏幕录制重置失败（可能没有现存记录）"
    tccutil reset Accessibility "$SIGN_ID" 2>/dev/null || echo "  辅助功能重置失败（可能没有现存记录）"
    echo "已重置。下次启动 SecDisplay 时需重新授权屏幕录制与辅助功能。"
    echo
fi

echo "=== 完成 ==="
echo
echo "现在检查："
echo "  1. Spotlight 搜 SecDisplay —— 应该只剩一条，带图标"
echo "  2. 启动台里搜 SecDisplay —— 应该只剩一条"
echo
echo "如果仍有残留，说明还留有别的 .app 副本。用下面命令定位："
echo "  mdfind -name 'SecDisplay.app'"
echo
echo "确认硬盘上只有 /Applications/SecDisplay.app 之后再重跑本脚本。"