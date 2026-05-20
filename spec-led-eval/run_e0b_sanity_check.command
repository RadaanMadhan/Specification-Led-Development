#!/usr/bin/env bash
#
# run_e0b_sanity_check.command — E0b live sanity check on A-L2.
#
# Runs three verify-design invocations (M-small, M-best, M-mid) against
# eval/specs/A-L2/ to validate the new tier-aware request bodies. Writes
# per-tier outputs to runs/_e0b_sanity_check/<tier>_run/ and a
# SANITY_CHECK_DONE marker file when finished so the sandbox can poll for
# completion.
#
# Per MODEL_SELECTION.md §5: if any of the four pass conditions fails on
# M-small, drop M-small from the design — do NOT silently substitute.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

LOG_DIR="$ROOT/runs/_e0b_sanity_check"
mkdir -p "$LOG_DIR"
DONE_MARKER="$LOG_DIR/SANITY_CHECK_DONE"
# Clear stale marker upfront so the sandbox can detect a fresh run.
rm -f "$DONE_MARKER"

echo "================================================================"
echo "  spec-led-eval — E0b live sanity check (Mac runner)"
echo "  cell    : eval/specs/A-L2"
echo "  tiers   : M-small, M-best, M-mid"
echo "  cwd     : $ROOT"
echo "  log dir : $LOG_DIR"
echo "================================================================"
echo

if [ ! -f .env ]; then
  echo "ERROR: .env not found. Cannot resolve ANTHROPIC_API_KEY."
  echo "FAIL: setup-no-env" > "$DONE_MARKER"
  read -n1 -r -p "Press any key to close..."
  exit 1
fi

# .command files launched from Finder open a fresh login shell where
# conda is NOT auto-activated. Source ~/.zshrc (or ~/.bashrc) so the
# user's normal shell init runs, then activate conda base if available.
# Don't fail the whole script if these steps fail — we'll fall back to
# probing candidate Pythons below.
if [ -f "$HOME/.zshrc" ]; then
  # shellcheck source=/dev/null
  source "$HOME/.zshrc" 2>/dev/null || true
fi
if command -v conda >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  eval "$(conda shell.bash hook 2>/dev/null)" || true
  conda activate base 2>/dev/null || true
fi

# Find a working python3. Prefer the conda-active python (now on PATH
# after sourcing ~/.zshrc + conda activate base above); fall back to
# common Anaconda/Miniconda paths, then the system python3.
PYBIN=""
for CANDIDATE in \
    "$(command -v python3 2>/dev/null || true)" \
    "$HOME/anaconda3/bin/python3" \
    "$HOME/miniconda3/bin/python3" \
    "$HOME/opt/anaconda3/bin/python3" \
    "/opt/anaconda3/bin/python3" \
    "/usr/local/bin/python3" \
    "/usr/bin/python3"; do
  if [ -n "$CANDIDATE" ] && [ -x "$CANDIDATE" ]; then
    PYBIN="$CANDIDATE"
    break
  fi
done

if [ -z "$PYBIN" ]; then
  echo "ERROR: no python3 found on PATH or in standard locations."
  echo "FAIL: no-python" > "$DONE_MARKER"
  read -n1 -r -p "Press any key to close..."
  exit 1
fi

# Auto-install jdk4py if missing — it's a small wheel that bundles a
# pinned Java 25 runtime (Alloy 6.2 needs Java 17+). Leon's setup is
# conda base, where pip installs are allowed.
if ! "$PYBIN" -c 'import jdk4py' 2>/dev/null; then
  echo "[setup] jdk4py not importable; installing into $PYBIN..."
  "$PYBIN" -m pip install --quiet jdk4py || {
    echo "ERROR: pip install jdk4py failed."
    echo "FAIL: jdk4py-install" > "$DONE_MARKER"
    read -n1 -r -p "Press any key to close..."
    exit 1
  }
  if ! "$PYBIN" -c 'import jdk4py' 2>/dev/null; then
    echo "ERROR: jdk4py still not importable after install."
    echo "FAIL: jdk4py-still-missing" > "$DONE_MARKER"
    read -n1 -r -p "Press any key to close..."
    exit 1
  fi
fi

JDK4PY="$($PYBIN -c 'import jdk4py; print(jdk4py.JAVA)')"
echo "python  : $PYBIN"
echo "java    : $JDK4PY"
echo "version : $($PYBIN --version 2>&1)"
echo

# Kill any prior hung verify-design lift before starting fresh runs.
pkill -f "speceval.cli verify-design" 2>/dev/null && echo "[setup] killed hung verify-design process" || true

# Wipe stale outputs from runs/A-L2/ so each invocation is observed cleanly.
rm -rf "$ROOT/runs/A-L2"

OVERALL=PASS
for TIER in M-small M-best M-mid; do
  echo "----------------------------------------------------------------"
  echo "  >>> Tier: $TIER"
  echo "----------------------------------------------------------------"
  TIER_LOG="$LOG_DIR/${TIER}.log"
  "$PYBIN" -m speceval.cli verify-design --no-cache --model "$TIER" \
      --java-bin "$JDK4PY" eval/specs/A-L2/ 2>&1 | tee "$TIER_LOG"
  RC=${PIPESTATUS[0]}

  TIER_RUN_DIR="$ROOT/runs/A-L2"
  if [ -d "$TIER_RUN_DIR" ]; then
    rm -rf "$LOG_DIR/${TIER}_run"
    mv "$TIER_RUN_DIR" "$LOG_DIR/${TIER}_run"
  fi

  if [ "$RC" -ne 0 ]; then
    echo
    echo "  !!! $TIER FAILED with exit code $RC"
    OVERALL=FAIL
  else
    echo
    echo "  *** $TIER completed (exit 0)"
  fi
  echo
done

echo "================================================================"
echo "  Sanity check overall: $OVERALL"
echo "  Per-tier artefacts under: $LOG_DIR/<tier>_run/"
echo "================================================================"

echo "$OVERALL" > "$DONE_MARKER"
echo
echo "Done. You can close this window."
