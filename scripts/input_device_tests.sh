#!/bin/bash
# 输入源功能纯逻辑测试(macOS 专属):swiftc 直编,不依赖 Xcode 测试 target。
# 先把 SoundSenseCore 编成动态库,再与被测源文件、断言 main 一起链接。
# (-disable-sandbox:绕开本机 swift-plugin-server 沙箱问题)
set -e
cd "$(dirname "$0")/.."
SDK=$(xcrun --sdk macosx --show-sdk-path)
TARGET=arm64-apple-macos12.0
OUT=.build/logic_input
mkdir -p "$OUT"

xcrun -sdk macosx swiftc -disable-sandbox -emit-library -emit-module \
  -module-name SoundSenseCore \
  Core/Sources/SoundSenseCore/SoundSenseCore.swift \
  -sdk "$SDK" -target "$TARGET" \
  -o "$OUT/libSoundSenseCore.dylib" \
  -emit-module-path "$OUT/SoundSenseCore.swiftmodule"

xcrun -sdk macosx swiftc -disable-sandbox \
  Shared/AudioInputDeviceManager.swift \
  Shared/AudioMeterEngine.swift \
  macOS/SoundSenseMacApp/MeterViewModel.swift \
  Shared/MeasurementRecorder.swift \
  Shared/SessionAudioRecorder.swift \
  Shared/MeasurementHistoryStore.swift \
  Shared/NoiseLevel.swift \
  Shared/NoiseAlertNotifier.swift \
  Tests/logic_input/main.swift \
  -I "$OUT" -L "$OUT" -lSoundSenseCore \
  -sdk "$SDK" -target "$TARGET" \
  -o "$OUT/input_device_tests"

DYLD_LIBRARY_PATH="$OUT" "$OUT/input_device_tests"
