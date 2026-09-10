#!/bin/bash
# Runs only the real-input test through the bundled production Engine.
set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo "Usage: bash scripts/replay_recognition_trace.sh /absolute/Recognition-UUID" >&2
  exit 2
fi
trace_directory="$(cd "$1" && pwd)"
test -f "$trace_directory/recognition_input.json"
test -f "$trace_directory/recognition_input_attachments.plist"
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Replay requires macOS with Xcode and the project's bundled Core ML model." >&2
  exit 2
fi
test -d App/Models/CardDetector.mlpackage || test -f App/Models/CardDetector.mlmodel
xcodegen generate
export TEST_RUNNER_RECOGNITION_TRACE_REPLAY_DIR="$trace_directory"
xcodebuild test -project CardScanMagic.xcodeproj -scheme CardScanMagic \
  -destination "${TRACE_SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 15}" \
  -only-testing:CardScanMagicTests/RealFrameReplayTests/testExportedProductionInputThroughFullEngineWhenProvided \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
echo "Replay trace: $trace_directory/replay_trace.json"

