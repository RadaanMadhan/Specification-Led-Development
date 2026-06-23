#!/usr/bin/env python3
"""Calculate token usage and costs from pipeline run outputs.

Extracts token counts from claude -p JSON outputs and computes costs
based on Claude pricing.

Usage:
    python pipeline/calculate_costs.py <workspace_dir>
"""

import argparse
import json
import sys
from pathlib import Path
from typing import Optional


# Claude pricing (as of 2024)
# https://www.anthropic.com/pricing
PRICING = {
    "claude-opus-4": {
        "input": 15.00 / 1_000_000,   # $15 per MTok
        "output": 75.00 / 1_000_000,  # $75 per MTok
    },
    "claude-sonnet-4": {
        "input": 3.00 / 1_000_000,    # $3 per MTok
        "output": 15.00 / 1_000_000,  # $15 per MTok
    },
    "claude-sonnet-3.5": {
        "input": 3.00 / 1_000_000,    # $3 per MTok
        "output": 15.00 / 1_000_000,  # $15 per MTok
    },
    "claude-haiku-3.5": {
        "input": 1.00 / 1_000_000,    # $1 per MTok
        "output": 5.00 / 1_000_000,   # $5 per MTok
    },
}


def extract_usage_from_json(json_path: Path) -> Optional[dict]:
    """Extract token usage from claude -p JSON output."""
    if not json_path.exists() or json_path.stat().st_size == 0:
        return None

    try:
        with open(json_path) as f:
            data = json.load(f)

        # Claude -p output format varies; try multiple paths
        usage = data.get("usage") or data.get("metadata", {}).get("usage")
        if not usage:
            return None

        return {
            "input_tokens": usage.get("input_tokens", 0),
            "output_tokens": usage.get("output_tokens", 0),
            "cache_creation_input_tokens": usage.get("cache_creation_input_tokens", 0),
            "cache_read_input_tokens": usage.get("cache_read_input_tokens", 0),
        }
    except (json.JSONDecodeError, KeyError, AttributeError):
        return None


def infer_model(usage: dict, default: str = "claude-sonnet-4") -> str:
    """Infer model from token counts (heuristic)."""
    # This is a heuristic; ideally the JSON would contain model info
    # For now, assume sonnet-4 (most common for code generation)
    return default


def calculate_cost(usage: dict, model: str) -> dict:
    """Calculate cost for a single usage record."""
    pricing = PRICING.get(model, PRICING["claude-sonnet-4"])

    input_cost = usage["input_tokens"] * pricing["input"]
    output_cost = usage["output_tokens"] * pricing["output"]

    # Cache tokens are cheaper (typically 10% of input price)
    cache_write_cost = usage.get("cache_creation_input_tokens", 0) * pricing["input"]
    cache_read_cost = usage.get("cache_read_input_tokens", 0) * (pricing["input"] * 0.1)

    total_cost = input_cost + output_cost + cache_write_cost + cache_read_cost

    return {
        "input_tokens": usage["input_tokens"],
        "output_tokens": usage["output_tokens"],
        "cache_creation_tokens": usage.get("cache_creation_input_tokens", 0),
        "cache_read_tokens": usage.get("cache_read_input_tokens", 0),
        "input_cost": input_cost,
        "output_cost": output_cost,
        "cache_write_cost": cache_write_cost,
        "cache_read_cost": cache_read_cost,
        "total_cost": total_cost,
        "model": model,
    }


