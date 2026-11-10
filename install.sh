#!/bin/zsh
# Installs Duo 1.0.0 (5) into ~/Applications and opens it.
# Usage: curl -fsSL https://gomjellie.github.io/DuoKeyboard/install.sh | zsh
# Template: Tools/scripts/dist.sh fills the @…@ fields.
set -euo pipefail

BASE_URL="https://gomjellie.github.io/DuoKeyboard"
SHA256="160bdf83c2e6659f883fb875fe980a8453f4d734bc970694521bfd618c59e209"
APP_DIR="$HOME/Applications"

major=$(sw_vers -productVersion | cut -d. -f1)
if (( major < 15 )); then
  echo "Duo는 macOS 15 이상에서 동작해요. 지금 macOS는 $(sw_vers -productVersion)이에요." >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "Duo 1.0.0 내려받는 중…"
curl -fsSL "$BASE_URL/Duo.zip" -o "$tmp/Duo.zip"
if ! echo "$SHA256  $tmp/Duo.zip" | shasum -a 256 -c - >/dev/null 2>&1; then
  echo "내려받은 파일이 올바르지 않아요. 잠시 뒤 다시 실행해 주세요." >&2
  exit 1
fi
ditto -x -k "$tmp/Duo.zip" "$tmp"

# The running host app keeps the old bundle open; the input method itself updates from Duo 설정.
pkill -x -U "$UID" Duo 2>/dev/null || true
mkdir -p "$APP_DIR"
rm -rf "$APP_DIR/Duo.app"
ditto "$tmp/Duo.app" "$APP_DIR/Duo.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP_DIR/Duo.app" 2>/dev/null || true

echo "설치했어요: $APP_DIR/Duo.app"
echo "Duo를 열어요. 처음이면 안내에 따라 ‘Duo 켜기’를 눌러 주세요."
open "$APP_DIR/Duo.app"
