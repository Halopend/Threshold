#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=.build/release/threshold-render
OUT=${1:-docs/benchmarks/frequency-aa}
SCENE=Corpus/scenes/bench-mandelbulb.threshscene
mkdir -p "$OUT"
swift build --build-system native -c release --product threshold-render

common=("$SCENE" -w 1024 -h 1024 --max-steps 120 --quiet)
"$BIN" "${common[@]}" --bench 60 --bench-warmup 8 \
  --bench-json "$OUT/baseline.json" --out "$OUT/baseline.png"
for threshold in 0.75 1.0 1.15 1.25 1.35 1.5; do
  "$BIN" "${common[@]}" --frequency-aa --frequency-grid 64 \
    --frequency-threshold $threshold --bench 60 --bench-warmup 8 \
    --bench-json "$OUT/frequency-$threshold.json" \
    --out "$OUT/frequency-$threshold.png" \
    --frequency-diagnostic "$OUT/frequency-slice-$threshold.png"
done

python3 - "$OUT" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
base = json.loads((p / "baseline.json").read_text())
rows = [("baseline", "", base)]
for threshold in ("0.75", "1.0", "1.15", "1.25", "1.35", "1.5"):
    rows.append(("frequency", threshold,
                 json.loads((p / f"frequency-{threshold}.json").read_text())))
lines = ["mode,threshold,median_ms,fps,vs_baseline_percent,total_steps"]
for mode, threshold, result in rows:
    delta = (result["medianMs"] - base["medianMs"]) / base["medianMs"] * 100
    lines.append(f"{mode},{threshold},{result['medianMs']:.4f},"
                 f"{result['medianFPS']:.2f},{delta:.2f},{result['totalSteps']}")
(p / "summary.csv").write_text("\n".join(lines) + "\n")
print("\n".join(lines))
PY
