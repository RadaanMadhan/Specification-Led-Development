#!/usr/bin/env bash
#
# run_opus47_quality_survey.command — full M-best quality survey.
#
# Now that SSE streaming is in providers/anthropic.py, Opus 4.7 +
# adaptive thinking is viable as M-best. This script:
#
#   1. Pre-flight: run M-best on the banking baseline
#      (`../speckit-trial/specs/002-bank-transfer-audit/`). Expect
#      ≥20/26 PASS. If the pre-flight fails, the streaming code path
#      is broken or Opus 4.7 is producing worse Alloy than 4.6 on
#      banking — STOP and report.
#
#   2. Per-cell survey: 1 lift each on the 9 pinned eval cells
#      (A-L1/L2/L3, B-L1/L2/L3, C-L1/L2/L3). Records:
#         - elapsed seconds
#         - Alloy parse PASS/FAIL
#         - count of assertions if parse OK
#         - count of PASS vs total verdicts
#         - cost (USD)
#
#   3. Summary: per-cell pass rate. Use this to decide whether to
#      commit Opus 4.7 + adaptive (streaming) as M-best for Stage 1.
#
# Expected wall clock: 10 lifts × ~10 min = ~100 min worst case.
# Expected cost: 10 × $0.5–$1 = $5–$10 (Opus 4.7 with adaptive).

set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

LOG_DIR="$ROOT/runs/_opus47_survey"
rm -rf "$LOG_DIR"
mkdir -p "$LOG_DIR"
DONE_MARKER="$LOG_DIR/SURVEY_DONE"
rm -f "$DONE_MARKER"

# Kill any hung verify-design from prior iterations.
pkill -f "speceval.cli verify-design" 2>/dev/null && echo "[setup] killed prior verify-design" || true

echo "================================================================"
echo "  spec-led-eval — Opus 4.7 + streaming quality survey"
echo "  step 1: pre-flight on banking baseline"
echo "  step 2: 9-cell survey (one lift each)"
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
    "$HOME/anaconda3/bin/python3"; do
  if [ -n "$CANDIDATE" ] && [ -x "$CANDIDATE" ]; then PYBIN="$CANDIDATE"; break; fi
done
"$PYBIN" -m pip install --quiet jdk4py 2>/dev/null || true
JDK4PY="$("$PYBIN" -c 'import jdk4py; print(jdk4py.JAVA)')"
echo "python  : $PYBIN"
echo "java    : $JDK4PY"
echo

run_one () {
  local LABEL="$1"; shift
  local FEATURE_DIR="$1"; shift
  local LOG="$LOG_DIR/${LABEL}.log"
  local OUT_DIR="$LOG_DIR/${LABEL}_run"
  rm -rf "$ROOT/runs/$(basename "$FEATURE_DIR")"
  echo
  echo "----------------------------------------------------------------"
  echo "  >>> $LABEL  ($FEATURE_DIR)"
  echo "----------------------------------------------------------------"
  "$PYBIN" -m speceval.cli verify-design --no-cache --model M-best \
      --java-bin "$JDK4PY" "$FEATURE_DIR" 2>&1 | tee "$LOG"
  local RC=${PIPESTATUS[0]}
  # Move the produced runs/<feature-id>/ aside.
  local FEAT_ID
  FEAT_ID="$(basename "$FEATURE_DIR")"
  if [ -d "$ROOT/runs/$FEAT_ID" ]; then
    mv "$ROOT/runs/$FEAT_ID" "$OUT_DIR"
  fi
  return $RC
}

# ----------------------------------------------------------------
# Step 1: banking pre-flight
# ----------------------------------------------------------------
BANKING_DIR="$ROOT/../speckit-trial/specs/002-bank-transfer-audit"
if [ ! -d "$BANKING_DIR" ]; then
  echo "ERROR: banking feature folder not found at $BANKING_DIR"
  echo "FAIL: no-banking" > "$DONE_MARKER"
  exit 1
fi

run_one "00_banking_preflight" "$BANKING_DIR" || true

# Inspect: is banking output reasonable?
PREFLIGHT_DIR="$LOG_DIR/00_banking_preflight_run"
if [ ! -f "$PREFLIGHT_DIR/alloy_verdicts.json" ]; then
  echo
  echo "!!! Pre-flight FAILED: banking did not produce alloy_verdicts.json"
  echo "    Streaming code path or Opus 4.7 output is broken — STOP."
  echo "FAIL: preflight-no-verdicts" > "$DONE_MARKER"
  exit 1
fi

# Count PASS vs total
PREFLIGHT_PASS=$("$PYBIN" -c "
import json, sys
v = json.loads(open('$PREFLIGHT_DIR/alloy_verdicts.json').read())
print(sum(1 for x in v.values() if x == 'PASS'), len(v))
")
echo
echo "================================================================"
echo "  Pre-flight banking result: $PREFLIGHT_PASS  (expected ≥20/26)"
echo "================================================================"
echo

# ----------------------------------------------------------------
# Step 2: 9-cell survey
# ----------------------------------------------------------------
for CELL in A-L1 A-L2 A-L3 B-L1 B-L2 B-L3 C-L1 C-L2 C-L3; do
  run_one "$CELL" "$ROOT/eval/specs/$CELL" || true
done

# ----------------------------------------------------------------
# Step 3: summary
# ----------------------------------------------------------------
echo
echo "================================================================"
echo "  Quality survey summary"
echo "================================================================"
"$PYBIN" - <<PY
import json
from pathlib import Path
log_dir = Path("$LOG_DIR")
rows = []
def summarise(label, rdir):
    verdicts = rdir / "alloy_verdicts.json"
    cost     = rdir / "cost_log.json"
    cost_data = json.loads(cost.read_text()) if cost.exists() else {}
    elapsed = cost_data.get("elapsed_seconds", 0)
    usd     = cost_data.get("cost_usd", 0)
    if verdicts.exists():
        v = json.loads(verdicts.read_text())
        n_pass = sum(1 for x in v.values() if x == "PASS")
        n_tot  = len(v)
        return (label, "PARSE_OK", f"{n_pass}/{n_tot}", f"{elapsed:.0f}s", f"\${usd:.3f}")
    else:
        return (label, "PARSE_FAIL", "-", f"{elapsed:.0f}s", f"\${usd:.3f}")

# Banking first
banking_dir = log_dir / "00_banking_preflight_run"
if banking_dir.exists():
    rows.append(summarise("banking (preflight)", banking_dir))

for cell in ["A-L1","A-L2","A-L3","B-L1","B-L2","B-L3","C-L1","C-L2","C-L3"]:
    rdir = log_dir / f"{cell}_run"
    if rdir.exists():
        rows.append(summarise(cell, rdir))

print(f"  {'cell':22s}  {'parse':12s}  {'pass/total':10s}  {'wall':8s}  cost")
print("  " + "-"*70)
total_pass = total_total = 0
parse_ok = parse_fail = 0
for label, parse, pt, wall, cost in rows:
    print(f"  {label:22s}  {parse:12s}  {pt:10s}  {wall:8s}  {cost}")
    if parse == "PARSE_OK":
        parse_ok += 1
        if "/" in pt:
            p, t = pt.split("/")
            total_pass += int(p); total_total += int(t)
    else:
        parse_fail += 1
print("  " + "-"*70)
print(f"  parse_ok={parse_ok}, parse_fail={parse_fail}, aggregate PASS={total_pass}/{total_total}")
PY

echo "done" > "$DONE_MARKER"
echo
echo "Done. You can close this window."
