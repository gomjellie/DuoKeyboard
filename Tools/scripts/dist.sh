#!/bin/zsh
# Packages the Release host app for the download site.
# Usage: Tools/scripts/dist.sh <base-url>   (the site URL that will serve build/dist)
# Output: build/dist/{index.html, demo.js, install.sh, Duo.zip, icon.png} from Tools/dist.
# Raise CURRENT_PROJECT_VERSION in project.yml before each release: Duo 설정 offers 업데이트 only
# when the embedded input method is newer than the installed one.
set -euo pipefail
BASE_URL="${1:?usage: dist.sh <base-url>}"
BASE_URL="${BASE_URL%/}"
cd "${0:A:h}/../.."

APP=build/dd/Build/Products/Release/Duo.app
OUT=build/dist
Tools/scripts/build.sh Duo Release
[[ -d "$APP/Contents/Library/Input Methods/DuoInputMethod.app" ]] || { echo "no input method in $APP" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

plist() { /usr/libexec/PlistBuddy -c "Print $1" "$APP/Contents/Info.plist"; }
VERSION=$(plist CFBundleShortVersionString)
BUILD=$(plist CFBundleVersion)

rm -rf "$OUT"
mkdir -p "$OUT"
ditto -c -k --keepParent "$APP" "$OUT/Duo.zip"
sips -s format png -Z 256 "$APP/Contents/Resources/AppIcon.icns" --out "$OUT/icon.png" >/dev/null
SHA256=$(shasum -a 256 "$OUT/Duo.zip" | cut -d' ' -f1)
SIZE=$(stat -f %z "$OUT/Duo.zip" | awk '{ printf "%.1f MB", $1 / 1048576 }')
DATE=$(date +%Y-%m-%d)

# The demo's frames come from the engine (DemoFramesTests) and go inline into the page.
for file in install.sh index.html; do
  awk -v frames=Tools/dist/demo-frames.json \
      '/@DEMO_FRAMES@/ { while ((getline line < frames) > 0) print line; next } { print }' "Tools/dist/$file" \
    | sed -e "s|@BASE_URL@|$BASE_URL|g" -e "s|@VERSION@|$VERSION|g" -e "s|@BUILD@|$BUILD|g" \
          -e "s|@SHA256@|$SHA256|g" -e "s|@SIZE@|$SIZE|g" -e "s|@DATE@|$DATE|g" > "$OUT/$file"
done
cp Tools/dist/demo.js "$OUT/demo.js"
if grep -q '@[A-Z0-9_]*@' "$OUT/install.sh" "$OUT/index.html"; then
  echo "unfilled template field in $OUT" >&2
  exit 1
fi
echo "→ $OUT: Duo $VERSION ($BUILD), $SIZE, sha256 $SHA256"
