#!/bin/zsh
# device-bench.sh — the ON-DEVICE sibling of bench-suite.sh.
#
# bench-suite.sh times the raymarch on the Mac GPU (offscreen CLI). This runs
# the SAME FrameBenchmark on the raymarch's Metal-compute path on a PHYSICAL
# Apple Vision Pro — headless, from the CLI, no immersive space, no simulator.
# Each measured frame renders BOTH eye views (stereo) and sums their GPU time.
#
#   Scripts/device-bench.sh -m "what changed"        # auto-detect the AVP
#   Scripts/device-bench.sh -m "..." --device <UDID> # or name one
#
# It logs a row to the SHARED bench-results/history.csv, tagged platform=visionOS
# (the last two columns are `platform,views`, so filter with:
#   awk -F, '$(NF-1)=="visionOS"' bench-results/history.csv     # device rows
#   awk -F, '$(NF-1)=="mac"'      bench-results/history.csv     # Mac rows
#
# WHAT IT MEASURES: GPU KERNEL cost of a stereo frame (both eyes' GPU ms summed)
# — a RELATIVE comparator across optimization rounds on the same warm device. It
# is NOT the delivered compositor frame cost: the real per-eye views are
# FOVEATED, so two FULL views is an upper bound; and the GPU clock is not pinned
# (DVFS/thermal float absolute ms). See DeviceBenchTests/DeviceGPUBenchTests.swift.
#
# Prereqs: the AVP is paired, trusted, in Developer Mode, and AWAKE. Resolution
# / frames / warmup / maxSteps / view-count are the THRESHOLD_BENCH_* defaults
# baked in the test source (1024², 120f, 2 views); change them there.

set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME=ThresholdDeviceBenchTests
BUNDLE_ID=com.pupppower.thresholdb3
# DerivedData MUST live outside this iCloud-synced repo: iCloud stamps FinderInfo
# xattrs on the build products and codesign then rejects the .xctest with
# "resource fork, Finder information, or similar detritus not allowed" (same
# reason `swift test` needs --scratch-path outside the repo).
DD="${TMPDIR:-/tmp}/threshold-device-bench-dd"
RESULTS=bench-results
DEVICE=""
NOTE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--note) NOTE="$2"; shift 2 ;;
    --device) DEVICE="$2"; shift 2 ;;
    -*) echo "unknown arg: $1" >&2; exit 1 ;;
    *) DEVICE="$1"; shift ;;   # bare positional = UDID (back-compat)
  esac
done
[[ -n "$NOTE" ]] || NOTE="device run"

# Auto-detect a connected physical Apple Vision Pro if no UDID was given.
if [[ -z "$DEVICE" ]]; then
  DEVICE=$(xcrun devicectl list devices 2>/dev/null \
    | awk '/Apple Vision Pro/ && /connected/ {
        for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-Fa-f]{8}-/) { print $i; exit }
      }')
fi
[[ -n "$DEVICE" ]] || {
  echo "no connected Apple Vision Pro found — pass a UDID as arg 1" >&2
  echo "  (list with: xcrun devicectl list devices)" >&2
  exit 1
}
echo "device: $DEVICE"

mkdir -p "$RESULTS"
RB="$(mktemp -d)/device-bench.xcresult"

echo "building + running on device (first run compiles everything)..."
LOG="$(dirname "$RB")/xcodebuild.log"
# Gate on xcodebuild SUCCESS: a failed build/test must NOT fall through to pull
# a stale JSON and log garbage (as an early codesign-FinderInfo failure did).
if xcodebuild test \
     -scheme "$SCHEME" \
     -destination "platform=visionOS,id=$DEVICE" \
     -derivedDataPath "$DD" \
     -resultBundlePath "$RB" \
     -allowProvisioningUpdates > "$LOG" 2>&1; then
  grep -E 'DEVICE-BENCH|Test .*(passed|failed)' "$LOG" || true
else
  echo "xcodebuild test FAILED — not pulling/logging results. Detail:" >&2
  grep -E 'error:|Testing failed|resource fork|CodeSign|could not|not connected|locked' "$LOG" \
    | tail -8 >&2
  echo "full log: $LOG" >&2
  exit 1
fi

# Pull the structured FrameBenchmark.Result JSON off the headset.
JSON="$RESULTS/device-last.json"
if ! xcrun devicectl device copy from --device "$DEVICE" \
       --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
       --source Documents/threshold-device-bench.json \
       --destination "$JSON" 2>/dev/null; then
  echo "note: could not pull JSON — use the DEVICE-BENCH line above; no CSV row logged" >&2
  exit 0
fi
echo "pulled → $JSON"

# Append a Vision-Pro-tagged row to the SHARED history (same schema as the Mac
# suite; the trailing platform,views columns are the tag).
CSV="$RESULTS/history.csv"
[[ -f $CSV ]] || echo "time,rev,note,scene,maxSteps,frames,resolution,medianMs,meanMs,p95Ms,minMs,maxMs,fps,goal,platform,views" > "$CSV"
rev=$(git rev-parse --short HEAD 2>/dev/null || echo "no-git")
dirty=$(git diff --quiet 2>/dev/null && echo "" || echo "+dirty")
stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

csv_note=${NOTE//\"/\"\"}
note_json=${NOTE//\\/\\\\}; note_json=${note_json//\"/\\\"}

# The JSON is a SWEEP: {deviceName, deKey, maxSteps, frames, runs:[{size,views,result}]}.
# Emit one TSV line per run, then log one CSV/jsonl row each.
rows="$(python3 - "$JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for e in d["runs"]:
    r = e["result"]
    print("\t".join(str(x) for x in [
        e["size"], e["views"], d["frames"], d["maxSteps"], d["deKey"],
        f"{r['medianMs']:.2f}", f"{r['meanMs']:.2f}", f"{r['p95Ms']:.2f}",
        f"{r['minMs']:.2f}", f"{r['maxMs']:.2f}", f"{r['medianFPS']:.1f}"]))
PY
)"
if [[ -z "$rows" ]]; then
  echo "could not parse $JSON (stale/empty sweep?) — no rows logged" >&2
  exit 1
fi

n=0
printf "\n  %-9s %5s %11s %8s %9s\n" "per-eye" "eyes" "median ms" "fps" "p95 ms"
while IFS=$'\t' read -r size views frames maxsteps scene median mean p95 minv maxv fps; do
  [[ -n "$size" ]] || continue
  echo "$stamp,$rev$dirty,\"$csv_note\",$scene,$maxsteps,$frames,$size,$median,$mean,$p95,$minv,$maxv,$fps,-,visionOS,$views" >> "$CSV"
  echo "{\"time\":\"$stamp\",\"rev\":\"$rev$dirty\",\"platform\":\"visionOS\",\"note\":\"$note_json\",\"scene\":\"$scene\",\"maxSteps\":$maxsteps,\"frames\":$frames,\"views\":$views,\"resolution\":$size,\"medianMs\":$median,\"meanMs\":$mean,\"p95Ms\":$p95,\"minMs\":$minv,\"maxMs\":$maxv,\"fps\":$fps}" \
    >> "$RESULTS/history.jsonl"
  printf "  %-9s %5s %11s %8s %9s\n" "${size}²" "$views" "$median" "$fps" "$p95"
  n=$((n + 1))
done <<< "$rows"

echo ""
echo "logged $n row(s) → $CSV (platform=visionOS)"
