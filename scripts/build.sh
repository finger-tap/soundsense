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

# ---- 3. 打 zip 包 ----
echo "🗜  打包 zip..."

ZIP_NAME="SoundSense-${VERSION}.zip"
cd "$OUTPUT_DIR"
zip -r -q "$ZIP_NAME" SoundSense.app
cd "$PROJECT_ROOT"

echo "✅ 打包完成: $OUTPUT_DIR/$ZIP_NAME"
echo ""
echo "═══════════════════════════════════════════════"
echo "  构建完成！"
echo "  App:  $OUTPUT_DIR/SoundSense.app"
echo "  Zip:  $OUTPUT_DIR/$ZIP_NAME"
echo "═══════════════════════════════════════════════"
