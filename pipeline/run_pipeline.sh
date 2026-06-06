#!/usr/bin/env bash
# ============================================================
# SpecEval-Guided Code Generation Pipeline
#
# Runs two parallel tracks — guided (with verification context)
# and baseline (description only) — then compares results.
#
# Usage:
#   bash pipeline/run_pipeline.sh <run_dir> "goal description"
#
# Arguments:
#   run_dir  — path to a speceval run (e.g. runs/005-a-banking-transfer-system-with-audit-logging/)
#   goal     — one-line feature description
#
# Prerequisites:
#   - claude CLI installed and authenticated (Claude Code Max subscription)
#   - Python 3.10+
#   - pytest
# ============================================================

set -euo pipefail

# --- Color output helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[pipeline]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }

# --- Argument validation ---
if [[ $# -lt 2 ]]; then
    echo "Usage: bash pipeline/run_pipeline.sh <run_dir> \"goal description\""
    echo ""
    echo "  run_dir  — path to a speceval run directory"
    echo "  goal     — one-line feature description"
    exit 1
fi

RUN_DIR="$(realpath "$1")"
GOAL="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Validate run directory
if [[ ! -d "$RUN_DIR" ]]; then
    err "Run directory does not exist: $RUN_DIR"
    exit 1
fi

if [[ ! -f "$RUN_DIR/feature_model.manifest.json" ]]; then
    err "No feature_model.manifest.json found in $RUN_DIR"
    err "Run speceval first to generate verification artifacts."
    exit 1
fi

# Check claude CLI is available
if ! command -v claude &>/dev/null; then
    err "claude CLI not found. Install Claude Code first."
    exit 1
fi

# ============================================================
# Step 1: Setup workspace
# ============================================================

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
WORKSPACE="$PROJECT_ROOT/pipeline_runs/$TIMESTAMP"
mkdir -p "$WORKSPACE"

log "Workspace: $WORKSPACE"
log "Run dir:   $RUN_DIR"
log "Goal:      $GOAL"

# Copy prompts into workspace for reproducibility
cp -r "$SCRIPT_DIR/prompts" "$WORKSPACE/prompts"

# Save run metadata
cat > "$WORKSPACE/metadata.json" <<METAEOF
{
  "timestamp": "$TIMESTAMP",
  "run_dir": "$RUN_DIR",
  "goal": "$GOAL",
  "pipeline_version": "1.0.0"
}
METAEOF

ok "Workspace created"

# ============================================================
# Step 2: Extract verification context
# ============================================================

log "Extracting verification context..."

python3 "$SCRIPT_DIR/extract_verification_context.py" \
    "$RUN_DIR" \
    -o "$WORKSPACE/verification_context.md"

if [[ ! -f "$WORKSPACE/verification_context.md" ]]; then
    err "Failed to extract verification context"
    exit 1
fi

ok "Verification context extracted"

# ============================================================
# Step 3 & 4: Run guided and baseline tracks in parallel
# ============================================================

# --- Track A: Guided ---
run_guided() {
    local track_dir="$WORKSPACE/guided"
    mkdir -p "$track_dir"
    cd "$track_dir"

    log "[guided] Starting code generation..."

    # Code generation with verification context piped in
    claude -p "$(cat "$WORKSPACE/verification_context.md")

---

Goal: $GOAL

Generate a complete implementation following the verification context above." \
        --append-system-prompt-file "$WORKSPACE/prompts/guided_codegen.md" \
        --allowedTools "Read,Edit,Write,Bash" \
        --permission-mode bypassPermissions \
        --max-turns 30 \
        --output-format json \
        > "$track_dir/codegen_result.json" 2>"$track_dir/codegen_stderr.log" || {
        warn "[guided] Code generation exited with non-zero status"
    }

    ok "[guided] Code generation complete"

    # Test generation
    log "[guided] Starting test generation..."

    claude -p "Read the codebase in the current directory and write comprehensive tests." \
        --append-system-prompt-file "$WORKSPACE/prompts/guided_testgen.md" \
        --allowedTools "Read,Edit,Write,Bash" \
        --permission-mode bypassPermissions \
        --max-turns 20 \
        --output-format json \
        > "$track_dir/testgen_result.json" 2>"$track_dir/testgen_stderr.log" || {
        warn "[guided] Test generation exited with non-zero status"
    }

    ok "[guided] Test generation complete"

    # Run tests
    log "[guided] Running tests..."
    if [[ -d "$track_dir/tests" ]]; then
        python3 -m pytest "$track_dir/tests/" -v --tb=short \
            > "$track_dir/test_results.txt" 2>&1 || true
        ok "[guided] Tests finished (see test_results.txt)"
    else
        warn "[guided] No tests/ directory found"
        echo "No tests directory found" > "$track_dir/test_results.txt"
    fi
}

# --- Track B: Baseline ---
run_baseline() {
    local track_dir="$WORKSPACE/baseline"
    mkdir -p "$track_dir"
    cd "$track_dir"

    log "[baseline] Starting code generation..."

    claude -p "$GOAL

Generate a complete, production-quality implementation with tests." \
        --append-system-prompt-file "$WORKSPACE/prompts/baseline_codegen.md" \
        --allowedTools "Read,Edit,Write,Bash" \
        --permission-mode bypassPermissions \
        --max-turns 30 \
        --output-format json \
        > "$track_dir/codegen_result.json" 2>"$track_dir/codegen_stderr.log" || {
        warn "[baseline] Code generation exited with non-zero status"
    }

    ok "[baseline] Code generation complete"

    # Run tests
    log "[baseline] Running tests..."
    if [[ -d "$track_dir/tests" ]]; then
        python3 -m pytest "$track_dir/tests/" -v --tb=short \
            > "$track_dir/test_results.txt" 2>&1 || true
        ok "[baseline] Tests finished (see test_results.txt)"
    else
        warn "[baseline] No tests/ directory found"
        echo "No tests directory found" > "$track_dir/test_results.txt"
    fi
}

