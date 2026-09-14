#!/bin/bash
# 纯逻辑测试:swiftc 直接编译 Shared 源文件 + 断言 main,不依赖 Xcode 测试 target。
set -e
cd "$(dirname "$0")/.."
mkdir -p .build/logic
swiftc -O \
  -framework Foundation -framework Combine \
  Shared/MeasurementRecorder.swift \
  Shared/MeasurementHistoryStore.swift \
  Shared/SessionAudioRecorder.swift \
  Shared/RecordingPlayer.swift \
  Shared/ReportHTMLBuilder.swift \
  Shared/NoiseEventEngine.swift \
  Tests/logic/main.swift \
  -o .build/logic/logic_tests
.build/logic/logic_tests
echo "ALL LOGIC TESTS PASSED"
