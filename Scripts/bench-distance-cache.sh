#!/bin/zsh
# Reproducible baseline/cold/warm A/B for the view-invariant distance cache.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=.build/release/threshold-render
OUT=${1:-docs/benchmarks/distance-cache}
SCENE=Corpus/scenes/bench-mandelbulb.threshscene
mkdir -p "$OUT"

swift build --build-system native -c release --product threshold-render

common=("$SCENE" -w 1024 -h 1024 --max-steps 120 --skip-grid 96 --quiet)
"$BIN" "${common[@]}" --bench 60 --bench-warmup 8 \
  --bench-json "$OUT/baseline.json"
"$BIN" "${common[@]}" --distance-cache --bench 1 --bench-warmup 0 \
  --bench-json "$OUT/cache-cold.json"
"$BIN" "${common[@]}" --distance-cache --bench 60 --bench-warmup 8 \
  --bench-json "$OUT/cache-warm.json" --out "$OUT/cache.png" \
  --cache-diagnostic "$OUT/cache-slice.png"

python3 - "$OUT" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
rows = []
for name in ("baseline", "cache-cold", "cache-warm"):
    d = json.loads((p / f"{name}.json").read_text())
    rows.append((name, d["medianMs"], d["medianFPS"], d["totalSteps"]))
base = rows[0][1]
lines = ["mode,median_ms,median_fps,total_steps,vs_baseline_percent"]
for name, ms, fps, steps in rows:
    lines.append(f"{name},{ms:.4f},{fps:.2f},{steps},{(base-ms)/base*100:.2f}")
(p / "summary.csv").write_text("\n".join(lines) + "\n")
print("\n".join(lines))
PY
