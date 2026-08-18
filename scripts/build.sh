#!/bin/bash
#
# build.sh -- 闻声 SoundSense 构建脚本
#
# 用法:
#   ./scripts/build.sh [output_dir]
#
# 功能:
#   1. 用 swiftc 编译源码
#   2. 组装 .app bundle（Info.plist + 可执行文件 + Assets.car 图标）
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

# 优先使用完整 Xcode 工具链(交叉编译更可靠;CommandLineTools 的 swiftc 在
# 交叉编译 arm64 时可能卡死)。CI(macos-14 runner)已默认 xcode-select 到 Xcode。
if [ -z "${DEVELOPER_DIR:-}" ] || [ "${DEVELOPER_DIR:-}" = "/" ]; then
  if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    export PATH="/Applications/Xcode.app/Contents/Developer/usr/bin:$PATH"
    echo "  使用 Xcode 工具链: $DEVELOPER_DIR"
  fi
fi

# 确定 SDK 路径
SDK_PATH="$(xcrun --show-sdk-path 2>/dev/null || echo '/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk')"

# Universal Binary:分别编译 arm64(Apple Silicon,M 系列)和 x86_64(Intel),
# 再用 lipo 合并成一个双架构二进制。这样一个 .app / .dmg 在两种芯片的 Mac 上
# 都能原生运行,无需 Rosetta。
# macOS 12 最低部署目标:Intel 最后支持到 macOS 12 Monterey;Apple Silicon 全支持。
MACOS_MIN="12.0"
SOURCES="Core/Sources/SoundSenseCore/SoundSenseCore.swift Core/Sources/soundsense/main.swift"
FRAMEWORKS="-framework Accelerate -framework AVFoundation -framework Foundation"

# 1a. 编译 arm64(Apple Silicon)
echo "  → 编译 arm64 (Apple Silicon)..."
swiftc -O -target "arm64-apple-macos${MACOS_MIN}" -sdk "$SDK_PATH" \
  $FRAMEWORKS $SOURCES \
  -o "$OUTPUT_DIR/SoundSense.arm64" || { echo "❌ arm64 编译失败"; exit 1; }

# 1b. 编译 x86_64(Intel)
echo "  → 编译 x86_64 (Intel)..."
swiftc -O -target "x86_64-apple-macos${MACOS_MIN}" -sdk "$SDK_PATH" \
  $FRAMEWORKS $SOURCES \
  -o "$OUTPUT_DIR/SoundSense.x86_64" || { echo "❌ x86_64 编译失败"; exit 1; }

# 1c. 合并为 universal binary
echo "  → 合并 universal binary..."
lipo -create \
  "$OUTPUT_DIR/SoundSense.arm64" \
  "$OUTPUT_DIR/SoundSense.x86_64" \
  -output "$OUTPUT_DIR/SoundSense" || { echo "❌ lipo 合并失败"; exit 1; }

# 清理中间产物
rm -f "$OUTPUT_DIR/SoundSense.arm64" "$OUTPUT_DIR/SoundSense.x86_64"

# 校验产物确实是双架构
BUILT_ARCHS="$(lipo -archs "$OUTPUT_DIR/SoundSense" 2>/dev/null || echo unknown)"
echo "  二进制架构: $BUILT_ARCHS"
if [[ "$BUILT_ARCHS" != *"arm64"* || "$BUILT_ARCHS" != *"x86_64"* ]]; then
  echo "  ⚠️  警告:产物未包含双架构,某些 Mac 可能无法运行"
fi

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

# 编译图标资产目录 → Assets.car(明/暗双变体,系统按外观自动切换)。
# 注意:不能用裸 .icns —— 单文件 icns 无法携带深色变体;也不用 actool 附带的
# AppIcon.icns fallback(Xcode 14.2 上实测为残缺产物),只保留 Assets.car +
# CFBundleIconName,系统会优先从 car 取图。
ACTOOL_OUT="$OUTPUT_DIR/actool"
mkdir -p "$ACTOOL_OUT"
xcrun actool --compile "$ACTOOL_OUT" \
  --platform macosx --minimum-deployment-target "$MACOS_MIN" --target-device mac \
  --app-icon AppIcon \
  --output-partial-info-plist "$ACTOOL_OUT/partial.plist" \
  macOS/Assets.xcassets >/dev/null
if [ -f "$ACTOOL_OUT/Assets.car" ]; then
    cp "$ACTOOL_OUT/Assets.car" "$APP_DIR/Contents/Resources/Assets.car"
else
    echo "❌ Assets.car 编译失败"; exit 1
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
    <key>CFBundleIconName</key>
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

# 生成品牌背景图(1120×720 @2x,对应 560×360 窗口)并放入隐藏目录
echo "  → 生成品牌背景图..."
swift scripts/make_dmg_background.swift "$OUTPUT_DIR/dmg_background.png" >/dev/null 2>&1 \
  || echo "  ⚠️ 背景图生成失败,DMG 将无背景"
mkdir -p "$STAGING_DIR/.background"
cp "$OUTPUT_DIR/dmg_background.png" "$STAGING_DIR/.background/background.png" 2>/dev/null || true

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
    # 等 Finder 完成挂载识别,否则设置背景/位置可能不生效
    sleep 3
    # 用 AppleScript 设置 DMG 窗口外观。
    # 注意:必须是 "icon view options of container window"(逐属性设置),
    # 旧写法 "view options of icon view of container window" 在 macOS 12
    # 上直接语法报错,导致背景一直不生效。
    osascript << APPLESCRIPT 2>/dev/null || true
tell application "Finder"
    tell disk "$(basename "$MOUNT_POINT")"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 660, 460}
        set icon size of icon view options of container window to 96
        set arrangement of icon view options of container window to not arranged
        -- 背景图:先试 HFS 相对路径,失败再用 POSIX 绝对路径
        try
            set background picture of icon view options of container window to file ".background:background.png"
        on error
            set background picture of icon view options of container window to POSIX file "$MOUNT_POINT/.background/background.png"
        end try
        -- 两个图标当"眼睛"
        set position of item "SoundSense.app" of container window to {150, 120}
        set position of item "Applications" of container window to {410, 120}
        close
        -- 重开一次让背景设置稳定生效
        open
        close
    end tell
end tell
APPLESCRIPT
    # 卸载
    sleep 2
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1
fi

# 转换为压缩只读 DMG（体积更小，带 LZMA 压缩）
hdiutil convert "$TMP_DMG" \
  -format ULMO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH" >/dev/null 2>&1

# 清理临时文件
rm -f "$TMP_DMG" "$OUTPUT_DIR/dmg_background.png"
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
