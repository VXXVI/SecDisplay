#!/bin/zsh
# 安装/卸载 Mac 端无人值守遥测（launchd，每 5 分钟一次）。
# 只从运行中的日志读指标，不碰屏幕、不移动光标、不常驻进程。
#
#   ./install_telemetry.sh         安装
#   ./install_telemetry.sh remove  卸载
set -u
# 脚本本身就在 prototype/mac/ 下，MACDIR 必须是这里（循环脚本也在此）。
# 早期版本多 cd 了一级到 prototype/，导致 plist 指向不存在的路径、launchd 报 127。
MACDIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$MACDIR/../.." && pwd)"
TOOLS="$REPO/tools"
PLIST="$HOME/Library/LaunchAgents/com.secdisplay.telemetry.plist"

chmod +x "$TOOLS/extract_telemetry.py" "$TOOLS/summarize_telemetry.py" \
         "$TOOLS/push_telemetry.sh" "$MACDIR/telemetry_mac_loop.sh" 2>/dev/null

if [ "${1:-}" = "remove" ]; then
    launchctl unload "$PLIST" 2>/dev/null
    rm -f "$PLIST"
    rm -f /tmp/secdisplay-telemetry.out /tmp/secdisplay-telemetry.err
    echo "已卸载 Mac 遥测任务"
    exit 0
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.secdisplay.telemetry</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>$MACDIR/telemetry_mac_loop.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/secdisplay-telemetry.out</string>
    <key>StandardErrorPath</key>
    <string>/tmp/secdisplay-telemetry.err</string>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
</dict>
</plist>
PLIST

launchctl unload "$PLIST" 2>/dev/null
launchctl load "$PLIST"
echo "已安装 Mac 遥测任务，每 5 分钟一次。"
echo "设备标识是仓库外的随机 ID（$HOME/.secdisplay-device-id），主机名不会进公开仓。"
echo "手动触发一次: launchctl start com.secdisplay.telemetry"
echo "卸载: ./install_telemetry.sh remove"
