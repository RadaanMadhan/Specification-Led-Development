#!/usr/bin/env bash
#
# run_design_lift.command — Phase-3 design-mode lift on Leon's Mac.
#
# The Cowork sandbox proxy blocks POST https://api.anthropic.com/v1/messages,
# so the LLM call has to run on the Mac. Double-click this file in Finder to
# perform the lift; the result is cached at
#    spec-led-eval/cache/lifts_design/<sha>.json
# which is on the shared filesystem the sandbox can read. The sandbox then
# completes the rest of the pipeline (Alloy, mutation tests, report).
#
# Re-running is safe: the cache is content-addressed, so a second double-click
# just confirms the cached payload is still up-to-date.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "================================================================"
echo "  spec-led-eval — Phase 3 design-mode lift (Mac runner)"
echo "  feature : 002-bank-transfer-audit"
echo "  cwd     : $ROOT"
echo "================================================================"
echo

if [ ! -f .env ]; then
  echo "ERROR: .env not found. Cannot resolve ANTHROPIC_API_KEY."
  read -n1 -p "Press any key to close..."
  exit 1
fi

PYTHONPATH="$ROOT" python3 - <<'PY'
import sys
from pathlib import Path

from speceval.lifter_design import (
    DesignLiftError,
    load_design_inputs,
    lift_design,
    write_feature_model,
)
from speceval.providers.anthropic import AnthropicProvider

feature_dir = Path("../speckit-trial/specs/002-bank-transfer-audit").resolve()
patterns_md = Path("patterns.md").resolve()
cache_dir   = Path("cache/lifts_design").resolve()
run_dir     = Path("runs/002-bank-transfer-audit").resolve()

print(f"  feature dir   : {feature_dir}")
print(f"  patterns.md   : {patterns_md}")
print(f"  cache dir     : {cache_dir}")

try:
    inputs = load_design_inputs(feature_dir, patterns_md_path=patterns_md)
except DesignLiftError as e:
    print(f"FATAL: {e}", file=sys.stderr)
    sys.exit(1)

try:
    provider = AnthropicProvider.from_env()
except RuntimeError as e:
    print(f"FATAL: {e}", file=sys.stderr)
    sys.exit(1)

print(f"  provider      : {provider.name}: {provider.model}")
print()
print("  Calling Claude Opus...")
print("  (this may take 30–90 seconds)")
print()

# Force a fresh lift so we know we hit the API; cache is still written
# afterward and the sandbox-side run will read it.
pkg = lift_design(
    inputs,
    provider=provider,
    cache_dir=cache_dir,
    use_cache=False,
)

print(f"  OK — sha={pkg.sha[:16]}  cache_hit={pkg.cache_hit}")
print(f"  feature_model.als length : {len(pkg.feature_model_als)} chars")
print(f"  patterns_applied         : {pkg.manifest.get('patterns_applied')}")
print(f"  fr_assertion_map keys    : "
      f"{list((pkg.manifest.get('fr_assertion_map') or {}).keys())}")
print(f"  mutation_targets         : "
      f"{[m.get('fact_name') for m in (pkg.manifest.get('mutation_targets') or [])]}")

als_path = write_feature_model(pkg, run_dir)
print()
print(f"  wrote {als_path}")
print(f"  wrote {(run_dir / 'feature_model.manifest.json')}")
print()
print("Lift complete. The sandbox can now run the rest of the pipeline.")
PY

echo
echo "================================================================"
echo "  Done. The cached lift now lives at:"
echo "    cache/lifts_design/<sha>.json"
echo "    runs/002-bank-transfer-audit/feature_model.als"
echo "================================================================"
echo
read -n1 -p "Press any key to close this window..."
echo
