#!/bin/bash
# Runs only the real-input test through the bundled production Engine.
set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo "Usage: bash scripts/replay_recognition_trace.sh /absolute/Recognition-UUID" >&2
  exit 2
fi
trace_directory="$(cd "$1" && pwd)"
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_directory="$(cd "$script_directory/.." && pwd)"
test -f "$trace_directory/recognition_input.json"
test -f "$trace_directory/recognition_input_attachments.plist"
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Replay requires macOS with Xcode and the project's bundled Core ML model." >&2
  exit 2
fi
command -v python3 >/dev/null 2>&1 || { echo "Python 3 is required for replay verification." >&2; exit 2; }
command -v xcodegen >/dev/null 2>&1 || { echo "Install XcodeGen before replaying." >&2; exit 2; }
state_file="$(mktemp "${TMPDIR:-/tmp}/cardscan-replay.XXXXXX")"
trap 'rm -f "$state_file"' EXIT
verifier="$script_directory/verify_recognition_trace_replay.py"
python3 "$verifier" prepare --repository "$repository_directory" \
  --recognition "$trace_directory" --state "$state_file"
source_revision="$(python3 "$verifier" field --state "$state_file" --name sourceRevision)"
model_sha256="$(python3 "$verifier" field --state "$state_file" --name modelSHA256)"
cd "$repository_directory"
xcodegen generate
export TEST_RUNNER_RECOGNITION_TRACE_REPLAY_DIR="$trace_directory"
xcodebuild test -project CardScanMagic.xcodeproj -scheme CardScanMagic \
  -destination "${TRACE_SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 15}" \
  -only-testing:CardScanMagicTests/RealFrameReplayTests/testExportedProductionInputThroughFullEngineWhenProvided \
  "INFOPLIST_KEY_TraceSourceRevision=$source_revision" "INFOPLIST_KEY_TraceModelSHA256=$model_sha256" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
python3 "$verifier" verify --state "$state_file"
echo "Replay trace: $trace_directory/replay_trace.json"
echo "Verified replay receipt: $trace_directory/replay_verification.json"
