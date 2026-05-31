"""
aggregate.py
------------
Loads all scored records from all runs, computes D5 (Monte Carlo stability)
per (spec_id, fr_id, metric_name) group, and writes:

    eval/results/all_scores.csv      — one row per kpi record across all 90 runs
    eval/results/cell_summary.csv    — one row per (spec_id, pillar_id) with mean KQS + D5

Usage:
    python eval/aggregate.py

Run from project root.
"""

import csv
import json
import math
from pathlib import Path

EVAL_DIR    = Path(__file__).parent
RUNS_DIR    = EVAL_DIR / "runs"
RESULTS_DIR = EVAL_DIR / "results"

ALL_SCORES_CSV    = RESULTS_DIR / "all_scores.csv"
CELL_SUMMARY_CSV  = RESULTS_DIR / "cell_summary.csv"

SPEC_ORDER   = ["A-L1", "A-L2", "A-L3", "B-L1", "B-L2", "B-L3", "C-L1", "C-L2", "C-L3"]
PILLAR_ORDER = ["reliability", "security", "cost", "operations", "performance"]

ALL_SCORES_FIELDS = [
    "run_id", "spec_id", "framework_id", "richness", "context", "fr_id",
    "kpi_id", "gqm_id", "pillar_id", "metric_name",
    "threshold_numeric", "threshold_direction", "waf_code_refs",
    "d1", "d3", "d4", "kqs_partial", "d5",
    "total_tokens", "cost_usd", "cost_per_kpi_usd",
]

CELL_FIELDS = [
    "spec_id", "framework_id", "context", "richness", "pillar_id", "n_records",
    "d1_mean", "d3_mean", "d4_mean", "d5",
    "kqs_partial_mean", "kqs_full",
]


# ── D5 computation ─────────────────────────────────────────────────────────────

def compute_d5(values: list[float]) -> float:
    """
    Compute Monte Carlo stability score for a group of threshold_numeric values.

    Args:
        values: list of threshold_numeric floats (nulls excluded before calling).

    Returns:
        0.5  — fewer than 2 non-null values (insufficient data)
        0.0  — mean is zero (CV undefined, treat as maximally unstable)
        max(0.0, 1.0 - cv)  — coefficient of variation inverted; clamped to [0, 1]

    Edge cases:
        - Empty list → 0.5
        - All identical values → std=0 → cv=0 → D5=1.0
        - Mean == 0 → cv undefined → D5=0.0
    """
    if len(values) < 2:
        return 0.5

    n = len(values)
    mean = sum(values) / n
    if mean == 0:
        return 0.0

    variance = sum((x - mean) ** 2 for x in values) / (n - 1)
    std = math.sqrt(variance)
    cv = std / mean
    return max(0.0, 1.0 - cv)


# ── Data loading ───────────────────────────────────────────────────────────────

def load_all_scores() -> list[dict]:
    """
    Walk eval/runs/ and return a flat list of scored records.

    Supports both old layout (runs/{spec_id}/run_{nn}/scores.json) and new
    framework-aware layout (runs/{spec_id}/{framework}/run_{nn}/scores.json).
    framework_id is extracted from the directory structure; records from the
    old layout receive framework_id='waf' for backwards compatibility.

    Returns:
        List of scored record dicts with framework_id attached.
    """
    all_records: list[dict] = []

    # Determine which (spec, framework) pairs have new-layout runs so old-layout
    # WAF runs are not double-counted when the framework comparison was also run.
    new_layout_keys: set = set()
    for f in RUNS_DIR.glob("*/*/run_*/scores.json"):
        spec     = f.parent.parent.parent.name
        framework = f.parent.parent.name
        new_layout_keys.add((spec, framework))

    # New layout: spec_id / framework / run_NN
    for scores_file in sorted(RUNS_DIR.glob("*/*/run_*/scores.json")):
        try:
            framework_id = scores_file.parent.parent.name
            records = json.loads(scores_file.read_text())
            for r in records:
                r.setdefault("framework_id", framework_id)
            all_records.extend(records)
        except Exception as e:
            print(f"  ! Skipping {scores_file}: {e}")

    # Old layout: spec_id / run_NN (no framework directory)
    # Skip any spec that already has new-layout WAF runs to avoid inflating WAF n.
    for scores_file in sorted(RUNS_DIR.glob("*/run_*/scores.json")):
        spec = scores_file.parent.parent.name
        if (spec, "waf") in new_layout_keys:
            continue
        try:
            records = json.loads(scores_file.read_text())
            for r in records:
                r.setdefault("framework_id", "waf")
            all_records.extend(records)
        except Exception as e:
            print(f"  ! Skipping {scores_file}: {e}")

    return all_records


