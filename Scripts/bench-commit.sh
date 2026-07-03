#!/bin/zsh
# bench-commit.sh — the perf-tracked commit flow. One command:
#
#   Scripts/bench-commit.sh -m "what changed"
#
# does, in order:
#   1. Commits the working tree to the CURRENT branch (message = the note).
#      The tree is then CLEAN, so the suite records the exact commit SHA —
#      no "+dirty" ambiguity between a CSV row and the code it measured.
#   2. Runs Scripts/bench-suite.sh (60-frame triplet).
#   3. Attaches the result table to the code commit as a GIT NOTE
#      (refs/notes/bench) — perf lives IN main's history without touching
#      the commit or the tree:  git log --oneline --notes=bench
#   4. Archives bench-results/ (CSV + per-run JSONs) to the bench-history
#      branch — an orphan, results-only branch; every commit there names the
#      main-branch SHA it measured, so CSV rows ↔ code states is a pure
#      lookup in either direction.
#
# Reading the history later:
#   git log --oneline --notes=bench              # code commits + their perf
#   git log bench-history --oneline              # chronology of runs
#   git show bench-history:history.csv           # the full CSV
#   awk -F, '$7==2048' <(git show bench-history:history.csv)   # one res
#
# Flags: --skip-commit  bench + record an ALREADY-committed clean tree
#        --frames N     forwarded to bench-suite.sh

set -euo pipefail
cd "$(dirname "$0")/.."

NOTE=""
FRAMES=""
DO_COMMIT=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--note) NOTE="$2"; shift 2 ;;
    --frames) FRAMES="--frames $2"; shift 2 ;;
    --skip-commit) DO_COMMIT=0; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$NOTE" ]] || { echo "need -m \"what changed\"" >&2; exit 1; }

# --- 1. commit the code ------------------------------------------------------
if [[ $DO_COMMIT -eq 1 ]]; then
  if ! git diff --quiet || ! git diff --cached --quiet \
     || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
    git add -A
    git commit -m "$NOTE" -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
  fi
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "tree still dirty — refusing to bench an ambiguous state" >&2
  exit 1
fi
sha=$(git rev-parse --short HEAD)

# --- 2. bench (goal failure is RECORDED, not fatal to the recording) ---------
set +e
Scripts/bench-suite.sh -m "$NOTE" $FRAMES
suite_status=$?
set -e

# --- 3. git note on the code commit ------------------------------------------
summary=$(python3 - <<'EOF'
import json
rows = []
for res in (1024, 1800, 2048):
    try:
        d = json.load(open(f"bench-results/last-{res}.json"))
        rows.append(f"{res}x{res}: {d['medianMs']:.2f} ms ({d['medianFPS']:.1f} fps) p95 {d['p95Ms']:.2f}")
    except FileNotFoundError:
        rows.append(f"{res}x{res}: (missing)")
print("\n".join(rows))
EOF
)
git notes --ref=bench add -f -m "bench (mandelbox iters=9 steps=120, specialized):
$summary
goal 2048>=30fps: $([[ $suite_status -eq 0 ]] && echo PASS || echo FAIL)" HEAD

# --- 4. archive to the bench-history branch ----------------------------------
if ! git show-ref --verify --quiet refs/heads/bench-history; then
  empty=$(git hash-object -t tree /dev/null)
  root=$(git commit-tree "$empty" -m "bench-history: results-only branch (Scripts/bench-commit.sh)")
  git branch bench-history "$root"
fi
if [[ ! -d .bench-history ]]; then
  git worktree add .bench-history bench-history > /dev/null
fi
stamp=$(date -u +%Y%m%dT%H%M%SZ)
run_dir=".bench-history/runs/${stamp}-${sha}"
mkdir -p "$run_dir"
cp bench-results/history.csv bench-results/history.jsonl .bench-history/
cp bench-results/last-*.json "$run_dir/" 2>/dev/null || true
git -C .bench-history add -A
git -C .bench-history commit -q -m "bench: $sha $NOTE" \
  -m "Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" || true

echo ""
echo "code commit $sha noted (git log --oneline --notes=bench)"
echo "results archived on bench-history ($(git -C .bench-history rev-parse --short HEAD))"
exit $suite_status
