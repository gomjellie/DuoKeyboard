#!/bin/zsh
# Runs end-to-end cases through the real IMK client path (no TCC permissions needed).
#
# Usage: Tools/scripts/e2e.sh [cases-file] [--snapshot <dir>] [--keep-source]
#        Tools/scripts/e2e.sh -e "dkssud{space}" ["keys" ...]
#
#   cases-file   JSON array of {name, keys, expect?, expectMarked?}; relative paths are resolved
#                against the current directory. Default: Tests/E2E/cases.json.
#   --snapshot   write a PNG of the harness text view per case into <dir>.
#   --keep-source  leave Duo selected afterwards (default: restore the previous input source).
#
# Needs the Debug input method installed (`make install`) and DuoHarness built in Debug. The harness
# selects Duo and takes focus while it runs: don't run it while someone is typing.
# Learning is isolated: the cases run against an empty store (flips in them record votes), and the
# user's learning.json is put back afterwards. The IME is stopped for this; afterwards the script
# relaunches it and selects Duo again (`DuoHarness --reconnect`), or the frontmost app would stay
# bound to the stopped server and type nothing.
# Exit status: 0 all passed, 1 a case failed or the IME never answered, 2 usage error.
set -uo pipefail

SCRIPT="${0:A}"
ROOT="${SCRIPT:h:h:h}"
usage() { sed -n '2,17p' "$SCRIPT" | sed 's/^# \{0,1\}//'; }
CASES=""
HARNESS_ARGS=()
INLINE=0
while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --snapshot)
      (( $# >= 2 )) || { echo "e2e: --snapshot needs a directory" >&2; exit 2; }
      HARNESS_ARGS+=(--snapshot "${2:A}"); shift 2 ;;
    --keep-source) HARNESS_ARGS+=(--keep-source); shift ;;
    -e)
      shift
      (( $# >= 1 )) || { echo "e2e: -e needs at least one key script" >&2; exit 2; }
      INLINE=1; HARNESS_ARGS+=(-e "$@"); break ;;
    -*) echo "e2e: unknown option $1" >&2; usage >&2; exit 2 ;;
    *)
      [[ -z "$CASES" ]] || { echo "e2e: more than one cases file ($CASES, $1)" >&2; exit 2; }
      CASES="${1:A}"; shift ;;
  esac
done

if (( ! INLINE )); then
  [[ -n "$CASES" ]] || CASES="$ROOT/Tests/E2E/cases.json"
  [[ -f "$CASES" ]] || { echo "e2e: cases file not found: $CASES" >&2; exit 2; }
  HARNESS_ARGS=("$CASES" "${HARNESS_ARGS[@]}")
fi

APP="$ROOT/build/dd/Build/Products/Debug/DuoHarness.app"
[[ -d "$APP" ]] || { echo "e2e: $APP is missing; run 'make e2e' (or build DuoHarness in Debug)" >&2; exit 2; }

OUT_DIR="$ROOT/build/e2e"
mkdir -p "$OUT_DIR"
REPORT="$OUT_DIR/report.json"
STDERR_LOG="$OUT_DIR/stderr.log"
rm -f "$REPORT" "$STDERR_LOG"

# Isolate the learning store (DuoIDs.learningFileURL): the IME flushes it on SIGTERM, so stop it,
# set the file aside, and restore it once the run (or an interrupted run) is over.
LEARNING="$HOME/Library/Application Support/Duo/learning.json"
LEARNING_BACKUP="$OUT_DIR/learning.user-backup.json"
stop_ime() {
  pkill -x DuoInputMethod 2>/dev/null || return 0
  for _ in {1..20}; do pgrep -x DuoInputMethod >/dev/null || return 0; sleep 0.25; done
}
restore_learning() {
  stop_ime
  if [[ -f "$LEARNING_BACKUP" ]]; then mv -f "$LEARNING_BACKUP" "$LEARNING"; else rm -f "$LEARNING"; fi
  open -g -W -n "$APP" --args --reconnect 2>/dev/null || true
}
stop_ime
if [[ -f "$LEARNING_BACKUP" ]]; then
  # A previous run was interrupted before it could restore: that backup is the user's file.
  rm -f "$LEARNING"
elif [[ -f "$LEARNING" ]]; then
  mv -f "$LEARNING" "$LEARNING_BACKUP"
fi
trap restore_learning EXIT
trap 'exit 130' INT TERM

echo "e2e: ${CASES:-inline cases} → $REPORT"
open -W -n --stdout "$REPORT" --stderr "$STDERR_LOG" "$APP" --args "${HARNESS_ARGS[@]}"

grep "\[harness\]" "$STDERR_LOG"
if grep -q -E "FAIL|timeout|usage:" "$STDERR_LOG" || ! grep -q -E "[0-9]+/[0-9]+ passed" "$STDERR_LOG"; then
  exit 1
fi
exit 0
