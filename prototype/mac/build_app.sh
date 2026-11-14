#!/bin/bash
# 把发送端打成 .app。
#
# 目的：
#   1. 从 Finder / 启动台直接双击启动，不用开 Terminal。
#   2. 屏幕录制授权挂在 bundle 上，重编译后不会每次都要重新勾。
#   3. 菜单栏常驻，面板可控。
#
# 用法：
#   ./build_app.sh                  # 编译、打包、直接安装到 /Applications
#   ./build_app.sh --no-install     # 只打包到 prototype/mac/SecDisplay.app，不安装
#
# 默认每次编译完就装到 /Applications：运行中的实例是 /Applications 那份，
# 只改 prototype/mac/SecDisplay.app 不生效，曾多次因此「改了没反应」。
set -euo pipefail
cd "$(dirname "$0")"

APP="SecDisplay.app"
BIN="$APP/Contents/MacOS/SecDisplay"
SIGN_ID="com.secdisplay.screensender"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "编译中..."
swiftc -O Sources/main.swift Sources/AppUI.swift -o "$BIN"

# 默认档位 balanced = 2880x1800 真 2x Retina（1440x900 逻辑），与 Windows 物理屏 1:1。
# .preset 是本地运行状态（gitignore），存在时仍优先，方便临时切档。
# 想固定用某个档位就写 .preset，例如 echo sharp > .preset
DEFAULT_PRESET="balanced"
if [ -f .preset ]; then
    cp .preset "$APP/Contents/Resources/preset"
else
    echo "$DEFAULT_PRESET" > "$APP/Contents/Resources/preset"
fi

# 图标。源文件在 assets/app-icon，由 assets/icon-gen/build_icons.py 生成。
REPO="$(cd ../.. && pwd)"
ICON="$REPO/assets/app-icon/AppIcon.icns"
if [ -f "$ICON" ]; then
    cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "警告: 没找到 $ICON，bundle 将使用系统默认图标"
fi

# 构建标记：启动日志会打印，用来判断跑的是不是旧包
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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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
    # security 失败或 head 提前关管道（SIGPIPE）在 pipefail 下都会非零，
    # 这里吞掉错误当作「没有证书」，交给后面的 ad-hoc 分支。
    CERT=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Apple Development: [^"]*\)"/\1/p' | head -1) || CERT=""
fi
if [ -n "$CERT" ]; then
    # set -e 下不能直接裸调：证书过期/钥匙串锁定时会中断整个打包，
    # 应该回退 ad-hoc 而不是什么都不产出。
    if codesign --force --sign "$CERT" --identifier "$SIGN_ID" --timestamp=none "$APP" >/dev/null 2>&1; then
        echo "已用证书签名: $CERT"
    else
        echo "证书签名失败，回退 ad-hoc: $CERT"
        CERT=""
    fi
fi
if [ -z "$CERT" ]; then
    codesign --force --sign - --identifier "$SIGN_ID" \
        -r="designated => identifier \"$SIGN_ID\"" --timestamp=none "$APP" >/dev/null
    echo "已用 ad-hoc 签名（identifier 型 DR，重编译不丢授权）"
fi

echo "已生成 $APP"

# 默认直接装到 /Applications。--no-install 才跳过。
# --install 保留为兼容旧调用，效果与默认一致。
INSTALL=1
case "${1:-}" in
    --no-install) INSTALL=0 ;;
    --install)    INSTALL=1 ;;
esac
if [ "$INSTALL" = "1" ]; then
    rm -rf "/Applications/SecDisplay.app"
    cp -R "$APP" /Applications/
    # 清理本地构建暂存 bundle，确保全盘只保留 /Applications/SecDisplay.app，
    # 避免启动台/Spotlight/系统权限页同时出现多个 SecDisplay.app 造成混淆。
    rm -rf "$APP"
    echo "已安装到 /Applications/SecDisplay.app（已清理构建目录冗余副本）"
    if pgrep -f "/Applications/SecDisplay.app/Contents/MacOS/SecDisplay" >/dev/null 2>&1; then
        echo "提示: 检测到旧实例正在运行，先退出旧实例后再重新 open /Applications/SecDisplay.app"
    fi
fi

echo
if [ "$INSTALL" = "1" ]; then
    echo "启动: open /Applications/SecDisplay.app"
else
    echo "启动: open \"$(pwd)/SecDisplay.app\""
fi
echo "日志: ~/Library/Logs/SecDisplay/sender.log"
echo "切档: echo sharp > $(pwd)/.preset && ./build_app.sh"
echo "首次启动若黑屏, 到 系统设置 > 隐私与安全 > 屏幕录制 勾选 SecDisplay 后重开"
