"""
visualise.py
------------
Generates the three paper figures from aggregated experiment results.

Reads:
    eval/results/all_scores.csv     — one row per kpi record
    eval/results/cell_summary.csv   — one row per (spec_id, pillar_id)

Writes (all 300 dpi, no interactive display):
    eval/results/figures/bar_chart_kqs_by_richness.png
    eval/results/figures/variance_heatmap.png
    eval/results/figures/pillar_coverage.png

Usage:
    python eval/visualise.py

Run from project root.
"""

import csv
from pathlib import Path

import matplotlib.patches as mpatches
import matplotlib.pyplot as plt
import numpy as np
import seaborn as sns

EVAL_DIR    = Path(__file__).parent
RESULTS_DIR = EVAL_DIR / "results"
FIGURES_DIR = RESULTS_DIR / "figures"

ALL_SCORES_CSV   = RESULTS_DIR / "all_scores.csv"
CELL_SUMMARY_CSV = RESULTS_DIR / "cell_summary.csv"

SPEC_ORDER   = ["A-L1", "A-L2", "A-L3", "B-L1", "B-L2", "B-L3", "C-L1", "C-L2", "C-L3"]
PILLAR_ORDER = ["reliability", "security", "cost", "operations", "performance"]

CONTEXT_LABELS = {"A": "Banking", "B": "SaaS", "C": "Healthcare"}
CONTEXT_COLORS = {"A": "#4878cf", "B": "#6acc65", "C": "#d65f5f"}
RICHNESS_COLORS = {"L1": "#4878cf", "L2": "#f5a623", "L3": "#d65f5f"}


# ── CSV helpers ────────────────────────────────────────────────────────────────

def _read_csv(path: Path) -> list[dict]:
    """
    Read a CSV file into a list of row dicts with numeric coercion.

    Args:
        path: path to CSV file.

    Returns:
        List of dicts; numeric strings are converted to float where possible.

    Edge cases:
        - Empty file → returns empty list.
        - Non-numeric strings remain as str.
    """
    rows = []
    with path.open(encoding="utf-8") as f:
        for row in csv.DictReader(f):
            coerced: dict = {}
            for k, v in row.items():
                try:
                    coerced[k] = float(v) if v not in ("", "None") else None
                except ValueError:
                    coerced[k] = v
            rows.append(coerced)
    return rows


def _setup_style() -> None:
    """Apply seaborn whitegrid theme with consistent font scale."""
    sns.set_theme(style="whitegrid", font_scale=1.1)


# ══════════════════════════════════════════════════════════════════════════════
# Figure 1 — Bar chart: KQS by richness level, grouped by context
# ══════════════════════════════════════════════════════════════════════════════

def fig1_bar_chart(records: list[dict]) -> None:
    """
    Figure 1: mean KQS by richness level (L1/L2/L3), one bar group per context.

    Args:
        records: rows from all_scores.csv (one per kpi record per run).

    Output:
        eval/results/figures/bar_chart_kqs_by_richness.png

    Edge cases:
        - Missing (richness, context) combinations → bar omitted, no error.
        - Fewer than 2 records in a group → ci95 = 0.
    """
    richness_levels = ["L1", "L2", "L3"]
    contexts = ["A", "B", "C"]

    # Collect kqs_partial grouped by (richness, context)
    groups: dict[tuple, list[float]] = {}
    for r in records:
        rn = str(r.get("richness", ""))
        cx = str(r.get("context", ""))
        kqs = r.get("kqs_partial")
        if rn in richness_levels and cx in contexts and kqs is not None:
            groups.setdefault((rn, cx), []).append(float(kqs))

    fig, ax = plt.subplots(figsize=(10, 6))
    x = np.arange(len(richness_levels))
    bar_width = 0.25

    for i, ctx in enumerate(contexts):
        means, cis = [], []
        for rn in richness_levels:
            vals = groups.get((rn, ctx), [])
            if vals:
                mean = np.mean(vals)
                ci95 = 1.96 * np.std(vals, ddof=1) / np.sqrt(len(vals)) if len(vals) > 1 else 0
            else:
                mean, ci95 = 0, 0
            means.append(mean)
            cis.append(ci95)

        offset = x + (i - 1) * bar_width
        ax.bar(
            offset, means, bar_width,
            label=f"{CONTEXT_LABELS[ctx]} ({ctx})",
            color=CONTEXT_COLORS[ctx],
            yerr=cis, capsize=4, alpha=0.85, error_kw={"linewidth": 1.5},
        )

    ax.set_xlabel("Richness Level")
    ax.set_ylabel("Mean KQS (0–1)")
    ax.set_title("KPI Quality Score by FR Richness Level and Application Context")
    ax.set_xticks(x)
    ax.set_xticklabels(richness_levels)
    ax.set_ylim(0, 1.15)
    ax.legend(title="Context")
    plt.tight_layout()

    out = FIGURES_DIR / "bar_chart_kqs_by_richness.png"
    plt.savefig(out, dpi=300, bbox_inches="tight")
    plt.close()
    print(f"  Saved: {out}")


