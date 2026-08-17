#!/bin/bash
#
# make_icns.sh -- 生成内嵌明/暗双变体的 AppIcon.icns
#
# 背景:裸 ICNS 若只有一套图,系统切换深色模式时图标不会变。
#   把「浅色 + 深色(luminosity/dark)」两套图标一起编进同一个 ICNS,
#   Dock/Finder 才能跟随系统外观切换。做法是把两套 PNG 组装成
#   资产目录,交给 actool 编译(Xcode 构建 macOS 图标的正规途径)。
#
# 依赖:Xcode 工具链(xcrun/actool)、swift
#
# 用法:./scripts/make_icns.sh
#   产物覆盖仓库根目录 AppIcon.icns(Xcode 工程与 build.sh 都引用它)
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- 1. 生成 A3 表盘图标(浅色 + 深色两套 PNG)----
swift "$ROOT/generate_icon_a3.swift" "$TMP/A3" dark >/dev/null

# ---- 2. 组装临时资产目录:10 浅色 + 10 深色 ----
# 深色条目带 "appearances: luminosity/dark" 标记,actool 才会编成外观变体。
# 注意:深色文件名必须与 Contents.json 引用严格一致,否则 actool 会静默
# 产出空结果(不报错),这是调试过的坑。
SET="$TMP/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$SET"
echo '{"info":{"author":"xcode","version":1}}' > "$TMP/Assets.xcassets/Contents.json"
cp "$TMP/A3/icon_"*.png "$SET/"

python3 - "$TMP/A3" "$SET" << 'PY'
import json, os, shutil, sys

light_dir, set_dir = sys.argv[1], sys.argv[2]
dark_dir = light_dir + "_dark"
entries = []
for size in ["16x16", "32x32", "128x128", "256x256", "512x512"]:
    for scale in ["1x", "2x"]:
        suffix = "@2x" if scale == "2x" else ""
        light = f"icon_{size}{suffix}.png"
        dark = f"dark_icon_{size}{suffix}.png"
        entries.append({"filename": light, "idiom": "mac", "scale": scale, "size": size})
        entries.append({"filename": dark, "idiom": "mac", "scale": scale, "size": size,
                        "appearances": [{"appearance": "luminosity", "value": "dark"}]})
        shutil.copy(os.path.join(dark_dir, f"icon_{size}{suffix}.png"),
                    os.path.join(set_dir, dark))

with open(os.path.join(set_dir, "Contents.json"), "w") as f:
    json.dump({"images": entries, "info": {"author": "xcode", "version": 1}}, f, indent=1)
PY

# ---- 3. actool 编译双变体 ICNS ----
OUT="$TMP/out"
mkdir -p "$OUT"
xcrun actool --compile "$OUT" \
  --platform macosx --minimum-deployment-target 12.0 --target-device mac \
  --app-icon AppIcon --output-partial-info-plist "$OUT/partial.plist" \
  "$TMP/Assets.xcassets" >/dev/null

if [ ! -f "$OUT/AppIcon.icns" ]; then
    echo "❌ actool 未生成 AppIcon.icns(检查资产目录文件名是否与 Contents.json 一致)"
    exit 1
fi

# ---- 4. 覆盖仓库根目录图标 ----
cp "$OUT/AppIcon.icns" "$ROOT/AppIcon.icns"
echo "✅ 双变体 AppIcon.icns 已生成 ($(du -h "$ROOT/AppIcon.icns" | cut -f1))"
