#!/usr/bin/env bash
#
# test_m_best_variants.command — pick the strongest M-best config for E0b.
#
# Per Leon's 2026-05-18 decision: drop M-mid and M-small entirely;
# evaluate only with M-best (the strongest Anthropic config that
# actually returns clean Alloy on rich Speckit cells).
#
# Two M-best variants are tested on eval/specs/A-L2 (the canonical
# sanity-check cell):
#
#   V1  Opus 4.6, no thinking          — fast (~2 min), current default
#   V2  Opus 4.6, manual thinking 16k  — gives Opus extra reasoning budget
#
# Each variant runs 3 replicates with --no-cache. We report:
#   - elapsed seconds per run
#   - whether the produced .als parses under Alloy
#   - pass rate per variant
#
# Whichever variant produces ≥2/3 parseable .als wins.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

LOG_DIR="$ROOT/runs/_m_best_variants"
rm -rf "$LOG_DIR"
mkdir -p "$LOG_DIR"
DONE_MARKER="$LOG_DIR/VARIANTS_DONE"

# Kill any hung verify-design processes from prior runs (M-mid hang, etc.)
pkill -f "speceval.cli verify-design" 2>/dev/null && echo "[setup] killed prior verify-design" || true
pkill -f "test_m_best_variants" 2>/dev/null || true

echo "================================================================"
echo "  spec-led-eval — M-best variant comparison (A-L2)"
echo "  variants : V1 (no thinking), V2 (manual thinking budget=16384)"
echo "  reps     : 3 each"
echo "  cwd      : $ROOT"
echo "================================================================"
echo

if [ ! -f .env ]; then
  echo "ERROR: .env not found."; echo "FAIL: no-env" > "$DONE_MARKER"; exit 1
fi

if [ -f "$HOME/.zshrc" ]; then
  # shellcheck source=/dev/null
  source "$HOME/.zshrc" 2>/dev/null || true
fi
if command -v conda >/dev/null 2>&1; then
  eval "$(conda shell.bash hook 2>/dev/null)" || true
  conda activate base 2>/dev/null || true
fi

PYBIN=""
for CANDIDATE in \
    "$(command -v python3 2>/dev/null || true)" \
    "$HOME/opt/anaconda3/bin/python3" \
    "$HOME/anaconda3/bin/python3" \
    "/opt/anaconda3/bin/python3" \
    "/usr/local/bin/python3"; do
  if [ -n "$CANDIDATE" ] && [ -x "$CANDIDATE" ]; then PYBIN="$CANDIDATE"; break; fi
done
"$PYBIN" -m pip install --quiet jdk4py 2>/dev/null || true
JDK4PY="$($PYBIN -c 'import jdk4py; print(jdk4py.JAVA)')"
echo "python  : $PYBIN"
echo "java    : $JDK4PY"
echo

# We test variants by patching TIER_CONFIG via a tiny wrapper that
# imports the real lifter but overrides the request-body construction.
# Variant V1 = current TIER_CONFIG (no thinking). Variant V2 = same
# model + manual thinking 16k.

run_variant () {
  local NAME="$1"; shift
  local PATCH="$1"; shift
  local VARIANT_DIR="$LOG_DIR/$NAME"
  mkdir -p "$VARIANT_DIR"
  echo "================================================================"
  echo "  Variant: $NAME"
  echo "  Patch  : $PATCH"
  echo "================================================================"
  for REP in 1 2 3; do
    echo
    echo "  --- rep $REP/3 ---"
    REP_LOG="$VARIANT_DIR/rep${REP}.log"
    rm -rf "$ROOT/runs/A-L2"
    "$PYBIN" - <<PY 2>&1 | tee "$REP_LOG"
import sys, json, time
sys.path.insert(0, "$ROOT")

# Apply the variant patch BEFORE importing the CLI.
from speceval.providers import anthropic as A
$PATCH
print(f"[patch]  TIER_CONFIG['M-best'] = {A.TIER_CONFIG['M-best']}")

from click.testing import CliRunner
from speceval.cli import main

runner = CliRunner(mix_stderr=False)
result = runner.invoke(main, [
    "verify-design", "--no-cache", "--model", "M-best",
    "--java-bin", "$JDK4PY",
    "eval/specs/A-L2/",
])
print("--- cli stdout ---")
print(result.output)
if result.stderr_bytes:
    print("--- cli stderr ---")
    print(result.stderr)
print(f"[exit]   {result.exit_code}")
PY
    REP_DIR="$ROOT/runs/A-L2"
    if [ -d "$REP_DIR" ]; then
      mv "$REP_DIR" "$VARIANT_DIR/rep${REP}_run"
    fi
  done
}

# V1 — no thinking (current TIER_CONFIG, no patch needed)
run_variant "V1_no_thinking" \
"# no patch"

# V2 — manual thinking budget=16384
run_variant "V2_manual_thinking_16k" \
"A.TIER_CONFIG['M-best'] = {'model': 'claude-opus-4-6', 'thinking': {'type': 'enabled', 'budget_tokens': 16384}}"

# Summarise: count how many runs in each variant produced an alloy_verdicts.json
echo
echo "================================================================"
echo "  Summary"
echo "================================================================"
"$PYBIN" - <<PY
import json
from pathlib import Path
log_dir = Path("$LOG_DIR")
for variant in ["V1_no_thinking", "V2_manual_thinking_16k"]:
    vdir = log_dir / variant
    if not vdir.exists():
        print(f"  {variant}: not run")
        continue
    pass_count = 0
    total = 0
    for rep_dir in sorted(vdir.glob("rep*_run")):
        total += 1
        verdicts = rep_dir / "alloy_verdicts.json"
        cost     = rep_dir / "cost_log.json"
        ok_parse = verdicts.exists()
        cost_data = json.loads(cost.read_text()) if cost.exists() else {}
        elapsed = cost_data.get("elapsed_seconds", 0)
        if ok_parse:
            n_pass = sum(1 for v in json.loads(verdicts.read_text()).values() if v == "PASS")
            n_tot  = len(json.loads(verdicts.read_text()))
            print(f"  {variant} / {rep_dir.name}: PARSE_OK, {n_pass}/{n_tot} PASS, {elapsed:.1f}s, \${cost_data.get('cost_usd',0):.3f}")
            pass_count += 1
        else:
            print(f"  {variant} / {rep_dir.name}: PARSE_FAIL, {elapsed:.1f}s, \${cost_data.get('cost_usd',0):.3f}")
    print(f"  >>> {variant}: {pass_count}/{total} parseable .als")
PY

echo "done" > "$DONE_MARKER"
echo
echo "Done. You can close this window."
