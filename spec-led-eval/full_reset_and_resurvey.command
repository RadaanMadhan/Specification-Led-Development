#!/usr/bin/env bash
# Aggressive cleanup + re-run the Opus 4.7 quality survey with the
# fixed lifter prompt (the `one sig PermMatrix { Allowed: set Role ->
# OperationKind }` example added 2026-05-18). Kills any prior surveys
# or python processes, wipes the survey log dir, then launches a fresh
# survey in this Terminal.

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "=== Aggressive cleanup ==="
pkill -f "speceval.cli verify-design" 2>/dev/null && echo "killed verify-design" || true
pkill -f "run_opus47_quality_survey" 2>/dev/null && echo "killed prior survey shell" || true
pkill -f "test_m_best_variants" 2>/dev/null || true
pkill -f "run_e0b_sanity_check" 2>/dev/null || true
sleep 2
# Second pass for stragglers
pkill -9 -f "speceval.cli verify-design" 2>/dev/null && echo "force-killed verify-design" || true
pkill -9 -f "run_opus47_quality_survey" 2>/dev/null || true

rm -rf "$ROOT/runs/_opus47_survey"
rm -rf "$ROOT/runs/A-L1" "$ROOT/runs/A-L2" "$ROOT/runs/A-L3"
rm -rf "$ROOT/runs/B-L1" "$ROOT/runs/B-L2" "$ROOT/runs/B-L3"
rm -rf "$ROOT/runs/C-L1" "$ROOT/runs/C-L2" "$ROOT/runs/C-L3"
rm -rf "$ROOT/runs/002-bank-transfer-audit"

echo "=== Cleanup done ==="
sleep 1

# Now invoke the real survey
exec "$ROOT/run_opus47_quality_survey.command"
