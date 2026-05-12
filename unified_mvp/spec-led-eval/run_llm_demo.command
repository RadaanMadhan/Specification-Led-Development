#!/usr/bin/env bash
#
# run_llm_demo.command — run the LLM-driven check on the Pomodoro spec.
# Double-click from Finder or run from terminal.

set -e
cd "$(dirname "$0")"

if [ ! -f .env ]; then
  echo "ERROR: .env not found. Copy .env.example to .env and set ANTHROPIC_API_KEY."
  read -n 1
  exit 1
fi

POMODORO_SPEC="../speckit-trial/specs/001-pomo-cli/spec.md"

# --no-review for autonomous run; remove it for an interactive review prompt.
if command -v speceval >/dev/null 2>&1; then
  speceval check --no-review "$POMODORO_SPEC"
else
  PYTHONPATH="$(pwd)" python3 -m speceval.cli check --no-review "$POMODORO_SPEC"
fi

echo
echo "Press any key to close."
read -n 1
