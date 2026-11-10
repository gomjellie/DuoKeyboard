#!/bin/zsh
# Packages the Release host app for the download site.
# Usage: Tools/scripts/dist.sh <base-url>   (the site URL that will serve build/dist)
# Output: build/dist/{index.html, demo.js, install.sh, Duo.zip, update.json, icon.png} from Tools/dist.
# Raise CURRENT_PROJECT_VERSION in project.yml before each release: installed copies update
# themselves only to a version newer than their own (update.json, DuoKit AppUpdate).
# update.json carries an Ed25519 signature of Duo.zip by the key at DUO_UPDATE_KEY
# (default ~/.config/duo/update-ed25519.key; Tools/scripts/update-sign.swift).
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

# Installed copies accept only a zip signed by the key whose public half is AppUpdate.publicKey.
KEY="${DUO_UPDATE_KEY:-$HOME/.config/duo/update-ed25519.key}"
[[ -f "$KEY" ]] || { echo "no update signing key at $KEY" >&2; exit 1; }
PUBLIC=$(xcrun swift Tools/scripts/update-sign.swift public "$KEY")
grep -qF "\"$PUBLIC\"" Packages/DuoCore/Sources/DuoKit/Host/AppUpdate.swift \
  || { echo "the key at $KEY is not AppUpdate.publicKey" >&2; exit 1; }
SIGNATURE=$(xcrun swift Tools/scripts/update-sign.swift sign "$OUT/Duo.zip" "$KEY")
cat > "$OUT/update.json" <<JSON
{
  "version": "$VERSION",
  "build": "$BUILD",
  "url": "$BASE_URL/Duo.zip",
  "size": $(stat -f %z "$OUT/Duo.zip"),
  "sha256": "$SHA256",
  "signature": "$SIGNATURE",
  "minimumSystemVersion": "$(plist LSMinimumSystemVersion)"
}
JSON

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