def analyze_workspace(workspace: Path) -> dict:
    """Analyze token usage for a pipeline workspace."""
    results = {
        "guided_codegen": None,
        "guided_testgen": None,
        "baseline_codegen": None,
        "comparison": None,
    }

    # Guided track
    guided_codegen = workspace / "guided" / "codegen_result.json"
    if guided_codegen.exists():
        usage = extract_usage_from_json(guided_codegen)
        if usage:
            results["guided_codegen"] = calculate_cost(usage, "claude-sonnet-4")

    guided_testgen = workspace / "guided" / "testgen_result.json"
    if guided_testgen.exists():
        usage = extract_usage_from_json(guided_testgen)
        if usage:
            results["guided_testgen"] = calculate_cost(usage, "claude-sonnet-4")

    # Baseline track
    baseline_codegen = workspace / "baseline" / "codegen_result.json"
    if baseline_codegen.exists():
        usage = extract_usage_from_json(baseline_codegen)
        if usage:
            results["baseline_codegen"] = calculate_cost(usage, "claude-sonnet-4")

    # Comparison
    comparison = workspace / "comparison_result.json"
    if comparison.exists():
        usage = extract_usage_from_json(comparison)
        if usage:
            results["comparison"] = calculate_cost(usage, "claude-sonnet-4")

    return results


def print_breakdown(results: dict):
    """Print formatted cost breakdown."""
    print("\n" + "=" * 80)
    print("TOKEN USAGE & COST BREAKDOWN")
    print("=" * 80 + "\n")

    total_input = 0
    total_output = 0
    total_cost = 0.0

    for phase, data in results.items():
        if data is None:
            continue

        phase_name = phase.replace("_", " ").title()
        print(f"### {phase_name}")
        print(f"  Model: {data['model']}")
        print(f"  Input tokens:  {data['input_tokens']:>10,}")
        if data['cache_creation_tokens'] > 0:
            print(f"  Cache write:   {data['cache_creation_tokens']:>10,}")
        if data['cache_read_tokens'] > 0:
            print(f"  Cache read:    {data['cache_read_tokens']:>10,}")
        print(f"  Output tokens: {data['output_tokens']:>10,}")
        print(f"  Cost:          ${data['total_cost']:>10.4f}")
        print()

        total_input += data['input_tokens']
        total_output += data['output_tokens']
        total_cost += data['total_cost']

    print("-" * 80)
    print(f"TOTAL INPUT TOKENS:  {total_input:>10,}")
    print(f"TOTAL OUTPUT TOKENS: {total_output:>10,}")
    print(f"TOTAL COST:          ${total_cost:>10.4f}")
    print("=" * 80 + "\n")


def save_breakdown(results: dict, output_path: Path):
    """Save cost breakdown to JSON."""
    # Compute totals
    total_input = sum(d['input_tokens'] for d in results.values() if d)
    total_output = sum(d['output_tokens'] for d in results.values() if d)
    total_cost = sum(d['total_cost'] for d in results.values() if d)

    output = {
        "phases": results,
        "totals": {
            "input_tokens": total_input,
            "output_tokens": total_output,
            "total_cost": total_cost,
        }
    }

    with open(output_path, "w") as f:
        json.dump(output, f, indent=2)


def main():
    parser = argparse.ArgumentParser(
        description="Calculate token usage and costs from pipeline run"
    )
    parser.add_argument(
        "workspace",
        type=Path,
        help="Path to pipeline workspace directory (e.g., pipeline_runs/20260519-162520/)",
    )
    parser.add_argument(
        "-o", "--output",
        type=Path,
        default=None,
        help="Output path for cost_breakdown.json (default: <workspace>/cost_breakdown.json)",
    )
    args = parser.parse_args()

    workspace = args.workspace.resolve()
    if not workspace.is_dir():
        print(f"ERROR: {workspace} is not a directory", file=sys.stderr)
        sys.exit(1)

    results = analyze_workspace(workspace)

    # Check if we found any usage data
    if all(v is None for v in results.values()):
        print("WARNING: No token usage data found in workspace", file=sys.stderr)
        print("Make sure the JSON outputs contain 'usage' fields", file=sys.stderr)
        sys.exit(1)

    print_breakdown(results)

    output_path = args.output or (workspace / "cost_breakdown.json")
    save_breakdown(results, output_path)
    print(f"Cost breakdown saved to {output_path}")


if __name__ == "__main__":
    main()
