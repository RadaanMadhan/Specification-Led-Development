#!/usr/bin/env bash
#
# run_charlotte_banking.command — one-click run against the banking spec.
#
# Requires a .env file in the same folder containing:
#     OPENAI_API_KEY="sk-..."
# kpi_agent.py auto-loads .env on startup.

set -uo pipefail
cd "$(dirname "$0")"

BANKING_SPEC="/Users/leonhausmann/Imperial_College/teaching/term3/microsoft_spec_led_dev/testing/speckit_testing/speckit-trial/specs/002-bank-transfer-audit/spec.md"

echo
echo "=========================================================="
echo "  WAF-derived KPI pipeline — banking demo"
echo "  cwd          : $(pwd)"
echo "  banking spec : $BANKING_SPEC"
echo "=========================================================="
echo

if [ ! -f .env ]; then
  echo "ERROR: .env file not found in $(pwd)"
  echo "Create one containing:"
  echo "    OPENAI_API_KEY=\"sk-...\""
  echo
  read -n1 -p "Press any key to close..."
  exit 1
fi

if ! python3 -c "import requests" 2>/dev/null; then
  echo "Installing 'requests' (one-time)..."
  python3 -m pip install --quiet requests || {
    echo "ERROR: pip install requests failed."
    read -n1 -p "Press any key to close..."
    exit 1
  }
fi

python3 kpi_agent.py "$BANKING_SPEC"
RC=$?

echo
echo "=========================================================="
if [ $RC -eq 0 ]; then
  echo "  Done. Outputs in:"
  echo "    $(pwd)/gqm_output.json"
  echo "    $(pwd)/kpi_output.json"
else
  echo "  kpi_agent.py exited with code $RC. See errors above."
fi
echo "=========================================================="
echo
read -n1 -p "Press any key to close..."
echo
