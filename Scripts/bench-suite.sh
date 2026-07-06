#!/bin/zsh
# bench-suite.sh — the standing perf regression suite. Run after every code
# change:
#
#   Scripts/bench-suite.sh -m "what was tested this run"
#   Scripts/bench-suite.sh --frames 120 -m "long soak"   # more frames
#   Scripts/bench-suite.sh --no-build -m "..."           # skip swift build
#   Scripts/bench-suite.sh --tg 16x16 -m "..."           # march threadgroup A/B
#   Scripts/bench-suite.sh --scene bench-kleinian -m ".." # one scene only
#   BIN=/path/threshold-render Scripts/bench-suite.sh --no-build -m ".."
#
# Contract: a fixed set of bench-<type> scenes spanning the DE cost spectrum,
# each pinned to iterations 9, maxSteps 120, SPECIALIZED pipeline, offscreen
# headless renderer. This path has NO quality governor / auto-quality /
# MetalFX — renderScale is fixed at 1, so every run marches identical pixels
# (the consistency guarantee; the live app's Auto Quality cannot affect these
# numbers). GPU-time medians come from the command buffer, so a debug BIN
# reports the same GPU cost as release (only CPU-side setup differs).
#
# The scenes (all share the off-axis default camera so kleinian/MSP render —
# kleinian needs off-axis, MSP needs its scene-embedded safety bubble):
#   bench-mandelbox    box folds — the historical baseline + the GATED scene
#   bench-mandelbulb   power-8 pow/log
#   bench-menger       abs/sort folds (cheap)
#   bench-kleinian     pseudo-Kleinian cylinder DE (expensive)
#   bench-quaternion   quaternion Julia
#   bench-msp          mandelbox sphere-projection (bubble on)
#
# Per resolution (1024², 1800², 2048²): warmup then FRAMES measured frames.
# Goal line: ≥ 30 fps at 2048² — enforced ONLY for bench-mandelbox (the other
# scenes are informational; their per-DE cost varies too much for one gate).
#
# Results:
#   bench-results/history.csv    one row per (run, scene, resolution) + note
#   bench-results/history.jsonl  same data, machine-friendly (one obj/scene)
#   bench-results/last-<scene>-<res>.json  full per-frame samples, latest run

set -euo pipefail
cd "$(dirname "$0")/.."

# BIN may be overridden to a prebuilt (e.g. out-of-tree) binary; default is the
# in-tree release product. GPU-time medians are build-config-independent.
BIN=${BIN:-.build/release/threshold-render}
RESULTS=${RESULTS:-bench-results}       # override to a scratch dir for dry runs
FRAMES=60
WARMUP=10
MAX_STEPS=120
TARGET_FPS_2048=30
GATED_SCENE=bench-mandelbox            # only this scene's 2048² fails the suite
RESOLUTIONS=(1024 1800 2048)
SCENES=(bench-mandelbox bench-mandelbulb bench-menger bench-kleinian bench-quaternion bench-msp)
# history rows end with tg,platform,views tags (on-device stereo runs log visionOS,2)
PLATFORM=mac
VIEWS=1
TG=8x8   # march threadgroup shape → THRESHOLD_TG env seam (engine default 8x8)
NOTE=""
BUILD=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--note) NOTE="$2"; shift 2 ;;
    --frames) FRAMES="$2"; shift 2 ;;
    --scene) SCENES=("$2"); shift 2 ;;      # bench a single named scene
    --tg) TG="$2"; shift 2 ;;               # march threadgroup shape A/B
    --no-build) BUILD=0; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
if [[ -z "$NOTE" ]]; then
  echo "note required: what is this run testing? (-m \"...\")" >&2
  exit 1
fi
# Must mirror OffscreenRenderer's THRESHOLD_TG parse — a malformed value falls
# back to 8x8 SILENTLY in-engine, which would mislabel the CSV row.
if [[ ! "$TG" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]]; then
  echo "--tg expects WxH (e.g. 16x16), got '$TG'" >&2
  exit 1
fi

# An out-of-tree BIN override brings its own binary — don't rebuild in-tree.
[[ "$BIN" == ".build/release/threshold-render" ]] || BUILD=0

if [[ $BUILD -eq 1 ]]; then
  echo "building (release)..."
  swift build --build-system native -c release --product threshold-render 2>&1 \
    | grep -E "error" && exit 1 || true
fi
[[ -x $BIN ]] || { echo "missing $BIN" >&2; exit 1; }

mkdir -p "$RESULTS"
CSV=$RESULTS/history.csv
[[ -f $CSV ]] || echo "time,rev,note,scene,maxSteps,frames,resolution,medianMs,meanMs,p95Ms,minMs,maxMs,fps,goal,tg,platform,views" > "$CSV"

rev=$(git rev-parse --short HEAD 2>/dev/null || echo "no-git")
dirty=$(git diff --quiet 2>/dev/null && echo "" || echo "+dirty")
stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo ""
echo "perf suite — iters=9 maxSteps=$MAX_STEPS specialized, ${FRAMES}f, ${#SCENES[@]} scenes, tg=$TG ($rev$dirty)"
echo "note: $NOTE"

fail=0
for scene in "${SCENES[@]}"; do
  scenePath=Corpus/scenes/${scene}.threshscene
  [[ -f $scenePath ]] || { echo "missing scene $scenePath" >&2; exit 1; }
  echo ""
  echo "▸ $scene"
  printf "%-12s %10s %8s %8s %8s %8s %10s\n" \
    "resolution" "median ms" "fps" "mean ms" "p95 ms" "max ms" "goal"
  row_json=""
  for res in "${RESOLUTIONS[@]}"; do
    json=$RESULTS/last-${scene}-${res}.json
    THRESHOLD_TG=$TG $BIN "$scenePath" -w $res -h $res --max-steps $MAX_STEPS --specialize \
      --bench $FRAMES --bench-warmup $WARMUP --bench-json "$json" --quiet \
      > /dev/null
    read median mean p95 minv maxv fps <<< "$(python3 -c "
import json
d = json.load(open('$json'))
print(f\"{d['medianMs']:.2f} {d['meanMs']:.2f} {d['p95Ms']:.2f} \"
      f\"{d['minMs']:.2f} {d['maxMs']:.2f} {d['medianFPS']:.1f}\")")"
    goal="-"
    if [[ "$scene" == "$GATED_SCENE" && $res -eq 2048 ]]; then
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
    echo "$stamp,$rev$dirty,\"$csv_note\",$scene,$MAX_STEPS,$FRAMES,$res,$median,$mean,$p95,$minv,$maxv,$fps,$goal,$TG,$PLATFORM,$VIEWS" >> "$CSV"
    row_json+="\"$res\":{\"medianMs\":$median,\"meanMs\":$mean,\"p95Ms\":$p95,\"minMs\":$minv,\"maxMs\":$maxv,\"fps\":$fps},"
  done
  note_json=${NOTE//\\/\\\\}; note_json=${note_json//\"/\\\"}
  echo "{\"time\":\"$stamp\",\"rev\":\"$rev$dirty\",\"platform\":\"$PLATFORM\",\"note\":\"$note_json\",\"scene\":\"$scene\",\"maxSteps\":$MAX_STEPS,\"frames\":$FRAMES,\"views\":$VIEWS,\"tg\":\"$TG\",\"resolutions\":{${row_json%,}}}" \
    >> "$RESULTS/history.jsonl"
done

echo ""
echo "logged → $CSV"
exit $fail
