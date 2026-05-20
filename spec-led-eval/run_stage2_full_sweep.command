#!/usr/bin/env bash
#
# run_stage2_full_sweep.command — Stage 2-C full model-comparison sweep.
#
# Kicks off run_stage1_sweep.command with --models M-mid,M-small and
# the default --reps 10. Total planned: 9 cells × 2 models × 10 reps
# = 180 runs.
#
# Filesystem resume skips every (cell, model, rep) that already
# exists on disk. After the Stage 2-A sanity check there are 12
# completed run_01 dirs on disk (9 M-mid + 3 M-small at budget=32768),
# so this wrapper actually adds:
#
#   - 9 M-mid runs × 9 missing reps = 81 new M-mid runs
#   - 9 M-small runs × ~7 missing reps = ~63 new M-small runs (varies
#     by which run_01s landed at 32k vs 16k)
#   - Plus the 6 cells whose M-small/run_01 was wiped during the 32k
#     experiment will re-run those run_01s first
#
# Net: ~162 new runs.
#
# Cost / wall-clock envelopes (per Stage 2-A sanity check):
#   - M-mid: ~$0.32/lift, ~3.5 min → 90 lifts ≈ $29, ~5 hr
#   - M-small: ~$0.10/lift, ~1.5 min → 90 lifts ≈ $9, ~2 hr
#   - Total: ~$38, ~7 hr wall clock
#
# Stage 1 M-best data (eval/runs/<cell>/M-best/*) is NEVER touched.
#
# Created 2026-05-19 for Stage 2 model comparison (H5/H6/H7).

set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

exec "$ROOT/run_stage1_sweep.command" --models M-mid,M-small