# ══════════════════════════════════════════════════════════════════════════════
# Figure 2 — Heatmap: Monte Carlo stability (D5) by spec × pillar
# ══════════════════════════════════════════════════════════════════════════════

def fig2_variance_heatmap(cell_rows: list[dict]) -> None:
    """
    Figure 2: D5 score heatmap — rows are spec_ids, columns are WAF pillars.

    Args:
        cell_rows: rows from cell_summary.csv.

    Output:
        eval/results/figures/variance_heatmap.png

    Edge cases:
        - Missing (spec_id, pillar_id) cells are NaN (shown as grey in heatmap).
        - Duplicate (spec_id, pillar_id) rows → mean taken.
    """
    # Build pivot table manually
    pivot: dict[str, dict[str, list[float]]] = {s: {p: [] for p in PILLAR_ORDER} for s in SPEC_ORDER}
    for row in cell_rows:
        spec = str(row.get("spec_id", ""))
        pillar = str(row.get("pillar_id", ""))
        d5 = row.get("d5")
        if spec in pivot and pillar in pivot[spec] and d5 is not None:
            pivot[spec][pillar].append(float(d5))

    matrix = np.full((len(SPEC_ORDER), len(PILLAR_ORDER)), np.nan)
    for i, spec in enumerate(SPEC_ORDER):
        for j, pillar in enumerate(PILLAR_ORDER):
            vals = pivot[spec][pillar]
            if vals:
                matrix[i, j] = np.mean(vals)

    fig, ax = plt.subplots(figsize=(10, 6))
    sns.heatmap(
        matrix,
        annot=True, fmt=".2f",
        cmap="RdYlGn", vmin=0, vmax=1,
        xticklabels=PILLAR_ORDER,
        yticklabels=SPEC_ORDER,
        linewidths=0.5, linecolor="white",
        ax=ax,
    )
    ax.set_title("Monte Carlo Threshold Stability by Spec and WAF Pillar")
    ax.set_xlabel("WAF Pillar")
    ax.set_ylabel("Spec ID")
    plt.tight_layout()

    out = FIGURES_DIR / "variance_heatmap.png"
    plt.savefig(out, dpi=300, bbox_inches="tight")
    plt.close()
    print(f"  Saved: {out}")


# ══════════════════════════════════════════════════════════════════════════════
# Figure 3 — Bar chart: distinct WAF pillars activated per spec
# ══════════════════════════════════════════════════════════════════════════════

def fig3_pillar_coverage(records: list[dict]) -> None:
    """
    Figure 3: number of distinct WAF pillars activated per spec, coloured by richness.

    Args:
        records: rows from all_scores.csv (one per kpi record per run).

    Output:
        eval/results/figures/pillar_coverage.png

    Edge cases:
        - Specs with no records → bar height 0.
        - pillar_id=None records are excluded from the distinct count.
    """
    # Collect distinct pillar_ids per spec_id across all runs
    spec_pillars: dict[str, set] = {s: set() for s in SPEC_ORDER}
    for r in records:
        spec = str(r.get("spec_id", ""))
        pillar = r.get("pillar_id")
        if spec in spec_pillars and pillar and isinstance(pillar, str):
            spec_pillars[spec].add(pillar)

    fig, ax = plt.subplots(figsize=(10, 6))

    for spec_id in SPEC_ORDER:
        richness = spec_id[2:] if len(spec_id) >= 4 else "?"
        count = len(spec_pillars.get(spec_id, set()))
        ax.bar(
            spec_id, count,
            color=RICHNESS_COLORS.get(richness, "#888888"),
            alpha=0.85,
        )
        ax.text(spec_id, count + 0.05, str(count), ha="center", va="bottom", fontsize=10)

    patches = [
        mpatches.Patch(color=c, label=f"{r} — {'Sparse' if r=='L1' else 'Standard' if r=='L2' else 'Rich'}")
        for r, c in RICHNESS_COLORS.items()
    ]
    ax.legend(handles=patches, title="Richness")
    ax.set_xlabel("Spec ID")
    ax.set_ylabel("Number of Distinct WAF Pillars")
    ax.set_title("WAF Pillar Coverage by Functional Requirement Richness")
    ax.set_ylim(0, 6)
    plt.tight_layout()

    out = FIGURES_DIR / "pillar_coverage.png"
    plt.savefig(out, dpi=300, bbox_inches="tight")
    plt.close()
    print(f"  Saved: {out}")