# ── Cost data loading ──────────────────────────────────────────────────────────

def load_cost_data() -> dict[str, dict]:
    """
    Walk eval/runs/*/run_*/cost_log.json and return a dict keyed by run_id.

    Args:
        (none — reads from RUNS_DIR)

    Returns:
        Dict mapping run_id → cost_log dict (fields: total_tokens, cost_usd,
        cost_per_kpi_usd, model, etc.).

    Edge cases:
        - Missing or malformed cost_log.json files are skipped with a warning.
        - If run_id is missing from the file, the file is skipped.
    """
    cost_map: dict[str, dict] = {}
    # New framework-aware layout: spec / framework / run_NN
    for cost_file in sorted(RUNS_DIR.glob("*/*/run_*/cost_log.json")):
        try:
            data = json.loads(cost_file.read_text())
            run_id = data.get("run_id")
            if run_id:
                cost_map[run_id] = data
        except Exception as e:
            print(f"  ! Skipping {cost_file}: {e}")
    # Old layout: spec / run_NN
    for cost_file in sorted(RUNS_DIR.glob("*/run_*/cost_log.json")):
        try:
            data = json.loads(cost_file.read_text())
            run_id = data.get("run_id")
            if run_id and run_id not in cost_map:
                cost_map[run_id] = data
        except Exception as e:
            print(f"  ! Skipping {cost_file}: {e}")
    return cost_map


def attach_cost(records: list[dict], cost_map: dict[str, dict]) -> list[dict]:
    """
    Merge cost fields from cost_map into each scored record.

    Args:
        records:  flat list of scored records (output of load_all_scores).
        cost_map: dict keyed by run_id, values are cost_log dicts.

    Returns:
        Same list with total_tokens, cost_usd, cost_per_kpi_usd added in-place.

    Edge cases:
        - Records whose run_id has no matching cost_log entry get None values.
    """
    for r in records:
        run_id = r.get("run_id", "")
        cost = cost_map.get(run_id)
        if cost is None:
            # New-layout cost_logs embed the framework in the run_id
            # e.g. scores use "A-L1_run_01" but cost_log has "A-L1_waf_run_01"
            framework = r.get("framework_id") or "waf"
            fw_run_id = run_id.replace("_run_", f"_{framework}_run_", 1)
            cost = cost_map.get(fw_run_id, {})
        r["total_tokens"]     = cost.get("total_tokens")
        r["cost_usd"]         = cost.get("cost_usd")
        r["cost_per_kpi_usd"] = cost.get("cost_per_kpi_usd")
    return records


# ── D5 attachment ──────────────────────────────────────────────────────────────

def attach_d5(records: list[dict]) -> list[dict]:
    """
    Compute D5 for each (spec_id, fr_id, metric_name) group and attach to records.

    Args:
        records: flat list of scored records (output of load_all_scores).

    Returns:
        Same list with 'd5' field added to each record in-place.

    Edge cases:
        - Records with threshold_numeric=None are excluded from the value list
          but still receive a d5 score based on the group's other values.
        - Groups with < 2 non-null values receive d5=0.5.
    """
    groups: dict[tuple, list[float]] = {}
    for r in records:
        key = (r.get("spec_id", ""), r.get("framework_id", ""), r.get("fr_id", ""), r.get("metric_name", ""))
        numeric = r.get("threshold_numeric")
        if numeric is not None:
            groups.setdefault(key, []).append(float(numeric))

    d5_map = {k: compute_d5(vs) for k, vs in groups.items()}

    for r in records:
        key = (r.get("spec_id", ""), r.get("framework_id", ""), r.get("fr_id", ""), r.get("metric_name", ""))
        r["d5"] = round(d5_map.get(key, 0.5), 4)

    return records


# ── Cell summary ───────────────────────────────────────────────────────────────

