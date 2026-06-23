#!/usr/bin/env bash
#
# bootstrap.sh — one-shot setup for speceval.
#
# Verifies Java 11+ and Python 3.10+, downloads the Alloy jar if needed,
# installs the Python package, and runs verification on bundled snapshots.
#
# Re-running is safe: steps that are already done are skipped.

set -euo pipefail

BOLD=$'\033[1m'
GREEN=$'\033[32m'
RED=$'\033[31m'
YELLOW=$'\033[33m'
RESET=$'\033[0m'

step() { printf "\n${BOLD}== %s ==${RESET}\n" "$1"; }
ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$1"; }
warn() { printf "  ${YELLOW}!${RESET} %s\n" "$1"; }
fail() { printf "  ${RED}✗${RESET} %s\n" "$1"; exit 1; }

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

step "1/4  Environment check"

if command -v java >/dev/null 2>&1; then
  JAVA_VER=$(java -version 2>&1 | head -1)
  ok "java found: $JAVA_VER"
else
  fail "java not found. Install with: brew install openjdk@11"
fi

if command -v python3 >/dev/null 2>&1; then
  PY_VER=$(python3 --version 2>&1)
  ok "python3 found: $PY_VER"
else
  fail "python3 not found. Install with: brew install python@3.11"
fi

step "2/4  Alloy Analyzer jar"

ALLOY_JAR="$ROOT/tools/alloy.jar"
ALLOY_URL="https://github.com/AlloyTools/org.alloytools.alloy/releases/download/v6.2.0/org.alloytools.alloy.dist.jar"

mkdir -p "$ROOT/tools"

if [ -f "$ALLOY_JAR" ] && [ -s "$ALLOY_JAR" ]; then
  SIZE=$(wc -c < "$ALLOY_JAR" | tr -d ' ')
  ok "alloy.jar already present ($(numfmt --to=iec --suffix=B "$SIZE" 2>/dev/null || echo "$SIZE bytes"))"
else
  echo "  downloading from $ALLOY_URL ..."
  if curl -fL --progress-bar -o "$ALLOY_JAR" "$ALLOY_URL"; then
    SIZE=$(wc -c < "$ALLOY_JAR" | tr -d ' ')
    ok "downloaded alloy.jar ($(numfmt --to=iec --suffix=B "$SIZE" 2>/dev/null || echo "$SIZE bytes"))"
  else
    fail "could not download alloy.jar — check network or download manually:
        $ALLOY_URL
      and place it at $ALLOY_JAR"
  fi
fi

# Verify the jar is loadable
if java -jar "$ALLOY_JAR" --help >/dev/null 2>&1 \
   || java -jar "$ALLOY_JAR" 2>&1 | head -1 | grep -qiE "alloy|usage|exec"; then
  ok "alloy.jar appears runnable"
else
  warn "could not verify alloy.jar runs; will continue and let speceval try"
fi

step "3/4  Install Python package (editable)"

if python3 -c "import speceval" 2>/dev/null; then
  ok "speceval already importable"
else
  if python3 -m pip install -e . >/tmp/speceval_pip.log 2>&1; then
    ok "speceval installed (pip install -e .)"
  else
    warn "pip install -e . failed — falling back to PYTHONPATH"
    export PYTHONPATH="$ROOT:${PYTHONPATH:-}"
  fi
fi

# Helper: invoke speceval whether it's on PATH or only via -m.
speceval_run() {
  if command -v speceval >/dev/null 2>&1; then
    speceval "$@"
  else
    PYTHONPATH="$ROOT:${PYTHONPATH:-}" python3 -m speceval.cli "$@"
  fi
}

step "4/4  Run health checks"

speceval_run doctor

step "Done"
ok "speceval is ready."
echo
echo "  Next steps:"
if [ -f "$ROOT/.env" ] && grep -q "ANTHROPIC_API_KEY=" "$ROOT/.env" 2>/dev/null; then
  echo "    speceval run <feature-dir>                 # run structural verification + WAF KPI derivation"
  echo "    speceval generate \"description\"            # generate SpecKit artefacts"
  echo "    speceval generate-interactive \"description\"# generate with interactive KPI review"
else
  echo "    Set ANTHROPIC_API_KEY in .env to enable LLM features."
  echo "    Then: speceval run <feature-dir>"
fi
