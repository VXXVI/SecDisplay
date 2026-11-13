#!/bin/bash
# 把发送端打成 .app。
#
# 目的：
#   1. 从 Finder / 启动台直接双击启动，不用开 Terminal。
#   2. 屏幕录制授权挂在 bundle 上，重编译后不会每次都要重新勾。
#   3. 菜单栏常驻，面板可控。
#
# 用法：
#   ./build_app.sh                 # 编译并打包到 prototype/mac/SecDisplay.app
#   ./build_app.sh --install       # 打包后复制到 /Applications
#   open SecDisplay.app            # 启动
set -euo pipefail
cd "$(dirname "$0")"

APP="SecDisplay.app"
BIN="$APP/Contents/MacOS/SecDisplay"
SIGN_ID="com.secdisplay.screensender"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "编译中..."
swiftc -O Sources/main.swift Sources/AppUI.swift -o "$BIN"

# 把当前档位写进 bundle，从 Finder 启动时按这个档位建屏
if [ -f .preset ]; then
    cp .preset "$APP/Contents/Resources/preset"
else
    echo "smooth" > "$APP/Contents/Resources/preset"
fi

# 构建标记：启动日志会打印，用来判断跑的是不是旧包
REPO="$(cd ../.. && pwd)"
printf '%s %s\n' "$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo nogit)" \
    "$(date '+%Y-%m-%d %H:%M:%S')" > "$APP/Contents/Resources/build-stamp"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>SecDisplay</string>
    <key>CFBundleDisplayName</key>
    <string>SecDisplay</string>
    <key>CFBundleIdentifier</key>
    <string>com.secdisplay.screensender</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>SecDisplay</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>SecDisplay 需要采集虚拟屏画面并发送到 Windows。</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>SecDisplay 需要用 AppleScript 调整显示器排列。</string>
</dict>
</plist>
PLIST

# 优先用本机 Apple Development 证书；没有就退回 ad-hoc。
# 证书签名的 designated requirement 稳定，重编译后屏幕录制授权不会失效。
CERT="${SECDISPLAY_SIGN_CERT:-}"
if [ -z "$CERT" ]; then
    CERT=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: [^"]*\)"/\1/p' | head -1)
fi
if [ -n "$CERT" ]; then
    codesign --force --sign "$CERT" --identifier "$SIGN_ID" --timestamp=none "$APP" >/dev/null
    echo "已用证书签名: $CERT"
else
    codesign --force --sign - --identifier "$SIGN_ID" \
        -r="designated => identifier \"$SIGN_ID\"" --timestamp=none "$APP" >/dev/null
    echo "已用 ad-hoc 签名（identifier 型 DR，重编译不丢授权）"
fi

echo "已生成 $APP"

if [ "${1:-}" = "--install" ]; then
    rm -rf "/Applications/SecDisplay.app"
    cp -R "$APP" /Applications/
    echo "已安装到 /Applications/SecDisplay.app"
fi

echo
echo "启动: open $APP"
echo "日志: ~/Library/Logs/SecDisplay/sender.log"
echo "首次启动若黑屏, 到 系统设置 > 隐私与安全 > 屏幕录制 勾选 SecDisplay 后重开"