def compute_cell_summary(records: list[dict]) -> list[dict]:
    """
    Group records by (spec_id, framework_id, pillar_id) and compute aggregate KQS metrics.

    Args:
        records: list of scored records with d5 already attached.

    Returns:
        List of cell summary dicts sorted by SPEC_ORDER × framework × PILLAR_ORDER.

    Edge cases:
        - pillar_id=None records are grouped under 'unknown'.
        - framework_id=None records are grouped under 'waf'.
        - D5 per cell is the mean of the unique D5 values for distinct
          (fr_id, metric_name) groups within the cell.
        - kqs_full = mean(D1, D3, D4, D5) — four dimensions.
    """
    cells: dict[tuple, list[dict]] = {}
    for r in records:
        key = (
            r.get("spec_id", "?"),
            r.get("framework_id") or "waf",
            r.get("pillar_id") or "unknown",
        )
        cells.setdefault(key, []).append(r)

    summary = []
    for (spec_id, framework_id, pillar_id), cell_records in cells.items():
        n = len(cell_records)
        d1_mean  = sum(r["d1"]  for r in cell_records) / n
        d3_mean  = sum(r["d3"]  for r in cell_records) / n
        d4_mean  = sum(r["d4"]  for r in cell_records) / n
        kqs_partial_mean = sum(r["kqs_partial"] for r in cell_records) / n

        group_d5: dict[tuple, float] = {}
        for r in cell_records:
            gkey = (r.get("fr_id", ""), r.get("metric_name", ""))
            group_d5[gkey] = r["d5"]
        d5 = sum(group_d5.values()) / len(group_d5) if group_d5 else 0.5

        # kqs_full uses 4 dimensions: D1, D3, D4, D5
        kqs_full = (d1_mean + d3_mean + d4_mean + d5) / 4

        summary.append({
            "spec_id":          spec_id,
            "framework_id":     framework_id,
            "context":          spec_id[0] if spec_id else "?",
            "richness":         spec_id[2:] if len(spec_id) >= 4 else "?",
            "pillar_id":        pillar_id,
            "n_records":        n,
            "d1_mean":          round(d1_mean, 4),
            "d3_mean":          round(d3_mean, 4),
            "d4_mean":          round(d4_mean, 4),
            "d5":               round(d5, 4),
            "kqs_partial_mean": round(kqs_partial_mean, 4),
            "kqs_full":         round(kqs_full, 4),
        })

    spec_rank   = {s: i for i, s in enumerate(SPEC_ORDER)}
    pillar_rank = {p: i for i, p in enumerate(PILLAR_ORDER)}
    summary.sort(key=lambda r: (
        spec_rank.get(r["spec_id"], 99),
        r.get("framework_id", ""),
        pillar_rank.get(r["pillar_id"], 99),
    ))
    return summary


# ── CSV writers ────────────────────────────────────────────────────────────────

def _write_csv(path: Path, rows: list[dict], fieldnames: list[str]) -> None:
    """
    Write a list of dicts to a CSV file.

    Args:
        path:       output file path (parent directory must exist).
        rows:       list of row dicts.
        fieldnames: ordered list of column names.

    Edge cases:
        - waf_code_refs is a list; serialised as pipe-separated string in CSV.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            flat = dict(row)
            if "waf_code_refs" in flat and isinstance(flat["waf_code_refs"], list):
                flat["waf_code_refs"] = "|".join(flat["waf_code_refs"])
            writer.writerow(flat)
    print(f"  Wrote {len(rows)} rows -> {path}")


# ── Main ───────────────────────────────────────────────────────────────────────

def main() -> None:
    """Load all scored runs, compute D5, write CSVs."""
    print("\nKPI-Spec Evaluation — Aggregation")
    print("=" * 40)

    records = load_all_scores()
    if not records:
        print("  No scores.json files found under eval/runs/. Run run_experiment.py first.")
        return

    print(f"  Loaded {len(records)} scored records across all runs")

    cost_map = load_cost_data()
    print(f"  Loaded cost data for {len(cost_map)} runs")

    records = attach_cost(records, cost_map)
    records = attach_d5(records)
    cell_summary = compute_cell_summary(records)

    _write_csv(ALL_SCORES_CSV, records, ALL_SCORES_FIELDS)
    _write_csv(CELL_SUMMARY_CSV, cell_summary, CELL_FIELDS)

    print(f"\nAggregation complete.")
    print(f"  all_scores.csv   -> {ALL_SCORES_CSV}")
    print(f"  cell_summary.csv -> {CELL_SUMMARY_CSV}")
    print(f"\nRun visualise.py next to generate figures.")


if __name__ == "__main__":
    main()
