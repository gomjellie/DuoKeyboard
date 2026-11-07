#!/bin/zsh
# Installs the built Duo input method into ~/Library/Input Methods and restarts it.
# Usage: Tools/scripts/install-ime.sh [path/to/DuoInputMethod.app]
#
# The new bundle is staged next to the destination and swapped in with two renames (the old copy is
# deleted only once the new one is in place), and the running server is stopped afterwards, so
# whatever imklaunchagent relaunches on the next keystroke is the new code. The server flushes its
# learning store on SIGTERM before exiting; the script waits up to 4 s for that. Info.plist changes
# (name, icon) need a TIS re-registration, which DuoHarness and the host app's installer do.
#
# Apps that were using Duo stay bound to the stopped server and type plain ABC until the input
# source is selected again while they are frontmost (pick another source and then Duo, e.g. with
# ⌃Space twice) or until focus moves to another app and back. The host app's installer does that
# re-selection itself (InputSourceManager.reselect); this script has no binary that can, so it only
# prints the reminder.
set -euo pipefail
SRC="${1:-build/dd/Build/Products/Debug/DuoInputMethod.app}"
DEST="$HOME/Library/Input Methods/DuoInputMethod.app"
[[ -d "$SRC" ]] || { echo "missing $SRC" >&2; exit 1; }
mkdir -p "$HOME/Library/Input Methods"
# Neither name ends in .app, so TIS never sees a second bundle with Duo's id.
STAGING="$DEST.installing"
OLD="$DEST.old"
rm -rf "$STAGING" "$OLD"
ditto "$SRC" "$STAGING"
if [[ -e "$DEST" ]]; then
  mv "$DEST" "$OLD"
  mv "$STAGING" "$DEST" || { mv "$OLD" "$DEST"; echo "could not swap in $STAGING" >&2; exit 1; }
  rm -rf "$OLD"
else
  mv "$STAGING" "$DEST"
fi
# Stop the old server (it keeps its old code until it exits) and wait for it to finish flushing.
pkill -x -U "$UID" DuoInputMethod 2>/dev/null || true
for _ in {1..80}; do
  pgrep -x -U "$UID" DuoInputMethod >/dev/null 2>&1 || break
  sleep 0.05
done
if pgrep -x -U "$UID" DuoInputMethod >/dev/null 2>&1; then
  echo "warning: DuoInputMethod is still running after 4 s" >&2
fi
# Touch so LaunchServices / TSM notice the change.
touch "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
echo "installed → $DEST"
echo "note: apps that were using Duo reconnect once you select the input source again in them (or switch apps and back)"
