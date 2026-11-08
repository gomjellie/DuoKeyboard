#!/bin/zsh
# Types every sentence of a corpus through the engine with the shipped model, then prints a report.
#
# Usage: Tools/scripts/corpus-typing.sh <corpus.tsv> <out.tsv> [--base <older-out.tsv>] [--limit N]
#                                       [--app <bundle id>]
#
#   corpus.tsv  source<TAB>id<TAB>text per line (Tools/scripts/community_corpus.py prep builds two).
#   out.tsv     one row per sentence: source, id, typable, correct, expected, produced, keys.
#   --base      also list the sentences that changed against an earlier out.tsv.
#   --limit     type only the first N sentences.
#   --app       type into that app's client profile (com.kakao.KakaoTalkMac is Korean first);
#               TextEdit when left out.
#
# Runs CorpusTypingTests (swift test, debug); each sentence gets a fresh engine, so no learning.
# Takes about 4 minutes for 58 000 sentences.
set -euo pipefail

SCRIPT="${0:A}"
ROOT="${SCRIPT:h:h:h}"
usage() { sed -n '2,15p' "$SCRIPT" | sed 's/^# \{0,1\}//'; }
(( $# >= 2 )) || { usage; exit 2; }
IN="${1:A}"
OUT="${2:A}"
shift 2
BASE=()
LIMIT=""
APP=""
while (( $# > 0 )); do
  case "$1" in
    --base) BASE=(--base "${2:A}"); shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --app) APP="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done
[[ -f "$IN" ]] || { echo "corpus-typing: no such corpus: $IN" >&2; exit 2; }

cd "$ROOT/Packages/DuoCore"
rm -f "$OUT"
LOG="$OUT.log"
if ! DUO_CORPUS_IN="$IN" DUO_CORPUS_OUT="$OUT" DUO_CORPUS_LIMIT="$LIMIT" DUO_CORPUS_APP="$APP" \
    swift test --scratch-path "$ROOT/build/spm" --filter CorpusTypingTests > "$LOG" 2>&1; then
  tail -20 "$LOG" >&2
  exit 1
fi
[[ -f "$OUT" ]] || { echo "corpus-typing: the test wrote nothing (is the model in place?), see $LOG" >&2; exit 1; }
python3 -I "$ROOT/Tools/scripts/community_corpus.py" report "$OUT" "${BASE[@]}"
