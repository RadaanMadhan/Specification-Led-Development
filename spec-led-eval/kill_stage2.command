#!/usr/bin/env bash
# kill_stage2.command — abort the Stage 2-A sanity check sweep.
#
# Stops, in order: run_experiment.py harness, verify-design subprocess,
# and the wrapper bash script. caffeinate is wired with `-w $$` so it
# exits automatically once the wrapper exits.
set -uo pipefail

pkill -f "eval/run_experiment.py"             2>/dev/null && echo "killed run_experiment.py"   || echo "no run_experiment.py"
pkill -f "speceval.cli verify-design"         2>/dev/null && echo "killed verify-design"       || echo "no verify-design"
pkill -f "run_stage2_sanity_check.command"    2>/dev/null && echo "killed sanity-check wrapper" || echo "no sanity-check wrapper"
pkill -f "run_stage1_sweep.command"           2>/dev/null && echo "killed stage1 wrapper"      || echo "no stage1 wrapper"

echo "Done. You can close this window."