# ══════════════════════════════════════════════════════════════════════════════
# Figure 4 — Dual-axis line chart: cost per KPI vs mean KQS by richness
# ══════════════════════════════════════════════════════════════════════════════

def fig4_cost_efficiency(records: list[dict]) -> None:
    """
    Figure 4: cost_per_kpi_usd (left axis) and mean KQS (right axis) vs
    richness level (L1/L2/L3), one line per context (A/B/C).

    Args:
        records: rows from all_scores.csv (one per kpi record per run).
                 Must contain cost_per_kpi_usd and kqs_partial columns.

    Output:
        eval/results/figures/cost_efficiency.png

    Edge cases:
        - Skips (richness, context) groups where cost_per_kpi_usd is entirely
          None (cost_log.json missing for those runs).
        - Uses np.nan for missing groups so matplotlib gaps the line correctly.
    """
    richness_levels = ["L1", "L2", "L3"]
    contexts = ["A", "B", "C"]

    fig, ax1 = plt.subplots(figsize=(10, 6))
    ax2 = ax1.twinx()

    has_cost_data = False
    for ctx in contexts:
        cost_means, kqs_means = [], []
        for rn in richness_levels:
            group = [
                r for r in records
                if str(r.get("context", "")) == ctx
                and str(r.get("richness", "")) == rn
            ]
            # Cost mean — exclude None values
            cost_vals = [
                float(r["cost_per_kpi_usd"])
                for r in group
                if r.get("cost_per_kpi_usd") is not None
            ]
            kqs_vals = [
                float(r["kqs_partial"])
                for r in group
                if r.get("kqs_partial") is not None
            ]
            cost_means.append(np.mean(cost_vals) if cost_vals else np.nan)
            kqs_means.append(np.mean(kqs_vals) if kqs_vals else np.nan)
            if cost_vals:
                has_cost_data = True

        label = CONTEXT_LABELS[ctx]
        color = CONTEXT_COLORS[ctx]

        ax1.plot(
            richness_levels, cost_means,
            marker="o", color=color, linestyle="-", linewidth=2,
            label=f"Cost/KPI — {label}",
        )
        ax2.plot(
            richness_levels, kqs_means,
            marker="s", color=color, linestyle="--", linewidth=2,
            label=f"KQS — {label}",
        )

    if not has_cost_data:
        ax1.text(
            0.5, 0.5, "No cost data available\n(run experiment first)",
            transform=ax1.transAxes, ha="center", va="center",
            fontsize=14, color="grey",
        )

    ax1.set_xlabel("Richness Level")
    ax1.set_ylabel("Mean Cost per KPI (USD)", color="black")
    ax2.set_ylabel("Mean KQS (0–1)", color="black")
    ax1.set_title(
        "Cost-Efficiency: KPI Quality Score vs Cost per KPI by FR Richness"
    )

    # Merge legends from both axes
    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(lines1 + lines2, labels1 + labels2, loc="upper left", fontsize=9)

    plt.tight_layout()
    out = FIGURES_DIR / "cost_efficiency.png"
    plt.savefig(out, dpi=300, bbox_inches="tight")
    plt.close()
    print(f"  Saved: {out}")


# ── Main ───────────────────────────────────────────────────────────────────────

def main() -> None:
    """Load CSVs and generate all four figures."""
    print("\nKPI-Spec Evaluation — Visualisation")
    print("=" * 40)

    for path in (ALL_SCORES_CSV, CELL_SUMMARY_CSV):
        if not path.exists():
            print(f"  Missing: {path}")
            print("  Run aggregate.py first.")
            return

    FIGURES_DIR.mkdir(parents=True, exist_ok=True)
    _setup_style()

    records = _read_csv(ALL_SCORES_CSV)
    cell_rows = _read_csv(CELL_SUMMARY_CSV)
    print(f"  Loaded {len(records)} score records, {len(cell_rows)} cell summary rows")

    print("\nGenerating figures...")
    fig1_bar_chart(records)
    fig2_variance_heatmap(cell_rows)
    fig3_pillar_coverage(records)
    fig4_cost_efficiency(records)

    print(f"\nAll figures saved to {FIGURES_DIR}")


if __name__ == "__main__":
    main()
