#!/bin/bash
# 编译并运行长时间监听 DSP 基准。用法: ./scripts/audio_benchmark.sh [秒数]
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/benchmark
xcrun swiftc -O \
  -framework Foundation \
  -framework Accelerate \
  -framework AVFoundation \
  Core/Sources/SoundSenseCore/SoundSenseCore.swift \
  Shared/MeasurementRecorder.swift \
  Shared/SessionAudioRecorder.swift \
  Shared/NoiseEventEngine.swift \
  Shared/SourceTendencyAnalyzer.swift \
  scripts/audio_benchmark.swift \
  -o .build/benchmark/audio_benchmark
.build/benchmark/audio_benchmark "${1:-300}"
