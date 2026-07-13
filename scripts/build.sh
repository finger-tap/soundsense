#!/bin/bash
#
# build.sh -- 闻声 SoundSense 构建脚本
#
# 用法:
#   ./scripts/build.sh [output_dir]
#
# 功能:
#   1. 用 swiftc 编译源码
#   2. 组装 .app bundle（Info.plist + 可执行文件 + AppIcon.icns）
#   3. 打 zip 包
#
# 输出:
#   SoundSense.app          -- 可运行的 macOS app
#   SoundSense-{version}.zip -- 发布用压缩包
#

set -euo pipefail

# 项目根目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# 输出目录
OUTPUT_DIR="${1:-build}"
mkdir -p "$OUTPUT_DIR"

# 版本号（从 git tag 获取，失败则用默认值）
VERSION="${VERSION:-$(git describe --tags --always 2>/dev/null || echo 'dev')}"
echo "📦 版本: $VERSION"
echo "📂 输出: $OUTPUT_DIR"
echo ""

# ---- 1. 编译 ----
echo "🔨 编译中..."

# 确定 SDK 路径
SDK_PATH="$(xcrun --show-sdk-path 2>/dev/null || echo '/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk')"
# 目标架构：GitHub Actions macos-14 是 arm64，本地可能是 x86_64
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos12"

swiftc \
  -O \
  -target "$TARGET" \
  -sdk "$SDK_PATH" \
  -framework Accelerate \
  -framework AVFoundation \
  -framework Foundation \
  Sources/SoundSenseCore/SoundSenseCore.swift \
  Sources/soundsense/main.swift \
  -o "$OUTPUT_DIR/SoundSense"

echo "✅ 编译完成"
echo ""

# ---- 2. 组装 .app bundle ----
echo "📦 组装 app bundle..."

APP_DIR="$OUTPUT_DIR/SoundSense.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# 复制可执行文件
cp "$OUTPUT_DIR/SoundSense" "$APP_DIR/Contents/MacOS/SoundSense"

# 复制图标
if [ -f "AppIcon.icns" ]; then
    cp "AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# 生成 Info.plist
cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>SoundSense</string>
    <key>CFBundleDisplayName</key>
    <string>闻声</string>
    <key>CFBundleIdentifier</key>
    <string>com.dinghao.soundsense</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>SoundSense</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>闻声需要访问麦克风来测量环境噪音水平。</string>
</dict>
</plist>
PLIST

echo "✅ App bundle 组装完成"
echo ""

# ---- 3. 打 DMG 包（拖拽安装）----
echo "💿 打包 DMG..."

DMG_NAME="SoundSense-${VERSION}.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
STAGING_DIR="$OUTPUT_DIR/dmg-staging"

# 准备 DMG 暂存目录：放 .app + /Applications 快捷方式
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

# 创建临时 DMG
TMP_DMG="$OUTPUT_DIR/tmp-$DMG_NAME"
rm -f "$TMP_DMG" "$DMG_PATH"
hdiutil create -volname "闻声 SoundSense" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -format UDRW \
  "$TMP_DMG" >/dev/null 2>&1

# 挂载临时 DMG
MOUNT_POINT=$(hdiutil attach -readwrite -noverify -noautoopen "$TMP_DMG" 2>/dev/null \
  | grep -o '/Volumes/.*' | head -1)

# 设置窗口布局（图标大小、位置等）
if [ -n "$MOUNT_POINT" ]; then
    # 用 AppleScript 设置 DMG 窗口外观
    osascript << APPLESCRIPT 2>/dev/null || true
tell application "Finder"
    tell disk "$(basename "$MOUNT_POINT")"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 500, 320}
        set view options of icon view of container window to \
            {icon size: 96, arrangement: row}
        set position of item "SoundSense.app" of container window to {120, 120}
        set position of item "Applications" of container window to {350, 120}
        close
    end tell
end tell
APPLESCRIPT
    # 卸载
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1
fi

# 转换为压缩只读 DMG（体积更小，带 LZMA 压缩）
hdiutil convert "$TMP_DMG" \
  -format ULMO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH" >/dev/null 2>&1

# 清理临时文件
rm -f "$TMP_DMG"
rm -rf "$STAGING_DIR"

if [ -f "$DMG_PATH" ]; then
    DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
    echo "✅ 打包完成: $OUTPUT_DIR/$DMG_NAME ($DMG_SIZE)"
else
    echo "❌ DMG 打包失败，回退到 zip"
    ZIP_NAME="SoundSense-${VERSION}.zip"
    cd "$OUTPUT_DIR"
    zip -r -q "$ZIP_NAME" SoundSense.app
    cd "$PROJECT_ROOT"
    echo "✅ 打包完成: $OUTPUT_DIR/$ZIP_NAME"
fi

echo ""
echo "═══════════════════════════════════════════════"
echo "  构建完成！"
echo "  App:  $OUTPUT_DIR/SoundSense.app"
echo "  Dmg:  $OUTPUT_DIR/$DMG_NAME"
echo "═══════════════════════════════════════════════"
