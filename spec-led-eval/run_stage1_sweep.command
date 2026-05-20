#!/usr/bin/env bash
#
# run_stage1_sweep.command — Stage 1 AQS sweep wrapper (Phase E2).
#
# Drives `eval/run_experiment.py` on Leon's Mac. The harness handles the
# actual orchestration (per-run logging, progress.json, resumability);
# this wrapper just resolves the right Python + jdk4py and forwards
# command-line args.
#
# Usage:
#   ./run_stage1_sweep.command                          # full 90-run sweep
#   ./run_stage1_sweep.command --cells A-L1 --reps 1    # single-run smoke test
#   ./run_stage1_sweep.command --cells A-L1,B-L2 --reps 3
#
# Safely re-runnable: the harness reads eval/runs/_progress.json on
# startup and skips every (cell, model, rep) that has a complete
# run_NN/ directory on disk. Interrupt with ^C any time — the latest
# run's progress entry is committed atomically after each run.
#
# Cost / wall-clock envelopes (M-best, per eval/MODEL_SELECTION.md §8.4):
#   - Single smoke run (--cells A-L1 --reps 1) : ~5 min, ~$1
#   - Full Stage 1 sweep (90 runs)             : ~15 hr, ~$90
#
# Sandbox cannot reach api.anthropic.com — Stage 1 must run on the Mac.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# ----------------------------------------------------------------
# Keep the Mac awake for the duration of the sweep.
#   -i  inhibit idle (system) sleep
#   -d  prevent display sleep
#   -w  wait for the wrapper's PID — caffeinate exits when this
#       script exits (clean exit OR Ctrl-C), no orphan process
#
# NOTE: closing the lid will still sleep the Mac unless an external
# display is connected with clamshell-mode set up. Leave the lid open.
# ----------------------------------------------------------------
caffeinate -i -d -w $$ &
CAFFEINATE_PID=$!
echo "[setup] caffeinate pid=$CAFFEINATE_PID — system sleep inhibited"

DONE_MARKER="$ROOT/eval/runs/STAGE1_DONE"
mkdir -p "$ROOT/eval/runs"
rm -f "$DONE_MARKER"

# ----------------------------------------------------------------
# Pre-flight checks
# ----------------------------------------------------------------
if [ ! -f .env ]; then
  echo "ERROR: .env not found. Copy .env.example and set ANTHROPIC_API_KEY."
  echo "FAIL: no-env" > "$DONE_MARKER"
  exit 1
fi

if [ ! -f eval/run_experiment.py ]; then
  echo "ERROR: eval/run_experiment.py not found. Are you in the right repo?"
  echo "FAIL: no-harness" > "$DONE_MARKER"
  exit 1
fi

# ----------------------------------------------------------------
# Resolve conda base + python + jdk4py
# ----------------------------------------------------------------
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
if [ -z "$PYBIN" ]; then
  echo "ERROR: no python3 found on PATH or in standard conda locations."
  echo "FAIL: no-python" > "$DONE_MARKER"
  exit 1
fi

# jdk4py vendors a Java 25 runtime — Alloy 6.2 needs Java 17+ and macOS
# ships 11 system-installed. Install if missing.
"$PYBIN" -m pip install --quiet jdk4py 2>/dev/null || true
JDK4PY="$("$PYBIN" -c 'import jdk4py; print(jdk4py.JAVA)')"
if [ -z "$JDK4PY" ] || [ ! -x "$JDK4PY" ]; then
  echo "ERROR: jdk4py JAVA executable not resolvable ('$JDK4PY')."
  echo "FAIL: no-jdk4py" > "$DONE_MARKER"
  exit 1
fi

echo "================================================================"
echo "  spec-led-eval — Stage 1 sweep (run_stage1_sweep.command)"
echo "================================================================"
echo "  python  : $PYBIN"
echo "  java    : $JDK4PY"
echo "  repo    : $ROOT"
echo "  args    : $*"
echo "  done    : $DONE_MARKER (created on success)"
echo "================================================================"
echo

# ----------------------------------------------------------------
# Kill any stale verify-design from a prior interrupted run.
# ----------------------------------------------------------------
pkill -f "speceval.cli verify-design" 2>/dev/null \
  && echo "[setup] killed stale verify-design from a prior run" \
  || true

# ----------------------------------------------------------------
# Run the harness. Pass through every command-line arg verbatim;
# pin --java-bin to jdk4py so Alloy works regardless of PATH.
# ----------------------------------------------------------------
"$PYBIN" eval/run_experiment.py \
    --java-bin "$JDK4PY" \
    --python-bin "$PYBIN" \
    "$@"
RC=$?

echo
echo "================================================================"
echo "  Stage 1 sweep wrapper finished — exit code $RC"
echo "================================================================"

if [ $RC -eq 0 ]; then
  echo "done at $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$DONE_MARKER"
  echo "OK. progress.json: $ROOT/eval/runs/_progress.json"
else
  echo "incomplete at $(date -u +%Y-%m-%dT%H:%M:%SZ) (rc=$RC)" > "$DONE_MARKER"
  echo "Some runs did not complete. Re-run this script to resume — the"
  echo "harness will skip every (cell, model, rep) that's already on disk."
fi

echo
echo "You can close this window."
exit $RC
