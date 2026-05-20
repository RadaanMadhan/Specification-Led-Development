#!/usr/bin/env bash
#
# run_stage1_smoke_test.command — single-cell smoke test for Phase E2.
#
# Delegates to run_stage1_sweep.command with `--cells A-L1 --reps 1`,
# i.e. one verify-design lift on the Banking-sparse cell against M-best.
# Expected runtime ~5 minutes, expected API cost ~$1.
#
# Used to validate the harness before the full 90-run Stage 1 sweep.
# Re-runnable: if eval/runs/A-L1/M-best/run_01/ already has the
# complete artefacts, the harness will skip without spending the $1.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

exec "$ROOT/run_stage1_sweep.command" --cells A-L1 --reps 1
