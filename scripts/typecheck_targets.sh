#!/bin/bash
# 三平台类型检查(绕开本机 xcodebuild 的本地包解析问题):
#   1. 从 project.pbxproj 的 Sources phase 提取各 target 文件清单
#   2. 每平台先 -emit-module SoundSenseCore,再对该 target 全部源码 -typecheck
# 用法: ./scripts/typecheck_targets.sh [macos|ios|watchos|all]
set -e
cd "$(dirname "$0")/.."

WHAT="${1:-all}"
WORK=$(mktemp -d /tmp/ss-typecheck.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# SoundSenseCore 源(编译为各平台模块)
CORE_SRC="Core/Sources/SoundSenseCore/SoundSenseCore.swift"

# 从 pbxproj 提取 Sources phase 文件名列表
files_of_phase() {
  awk "/$1 \/\* Sources \*\/ = \{/,/runOnlyForDeploymentPostprocessing/" \
    SoundSense.xcodeproj/project.pbxproj \
    | grep -o '/\* [^*]*\.swift in Sources \*/' \
    | sed 's:/\* \(.*\.swift\) in Sources \*/:\1:'
}

# 按平台目录优先顺序解析文件路径
resolve() {
  local name=$1; shift
  for dir in "$@"; do
    local hit
    hit=$(find "$dir" -name "$name" -not -path "*/.*" 2>/dev/null | head -1)
    if [ -n "$hit" ]; then echo "$hit"; return 0; fi
  done
  echo "MISSING:$name" >&2; return 1
}

typecheck_platform() {
  local label=$1 sdk=$2 triple=$3 phase_id=$4
  shift 4
  local search_dirs=("$@")
  echo "==> typecheck $label"
  mkdir -p "$WORK/$label"
  xcrun -sdk "$sdk" swiftc -emit-module -module-name SoundSenseCore \
    "$CORE_SRC" -sdk "$(xcrun -sdk "$sdk" --show-sdk-path)" \
    -target "$triple" -emit-module-path "$WORK/$label/SoundSenseCore.swiftmodule" 2>/dev/null

  local args=()
  for name in $(files_of_phase "$phase_id"); do
    args+=("$(resolve "$name" "${search_dirs[@]}")")
  done

  xcrun -sdk "$sdk" swiftc -typecheck "${args[@]}" \
    -I "$WORK/$label" \
    -sdk "$(xcrun -sdk "$sdk" --show-sdk-path)" \
    -target "$triple" 2>&1 | grep -E "error:" && {
      echo "✗ $label TYPECHECK FAILED"; exit 1
    }
  echo "✓ $label typecheck passed (${#args[@]} files)"
}

case "$WHAT" in
  macos) typecheck_platform macOS macosx x86_64-apple-macosx12.0 AA70000000000000000000005 macOS iOS Shared ;;
  ios)   typecheck_platform iOS iphonesimulator x86_64-apple-ios15.0-simulator A70000000000000000000001 iOS Shared ;;
  watchos) typecheck_platform watchOS watchsimulator x86_64-apple-watchos8.0-simulator A70000000000000000000003 watchOS Shared ;;
  all)
    typecheck_platform macOS macosx x86_64-apple-macosx12.0 AA70000000000000000000005 macOS iOS Shared
    typecheck_platform iOS iphonesimulator x86_64-apple-ios15.0-simulator A70000000000000000000001 iOS Shared
    typecheck_platform watchOS watchsimulator x86_64-apple-watchos8.0-simulator A70000000000000000000003 watchOS Shared
    ;;
  *) echo "unknown: $WHAT"; exit 2 ;;
esac
