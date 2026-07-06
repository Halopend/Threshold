#!/bin/zsh
# bench-suite.sh — the standing perf regression suite. Run after every code
# change:
#
#   Scripts/bench-suite.sh -m "what was tested this run"
#   Scripts/bench-suite.sh --frames 120 -m "long soak"   # more frames
#   Scripts/bench-suite.sh --no-build -m "..."           # skip swift build
#
# Contract: bench-mandelbox scene (mandelbox, iterations 9), maxSteps pinned
# to 120, SPECIALIZED pipeline, offscreen headless renderer. This path has NO
# quality governor / auto-quality / MetalFX — renderScale is fixed at 1, so
# every run marches identical pixels (the consistency guarantee; the live
# app's Auto Quality cannot affect these numbers).
#
# Per resolution (1024², 1800², 2048²): warmup then FRAMES measured frames,
# GPU-time medians from the command buffer. Goal line: ≥ 30 fps at 2048².
#
# Results:
#   bench-results/history.csv    one row per (run, resolution) + the note
#   bench-results/history.jsonl  same data, machine-friendly
#   bench-results/last-<res>.json  full per-frame samples of the latest run

set -euo pipefail
cd "$(dirname "$0")/.."

SCENE=Corpus/scenes/bench-mandelbox.threshscene
BIN=.build/release/threshold-render
RESULTS=bench-results
FRAMES=60
WARMUP=10
MAX_STEPS=120
TARGET_FPS_2048=30
RESOLUTIONS=(1024 1800 2048)
# history rows end with platform,views tags (on-device stereo runs log visionOS,2)
PLATFORM=mac
VIEWS=1
NOTE=""
BUILD=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--note) NOTE="$2"; shift 2 ;;
    --frames) FRAMES="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
if [[ -z "$NOTE" ]]; then
  echo "note required: what is this run testing? (-m \"...\")" >&2
  exit 1
fi

if [[ $BUILD -eq 1 ]]; then
  echo "building (release)..."
  swift build --build-system native -c release --product threshold-render 2>&1 \
    | grep -E "error" && exit 1 || true
fi
[[ -x $BIN ]] || { echo "missing $BIN" >&2; exit 1; }

mkdir -p "$RESULTS"
CSV=$RESULTS/history.csv
[[ -f $CSV ]] || echo "time,rev,note,scene,maxSteps,frames,resolution,medianMs,meanMs,p95Ms,minMs,maxMs,fps,goal,platform,views" > "$CSV"

rev=$(git rev-parse --short HEAD 2>/dev/null || echo "no-git")
dirty=$(git diff --quiet 2>/dev/null && echo "" || echo "+dirty")
stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo ""
echo "perf suite — mandelbox iters=9 maxSteps=$MAX_STEPS specialized, ${FRAMES}f ($rev$dirty)"
echo "note: $NOTE"
printf "%-12s %10s %8s %8s %8s %8s %10s\n" \
  "resolution" "median ms" "fps" "mean ms" "p95 ms" "max ms" "goal"

fail=0
row_json=""
for res in "${RESOLUTIONS[@]}"; do
  json=$RESULTS/last-${res}.json
  $BIN "$SCENE" -w $res -h $res --max-steps $MAX_STEPS --specialize \
    --bench $FRAMES --bench-warmup $WARMUP --bench-json "$json" --quiet \
    > /dev/null
  read median mean p95 minv maxv fps <<< "$(python3 -c "
import json
d = json.load(open('$json'))
print(f\"{d['medianMs']:.2f} {d['meanMs']:.2f} {d['p95Ms']:.2f} \"
      f\"{d['minMs']:.2f} {d['maxMs']:.2f} {d['medianFPS']:.1f}\")")"
  goal="-"
  if [[ $res -eq 2048 ]]; then
    if python3 -c "exit(0 if $fps >= $TARGET_FPS_2048 else 1)"; then
      goal="PASS(≥${TARGET_FPS_2048})"
    else
      goal="FAIL(<${TARGET_FPS_2048})"
      fail=1
    fi
  fi
  printf "%-12s %10s %8s %8s %8s %8s %10s\n" \
    "${res}x${res}" "$median" "$fps" "$mean" "$p95" "$maxv" "$goal"
  csv_note=${NOTE//\"/\"\"}
  echo "$stamp,$rev$dirty,\"$csv_note\",bench-mandelbox,$MAX_STEPS,$FRAMES,$res,$median,$mean,$p95,$minv,$maxv,$fps,$goal,$PLATFORM,$VIEWS" >> "$CSV"
  row_json+="\"$res\":{\"medianMs\":$median,\"meanMs\":$mean,\"p95Ms\":$p95,\"minMs\":$minv,\"maxMs\":$maxv,\"fps\":$fps},"
done

note_json=${NOTE//\\/\\\\}; note_json=${note_json//\"/\\\"}
echo "{\"time\":\"$stamp\",\"rev\":\"$rev$dirty\",\"platform\":\"$PLATFORM\",\"note\":\"$note_json\",\"scene\":\"bench-mandelbox\",\"maxSteps\":$MAX_STEPS,\"frames\":$FRAMES,\"views\":$VIEWS,\"resolutions\":{${row_json%,}}}" \
  >> "$RESULTS/history.jsonl"
echo ""
echo "logged → $CSV"
exit $fail
