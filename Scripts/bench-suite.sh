#!/bin/zsh
# bench-suite.sh — the standing perf regression suite. Run after every code
# change:
#
#   Scripts/bench-suite.sh -m "what was tested this run"
#   Scripts/bench-suite.sh --frames 120 -m "long soak"   # more frames
#   Scripts/bench-suite.sh --no-build -m "..."           # skip swift build
#   Scripts/bench-suite.sh --set-baseline -m "..."       # snapshot medians → baseline.json
#   Scripts/bench-suite.sh --strict-baseline -m "..."    # FAIL on > tol% median regression
#
# Contract: bench-mandelbox scene (mandelbox, iterations 9), maxSteps pinned
# to 120, SPECIALIZED pipeline, offscreen headless renderer. This path has NO
# quality governor / auto-quality / MetalFX — renderScale is fixed at 1, so
# every run marches identical pixels (the consistency guarantee; the live
# app's Auto Quality cannot affect these numbers).
#
# Per resolution (1024², 1800², 2048²): warmup then FRAMES measured frames,
# GPU-time medians from the command buffer. Goal line: ≥ 70 fps at 2048² (TARGET_FPS_2048).
#
# Each run also records (ADR-006 Phase 0): cov% (noise band = σ/mean), ns/step
# (median GPU time ÷ the deterministic per-frame march step count, recovered
# from a stats-ON pipeline twin so the timing pass stays atomic-free), thermal
# state, and — when bench-results/baseline.json exists — Δ% vs the baseline
# median. These land in history.jsonl + the console; history.csv keeps its
# legacy 16-column schema untouched.
#
# Results:
#   bench-results/history.csv    one row per (run, resolution) + the note
#   bench-results/history.jsonl  same data + cov/ns-step/thermal/Δ, machine-friendly
#   bench-results/last-<res>.json  full per-frame samples of the latest run
#   bench-results/baseline.json    per-res reference medians (--set-baseline)

set -euo pipefail
cd "$(dirname "$0")/.."

SCENE=Corpus/scenes/bench-mandelbox.threshscene
BIN=.build/release/threshold-render
# Default sink is the committed bench-results/; BENCH_RESULTS_DIR redirects it
# (CI / scratch runs that must not append to the perf history).
RESULTS=${BENCH_RESULTS_DIR:-bench-results}
FRAMES=260
WARMUP=10
MAX_STEPS=120
TARGET_FPS_2048=70
RESOLUTIONS=(1024 1800 2048)
# history rows end with platform,views tags (on-device stereo runs log visionOS,2)
PLATFORM=mac
VIEWS=1
NOTE=""
BUILD=1
BASELINE=$RESULTS/baseline.json
SET_BASELINE=0
STRICT_BASELINE=0
REGRESS_TOL=3       # % median regression that trips --strict-baseline

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--note) NOTE="$2"; shift 2 ;;
    --frames) FRAMES="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    --set-baseline) SET_BASELINE=1; shift ;;
    --strict-baseline) STRICT_BASELINE=1; shift ;;
    --tol) REGRESS_TOL="$2"; shift 2 ;;
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
printf "%-11s %9s %7s %6s %8s %7s %8s %s\n" \
  "resolution" "med ms" "fps" "cov%" "ns/step" "delta%" "thermal" "goal"

fail=0
row_json=""
base_json=""
for res in "${RESOLUTIONS[@]}"; do
  json=$RESULTS/last-${res}.json
  $BIN "$SCENE" -w $res -h $res --max-steps $MAX_STEPS --specialize \
    --bench $FRAMES --bench-warmup $WARMUP --bench-json "$json" --quiet \
    > /dev/null
  read median mean p95 minv maxv fps cov nsstep steps thermal deltapct <<< "$(python3 -c "
import json, os, math
d = json.load(open('$json'))
base = None
if os.path.exists('$BASELINE'):
    try:
        base = json.load(open('$BASELINE')).get('$res')
    except Exception:
        base = None
median = d['medianMs']
delta = (median - base) / base * 100.0 if base else float('nan')
ds = 'nan' if math.isnan(delta) else f'{delta:.1f}'
print(f\"{median:.2f} {d['meanMs']:.2f} {d['p95Ms']:.2f} {d['minMs']:.2f} \"
      f\"{d['maxMs']:.2f} {d['medianFPS']:.1f} {d.get('covPct',0):.1f} \"
      f\"{d.get('nsPerStep',0):.1f} {d.get('stepsPerFrame',0)} \"
      f\"{d.get('thermalState','?')} {ds}\")")"
  if [[ "$deltapct" == "nan" ]]; then delta_disp="-"; delta_json="null"
  else delta_disp="${deltapct}%"; delta_json="$deltapct"; fi
  goal="-"
  if [[ $res -eq 2048 ]]; then
    if python3 -c "exit(0 if $fps >= $TARGET_FPS_2048 else 1)"; then
      goal="PASS(≥${TARGET_FPS_2048})"
    else
      goal="FAIL(<${TARGET_FPS_2048})"; fail=1
    fi
  fi
  # --strict-baseline: a median regression beyond REGRESS_TOL% trips the suite
  # at ANY resolution (the absolute 2048² floor above is independent).
  if [[ $STRICT_BASELINE -eq 1 && "$deltapct" != "nan" ]]; then
    if python3 -c "exit(0 if $deltapct > $REGRESS_TOL else 1)"; then
      goal="${goal} REGRESS(+${deltapct}%)"; fail=1
    fi
  fi
  printf "%-11s %9s %7s %6s %8s %7s %8s %s\n" \
    "${res}x${res}" "$median" "$fps" "$cov" "$nsstep" "$delta_disp" "$thermal" "$goal"
  csv_note=${NOTE//\"/\"\"}
  echo "$stamp,$rev$dirty,\"$csv_note\",bench-mandelbox,$MAX_STEPS,$FRAMES,$res,$median,$mean,$p95,$minv,$maxv,$fps,$goal,$PLATFORM,$VIEWS" >> "$CSV"
  row_json+="\"$res\":{\"medianMs\":$median,\"meanMs\":$mean,\"p95Ms\":$p95,\"minMs\":$minv,\"maxMs\":$maxv,\"fps\":$fps,\"covPct\":$cov,\"nsPerStep\":$nsstep,\"stepsPerFrame\":$steps,\"thermal\":\"$thermal\",\"deltaPct\":$delta_json},"
  base_json+="\"$res\":$median,"
done

if [[ $SET_BASELINE -eq 1 ]]; then
  echo "{${base_json%,}}" > "$BASELINE"
  echo "baseline updated → $BASELINE"
fi

note_json=${NOTE//\\/\\\\}; note_json=${note_json//\"/\\\"}
echo "{\"time\":\"$stamp\",\"rev\":\"$rev$dirty\",\"platform\":\"$PLATFORM\",\"note\":\"$note_json\",\"scene\":\"bench-mandelbox\",\"maxSteps\":$MAX_STEPS,\"frames\":$FRAMES,\"views\":$VIEWS,\"resolutions\":{${row_json%,}}}" \
  >> "$RESULTS/history.jsonl"
echo ""
echo "logged → $CSV"
exit $fail
