#!/usr/bin/env bash
#
# bootstrap.sh — one-shot setup + demo for spec-led-eval.
#
# What it does:
#   1. Verifies Java 11+ and Python 3.10+ are present
#   2. Downloads the Alloy Analyzer jar to tools/alloy.jar (if missing)
#   3. Installs the Python package in the active environment (pip install -e .)
#   4. Runs the parser smoke tests
#   5. Runs `speceval verify-alloy` on the bundled tiny snapshots
#   6. Runs `speceval check` on ../speckit-trial/specs/001-pomo-cli/spec.md
#
# Run from the spec-led-eval directory:
#   $ bash bootstrap.sh
#
# Re-running is safe: the script skips steps that have already been done.

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 1. Environment
# ---------------------------------------------------------------------------
step "1/6  Environment check"

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

# ---------------------------------------------------------------------------
# 2. Alloy jar
# ---------------------------------------------------------------------------
step "2/6  Alloy Analyzer jar"

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

# ---------------------------------------------------------------------------
# 3. Python package
# ---------------------------------------------------------------------------
step "3/6  Install Python package (editable)"

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

# ---------------------------------------------------------------------------
# 4. Parser smoke tests
# ---------------------------------------------------------------------------
step "4/6  Parser smoke tests"

if PYTHONPATH="$ROOT:${PYTHONPATH:-}" python3 tests/test_parser.py; then
  ok "parser smoke tests passed"
else
  fail "parser smoke tests failed"
fi

# ---------------------------------------------------------------------------
# 5. Verify Alloy with bundled snapshots
# ---------------------------------------------------------------------------
step "5/6  Verify Alloy on bundled snapshots"

speceval_run verify-alloy

# ---------------------------------------------------------------------------
# 6. End-to-end demo on the Pomodoro spec
# ---------------------------------------------------------------------------
step "6/6  Run end-to-end on 001-pomo-cli/spec.md"

POMODORO_SPEC="$ROOT/../speckit-trial/specs/001-pomo-cli/spec.md"

if [ ! -f "$POMODORO_SPEC" ]; then
  warn "Pomodoro spec not found at $POMODORO_SPEC"
  warn "skipping end-to-end demo — pass a spec.md path to:"
  warn "  speceval check <path-to-spec.md>"
else
  # Use the offline hardcoded lifter for the bootstrap so it works without
  # an internet connection or API key. The LLM lifter is the default for
  # interactive `speceval check` runs once setup is done.
  speceval_run check --hardcoded --no-review "$POMODORO_SPEC"
fi

step "Done"
ok "spec-led-eval is ready."
echo
echo "  Next steps (LLM-driven, generic):"
if [ -f "$ROOT/.env" ] && grep -q "ANTHROPIC_API_KEY=sk-" "$ROOT/.env" 2>/dev/null; then
  echo "    speceval check <path-to-any-speckit-spec.md>"
  echo "    (uses Claude Opus to lift the spec; will pause for human review)"
else
  echo "    Set ANTHROPIC_API_KEY in .env to enable the LLM lifter."
  echo "    Then: speceval check <path-to-any-speckit-spec.md>"
fi
echo "    speceval lift  <path-to-any-speckit-spec.md>   # show the lifted .als"
echo "    speceval verify-alloy                          # ground-truth tiny snapshots"
