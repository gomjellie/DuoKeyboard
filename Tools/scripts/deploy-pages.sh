#!/bin/zsh
# Publishes build/dist (make dist) to GitHub Pages: one commit on the gh-pages branch of a remote.
# Usage: Tools/scripts/deploy-pages.sh [remote]   (default: origin)
# The branch is replaced each time, so old Duo.zip files do not pile up in the repository.
set -euo pipefail
cd "${0:A:h}/../.."

REMOTE="${1:-origin}"
OUT=build/dist
[[ -f "$OUT/update.json" && -f "$OUT/Duo.zip" ]] || { echo "no $OUT: run make dist first" >&2; exit 1; }
URL=$(git remote get-url "$REMOTE")
field() { /usr/bin/sed -n "s/.*\"$1\": *\"\\([^\"]*\\)\".*/\\1/p" "$OUT/update.json"; }
VERSION=$(field version)
BUILD=$(field build)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp -R "$OUT/." "$tmp/"
# Serve the files as they are: no Jekyll build.
touch "$tmp/.nojekyll"
git -C "$tmp" init -q -b gh-pages
git -C "$tmp" add -A
git -C "$tmp" -c user.name="$(git config user.name)" -c user.email="$(git config user.email)" \
  commit -q -m "build(dist): Duo $VERSION ($BUILD) 배포"
git -C "$tmp" push -q --force "$URL" gh-pages
echo "→ $URL gh-pages: Duo $VERSION ($BUILD)"
