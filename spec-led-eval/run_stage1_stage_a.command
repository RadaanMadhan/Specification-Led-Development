#!/usr/bin/env bash
#
# run_stage1_stage_a.command — Stage A pre-flight for the Stage-1 sweep.
#
# Delegates to run_stage1_sweep.command with `--reps 1`. Validates that
# every cell (A-L1..C-L3) lifts and parses cleanly THROUGH THE HARNESS
# before we commit ~$80 + ~14 hr to the full Stage-1 sweep.
#
# Why this exists:
#   The E2 smoke test only validated A-L1 through run_experiment.py.
#   The remaining 8 cells were validated by the E0b survey (a different
#   .command). Stage A is the harness-level pre-flight that closes that
#   gap cheaply.
#
# Expected envelope:
#   - 9 cells × M-best × 1 rep = 9 runs (A-L1/run_01 already exists →
#     skipped via disk-resume → 8 new runs in practice).
#   - Wall clock: ~1 hour (~6-9 min mean per lift, range 3-22 min).
#   - Cost: ~$8 (~$0.90-$1.30 per lift).
#   - Marker: STAGE1_DONE written on completion.
#
# What to check after this finishes:
#   1. `eval/runs/STAGE1_DONE` contains `done at <UTC>` (success) vs
#      `incomplete at <UTC> (rc=N)` (some run failed).
#   2. `eval/runs/_progress.json` — `runs_done: 9`, `cells_done: 9`,
#      every cell A-L1..C-L3 has a `run_01` entry with status `ok`
#      (or `parse_fail` — D1=0 is valid data, not a blocker).
#   3. Each `eval/runs/<cell>/M-best/run_01/` has the six artefacts:
#      feature_model.als, feature_model.manifest.json,
#      alloy_verdicts.json, mutation_outcomes.json, cost_log.json,
#      report.txt. (PARSE_FAIL runs may be missing alloy_verdicts +
#      mutation_outcomes; that's expected.)
#
# Next step after Stage A passes:
#   ./run_stage1_sweep.command
#       (no args; resumes from disk, runs reps 2..10 for all 9 cells
#        = 81 new runs; ~14 hr; ~$81).

set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

exec "$ROOT/run_stage1_sweep.command" --reps 1
