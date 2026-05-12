#!/usr/bin/env bash
#
# run_unified_banking.command — end-to-end unified-verify on the banking spec.
#
# Runs BOTH halves of the integrated MVP from Leon's Mac:
#   1. Alloy structural verification (uses ANTHROPIC_API_KEY via .env)
#   2. WAF-derived KPI targets       (uses OPENAI_API_KEY via ../kpi-agent/.env)
#
# The unified report is written to:
#   runs/002-bank-transfer-audit/unified_report.md
#   runs/002-bank-transfer-audit/unified_report.txt
#
# Re-running is safe: both halves have their own caches inside their copied
# folders (Alloy: cache/lifts_design/<sha>.json; KPI: waf_embeddings_cache.json).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

SPEC_DIR="$ROOT/../../speckit-trial/specs/002-bank-transfer-audit"

echo "================================================================"
echo "  unified-verify — end-to-end (Mac runner)"
echo "  feature   : 002-bank-transfer-audit"
echo "  cwd       : $ROOT"
echo "  spec_dir  : $SPEC_DIR"
echo "================================================================"
echo

if [ ! -f .env ]; then
  echo "ERROR: $ROOT/.env not found (need ANTHROPIC_API_KEY)."
  read -n1 -p "Press any key to close..."
  exit 1
fi

if [ ! -f ../kpi-agent/.env ]; then
  echo "ERROR: ../kpi-agent/.env not found (need OPENAI_API_KEY)."
  read -n1 -p "Press any key to close..."
  exit 1
fi

# Pick the Python interpreter — prefer the one that has the dependencies installed.
PY=python3
if command -v python3.11 &>/dev/null; then
  PY=python3.11
elif command -v python3.12 &>/dev/null; then
  PY=python3.12
fi
echo "[setup]   Using $($PY --version 2>&1) at $(command -v $PY)"

# Ensure required runtime deps are present (silently install only if missing).
$PY -c "import click, requests" 2>/dev/null || {
  echo "[setup]   Installing click + requests..."
  $PY -m pip install --quiet --user click requests
}

# Ensure jdk4py for Alloy (bundles Java 25 — Alloy 6.2 needs Java 17+).
if ! $PY -c "import jdk4py" 2>/dev/null; then
  echo "[setup]   Installing jdk4py for the bundled Java runtime..."
  $PY -m pip install --quiet --user jdk4py
fi
JAVA_BIN=$($PY -c "import jdk4py; from pathlib import Path; print(Path(jdk4py.__file__).parent / 'java-runtime/bin/java')")
echo "[setup]   Java binary at: $JAVA_BIN"
echo

echo "================================================================"
echo "  Running unified-verify ..."
echo "================================================================"
echo

$PY -m speceval.cli unified-verify \
    --java-bin "$JAVA_BIN" \
    "$SPEC_DIR"

EXIT=$?
echo
echo "================================================================"
if [ "$EXIT" -eq 0 ]; then
  echo "  DONE — exit 0."
  echo "  Reports written to:"
  echo "    $ROOT/runs/002-bank-transfer-audit/unified_report.md"
  echo "    $ROOT/runs/002-bank-transfer-audit/unified_report.txt"
else
  echo "  FAILED — exit $EXIT."
fi
echo "================================================================"

read -n1 -p "Press any key to close..." || true
echo