# Run both tracks in parallel
log "Launching guided and baseline tracks in parallel..."

run_guided &
GUIDED_PID=$!

run_baseline &
BASELINE_PID=$!

# Wait for both tracks
GUIDED_EXIT=0
BASELINE_EXIT=0

wait $GUIDED_PID || GUIDED_EXIT=$?
wait $BASELINE_PID || BASELINE_EXIT=$?

if [[ $GUIDED_EXIT -ne 0 ]]; then
    warn "Guided track exited with status $GUIDED_EXIT"
fi
if [[ $BASELINE_EXIT -ne 0 ]]; then
    warn "Baseline track exited with status $BASELINE_EXIT"
fi

ok "Both tracks complete"

# ============================================================
# Step 5: Automated scoring
# ============================================================

log "Running automated scorer..."

# Copy kpis.json if it exists in RUN_DIR
if [[ -f "$RUN_DIR/kpis.json" ]]; then
    cp "$RUN_DIR/kpis.json" "$WORKSPACE/kpis.json"
    log "Copied kpis.json to workspace"
fi

python3 "$SCRIPT_DIR/score.py" \
    "$WORKSPACE/guided" \
    "$WORKSPACE/baseline" \
    "$WORKSPACE/verification_context.md" \
    --kpis "$RUN_DIR/kpis.json" \
    -o "$WORKSPACE/scores.json"

ok "Scoring complete"

# ============================================================
# Step 6: LLM comparison (optional)
# ============================================================

log "Running LLM comparison judge..."

# Build a single concatenated source file per track so the judge doesn't
# need dozens of Read calls (which caused hangs on large codebases).
for track in guided baseline; do
    {
        echo "=== $track track ==="
        find "$WORKSPACE/$track" -name '*.py' \
            -not -path '*/.venv/*' -not -path '*__pycache__*' \
            -print0 | sort -z | while IFS= read -r -d '' src; do
            relpath="${src#$WORKSPACE/}"
            echo ""
            echo "--- FILE: $relpath ---"
            cat "$src"
        done
    } > "$WORKSPACE/${track}_source_bundle.txt"
