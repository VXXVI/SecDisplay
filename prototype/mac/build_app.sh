#!/bin/bash
# 把发送端打成 .app 并做 ad-hoc 签名。
#
# 目的不是分发，是让「屏幕录制」授权尽量挂在同一个 bundle 上。
# TCC 按 bundle id 与代码签名记授权，直接跑裸二进制时每次重编译都可能要重新勾。
#
# 用法：
#   ./build_app.sh              # 编译并签名
#   open SecDisplay.app         # 启动，菜单栏出现显示器图标
#   ./build_app.sh --clean      # 先删旧 bundle 再编译
set -euo pipefail
cd "$(dirname "$0")"

APP="SecDisplay.app"
BIN="$APP/Contents/MacOS/SecDisplay"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O Sources/ScreenSender.swift -o "$BIN"

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
    <string>com.secdisplay.sender</string>
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
</dict>
</plist>
PLIST

# 优先用本机 Apple Development 证书，没有就退回 ad-hoc。
# 证书签名的 designated requirement 稳定，重编译后屏幕录制授权不会失效；
# ad-hoc 的 DR 带 cdhash，重编译后可能要重新勾一次。
CERT="${SECDISPLAY_SIGN_CERT:-}"
if [ -z "$CERT" ]; then
    CERT=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: [^"]*\)"/\1/p' | head -1)
fi
if [ -n "$CERT" ]; then
    codesign --force --sign "$CERT" --timestamp=none "$APP" >/dev/null
    echo "已用证书签名: $CERT"
else
    codesign --force --sign - --timestamp=none "$APP" >/dev/null
    echo "已用 ad-hoc 签名（重编译后可能需要重新授权屏幕录制）"
fi

echo "已生成 $APP"
echo "启动: open $APP"
echo "日志: ~/Library/Logs/SecDisplay/sender.log"
echo "首次启动请在 系统设置 > 隐私与安全 > 屏幕录制 里勾选 SecDisplay"
