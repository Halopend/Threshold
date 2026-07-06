#!/bin/zsh
# golden-suite.sh — the standing golden-image regression gate (plan §9,
# Corpus/README.md). Run after any change that can touch pixels:
#
#   Scripts/golden-suite.sh                 # gate every corpus scene
#   Scripts/golden-suite.sh --no-build      # skip swift build (binary present)
#   Scripts/golden-suite.sh --update NAME   # (re)record Corpus/golden/NAME.png
#   Scripts/golden-suite.sh --update all    # (re)record every golden that exists
#
# Contract: each Corpus/scenes/*.threshscene is rendered headless at 512² by
# the deterministic threshold-render (FixedStepClock, no ambient time) — the
# same invocation is byte-identical on one GPU family. For every scene that
# has a Corpus/golden/<name>.png the output is byte-compared; scenes with no
# golden are still smoke-rendered (must not crash) and reported as PENDING.
#
# Result classes:
#   MATCH     golden exists and bytes are identical
#   MISMATCH  golden exists and bytes differ            -> suite fails (exit 1)
#   ERROR     render died / produced no file            -> suite fails (exit 1)
#   PENDING   no golden yet (new scene, or shader not ready) -> reported only
# A PENDING scene whose render is near-empty (all-black, tiny PNG) is tagged
# EMPTY? — a hint that its DE is not producing a surface in this build.
#
# Byte-compare is only valid within one GPU family (Apple silicon, M-family).
# Across families use a perceptual compare (not yet implemented).

set -euo pipefail
cd "$(dirname "$0")/.."

# BIN may be overridden to point at an out-of-tree build (e.g. one built with
# --scratch-path outside an iCloud-synced checkout); default is the in-tree
# debug product. When overridden, --no-build is implied.
BIN=${BIN:-.build/debug/threshold-render}
SCENES=Corpus/scenes
GOLDEN=Corpus/golden
WIDTH=512
HEIGHT=512
EMPTY_BYTES=20000        # a real 512² fractal PNG is >100 KB; <20 KB ≈ blank
BUILD=1
UPDATE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) BUILD=0; shift ;;
    --update) UPDATE="${2:-}"; [[ -n "$UPDATE" ]] || { echo "--update needs a scene name or 'all'" >&2; exit 1; }; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

# An out-of-tree BIN override brings its own binary — don't rebuild in-tree.
[[ "$BIN" == ".build/debug/threshold-render" ]] || BUILD=0

if [[ $BUILD -eq 1 ]]; then
  echo "building (debug)..."
  swift build --build-system native --product threshold-render 2>&1 \
    | grep -E "error:" && exit 1 || true
fi
[[ -x $BIN ]] || { echo "missing $BIN — build first (drop --no-build)" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --update: (re)record goldens, then exit. Only touches scenes that already
# have a golden (for 'all') or the single named scene.
if [[ -n "$UPDATE" ]]; then
  if [[ "$UPDATE" == "all" ]]; then
    targets=()
    for g in "$GOLDEN"/*.png(N); do targets+=("${g:t:r}"); done
  else
    targets=("$UPDATE")
  fi
  for name in $targets; do
    scene=$SCENES/$name.threshscene
    [[ -f $scene ]] || { echo "no scene $scene" >&2; exit 1; }
    $BIN "$scene" -w $WIDTH -h $HEIGHT --out "$GOLDEN/$name.png" --quiet 2>/dev/null
    echo "recorded → $GOLDEN/$name.png"
  done
  exit 0
fi

rev=$(git rev-parse --short HEAD 2>/dev/null || echo "no-git")
dirty=$(git diff --quiet 2>/dev/null && echo "" || echo "+dirty")
echo ""
echo "golden suite — ${WIDTH}x${HEIGHT} deterministic offscreen ($rev$dirty)"
printf "%-34s %-26s %-10s %s\n" "scene" "fractal" "result" "notes"

fail=0
n_match=0 n_mismatch=0 n_pending=0 n_error=0
for scene in "$SCENES"/*.threshscene(N); do
  name=${scene:t:r}
  fractal=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('fractalTypeKey','?'))" "$scene" 2>/dev/null || echo "?")
  out=$tmp/$name.png
  golden=$GOLDEN/$name.png
  notes=""

  if [[ -f $golden ]]; then
    rc=0
    $BIN "$scene" -w $WIDTH -h $HEIGHT --out "$out" --compare "$golden" --quiet 2>/dev/null || rc=$?
    case $rc in
      0) result=MATCH; n_match=$(( n_match + 1 )) ;;
      2) result=MISMATCH; n_mismatch=$(( n_mismatch + 1 )); fail=1 ;;
      *) result=ERROR; n_error=$(( n_error + 1 )); fail=1; notes="render exit $rc" ;;
    esac
  else
    rc=0
    $BIN "$scene" -w $WIDTH -h $HEIGHT --out "$out" --quiet 2>/dev/null || rc=$?
    if [[ $rc -ne 0 || ! -f $out ]]; then
      result=ERROR; n_error=$(( n_error + 1 )); fail=1; notes="render exit $rc"
    else
      result=PENDING; n_pending=$(( n_pending + 1 )); notes="no golden"
      sz=$(stat -f%z "$out" 2>/dev/null || echo 0)
      [[ $sz -lt $EMPTY_BYTES ]] && notes="no golden, EMPTY? (${sz}B — DE renders blank)"
    fi
  fi
  printf "%-34s %-26s %-10s %s\n" "$name" "$fractal" "$result" "$notes"
done

echo ""
echo "match=$n_match mismatch=$n_mismatch pending=$n_pending error=$n_error"
[[ $fail -eq 0 ]] || echo "FAIL — a golden drifted or a scene errored (see MISMATCH/ERROR rows)"
exit $fail