done

# Combine into a single input and pipe via stdin (avoids arg-list-too-long)
cat "$WORKSPACE/guided_source_bundle.txt" > "$WORKSPACE/comparison_input.txt"
printf '\n---\n\n' >> "$WORKSPACE/comparison_input.txt"
cat "$WORKSPACE/baseline_source_bundle.txt" >> "$WORKSPACE/comparison_input.txt"
printf '\n---\n\nAbove are the full source files for both the guided and baseline implementations. Compare them.\n' >> "$WORKSPACE/comparison_input.txt"

cat "$WORKSPACE/comparison_input.txt" | claude -p - \
    --append-system-prompt-file "$WORKSPACE/prompts/compare.md" \
    --allowedTools "Read" \
    --max-turns 5 \
    --output-format json \
    > "$WORKSPACE/comparison_result.json" 2>"$WORKSPACE/comparison_stderr.log" || {
    warn "LLM comparison exited with non-zero status"
}

# Extract the result text from JSON output
if [[ -f "$WORKSPACE/comparison_result.json" ]] && [[ -s "$WORKSPACE/comparison_result.json" ]]; then
    python3 -c "
import json, sys
try:
    data = json.load(open('$WORKSPACE/comparison_result.json'))
    text = data.get('result', data.get('content', str(data)))
    if isinstance(text, list):
        text = '\n'.join(b.get('text', '') for b in text if b.get('type') == 'text')
    print(text)
except Exception as e:
    print(f'Failed to extract comparison result: {e}', file=sys.stderr)
    sys.exit(0)
" > "$WORKSPACE/comparison_report.md" 2>/dev/null || {
    warn "Could not extract comparison report from JSON"
    cp "$WORKSPACE/comparison_result.json" "$WORKSPACE/comparison_report.md"
}
    ok "Comparison report generated"
else
    warn "Comparison result is empty — skipping report extraction"
fi

# ============================================================
# Step 7: Print summary
# ============================================================

echo ""
echo "============================================================"
echo "  Pipeline Complete"
echo "============================================================"
echo ""
echo "  Workspace:          $WORKSPACE"
echo "  Guided track:       $WORKSPACE/guided/"
echo "  Baseline track:     $WORKSPACE/baseline/"
echo "  Verification ctx:   $WORKSPACE/verification_context.md"
echo "  Scores:             $WORKSPACE/scores.json"
echo "  Comparison report:  $WORKSPACE/comparison_report.md"
echo ""

# Print score summary if scores.json exists
if [[ -f "$WORKSPACE/scores.json" ]]; then
    echo "--- Score Summary ---"
    python3 -c "
import json
scores = json.load(open('$WORKSPACE/scores.json'))

print(f\"{'Dimension':<30} {'Weight':>6} {'Guided':>8} {'Baseline':>8}\")
print('-' * 56)

for dim in scores.get('dimensions', []):
    name = dim['name']
    weight = f\"{dim['weight']}%\"
    g = dim.get('guided_score', 0)
    b = dim.get('baseline_score', 0)
    print(f'{name:<30} {weight:>6} {g:>8.1f} {b:>8.1f}')

print('-' * 56)
g_total = scores.get('guided_total', 0)
b_total = scores.get('baseline_total', 0)
print(f\"{'Weighted Total':<30} {'':>6} {g_total:>8.2f} {b_total:>8.2f}\")
print()
print(f\"Verdict: {scores.get('verdict', 'UNKNOWN')}\")
" 2>/dev/null || warn "Could not print score summary"
fi

# ============================================================
# Step 8: Calculate token usage and costs
# ============================================================

log "Calculating token usage and costs..."

python3 "$SCRIPT_DIR/calculate_costs.py" "$WORKSPACE" -o "$WORKSPACE/cost_breakdown.json" || {
    warn "Could not calculate costs (JSON outputs may be incomplete)"
}

echo ""
ok "Done."
