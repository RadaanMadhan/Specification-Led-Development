#!/usr/bin/env bash
#
# run_stage2_sanity_check.command — Stage 2-A sanity check wrapper.
#
# Kicks off run_stage1_sweep.command with the sanity-check args
# hard-coded so it can be double-clicked from Finder (no Terminal
# typing required). Runs 9 cells × 2 models (M-mid, M-small) × 1
# replicate = 18 runs. Expected ~2 hr wall clock, ~$8 cost.
#
# New artefacts land at:
#   eval/runs/<cell>/M-mid/run_01/
#   eval/runs/<cell>/M-small/run_01/
#
# Stage 1 M-best data (eval/runs/<cell>/M-best/*) stays untouched —
# the harness's filesystem-resume skips any (cell, model, rep)
# triple whose run_NN/ already exists.
#
# Pass criteria (checked manually after completion):
#   - ≥5/9 PARSE_OK on each model
#   - No catastrophic prompt-misfollow pattern across cells
#
# Created 2026-05-19 for Stage 2 (model comparison) re-enablement.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

exec "$ROOT/run_stage1_sweep.command" --models M-mid,M-small --reps 1
