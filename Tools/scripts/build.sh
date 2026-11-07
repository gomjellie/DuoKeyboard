#!/bin/zsh
# Builds a scheme quietly. Usage: Tools/scripts/build.sh <Scheme> [Debug|Release]
set -euo pipefail
SCHEME="$1"; CONFIG="${2:-Debug}"
cd "${0:A:h}/../.."
xcodebuild -project Duo.xcodeproj -scheme "$SCHEME" -configuration "$CONFIG" -derivedDataPath build/dd \
  -destination 'platform=macOS' build 2>&1 \
  | grep -v -E "DVTPlugIn|DVTCoreDevice|iOSSimulator|CoreSimulator|appintentsmetadataprocessor|^Details:" \
  | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" || true
