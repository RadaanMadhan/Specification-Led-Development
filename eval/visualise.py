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
import math
from pathlib import Path

import matplotlib.patches as mpatches
import matplotlib.pyplot as plt
import numpy as np
import seaborn as sns
from scipy import stats as _stats

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

FRAMEWORK_ORDER  = ["waf", "iso25010", "nist_csf", "sre"]
FRAMEWORK_LABELS = {"waf": "WAF", "iso25010": "ISO 25010", "nist_csf": "NIST CSF", "sre": "SRE"}
FRAMEWORK_COLORS = {"waf": "#4878cf", "iso25010": "#6acc65", "nist_csf": "#f5a623", "sre": "#d65f5f"}


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
# Figure 2 — Heatmap: Monte Carlo stability (D4) by spec × pillar
# ══════════════════════════════════════════════════════════════════════════════

def fig2_variance_heatmap(cell_rows: list[dict]) -> None:
    """
    Figure 2: D4 score heatmap — rows are spec_ids, columns are WAF pillars.

    Args:
        cell_rows: rows from cell_summary.csv.

    Output:
        eval/results/figures/variance_heatmap.png

    Edge cases:
        - Missing (spec_id, pillar_id) cells are NaN (shown as grey in heatmap).
        - Duplicate (spec_id, pillar_id) rows → mean taken.
    """
    # Build pivot table manually — WAF only to avoid name collisions with ISO pillars
    pivot: dict[str, dict[str, list[float]]] = {s: {p: [] for p in PILLAR_ORDER} for s in SPEC_ORDER}
    for row in cell_rows:
        if str(row.get("framework_id", "waf")) != "waf":
            continue
        spec = str(row.get("spec_id", ""))
        pillar = str(row.get("pillar_id", ""))
        d4 = row.get("d4")
        if spec in pivot and pillar in pivot[spec] and d4 is not None:
            pivot[spec][pillar].append(float(d4))

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
    ax.set_title("D4 Monte Carlo Threshold Stability by Spec and WAF Pillar")
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
    # Collect distinct WAF pillar_ids per spec_id — WAF only to keep pillar names consistent
    spec_pillars: dict[str, set] = {s: set() for s in SPEC_ORDER}
    for r in records:
        if str(r.get("framework_id", "waf")) != "waf":
            continue
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
    max_count = max((len(spec_pillars.get(s, set())) for s in SPEC_ORDER), default=6)
    ax.set_ylim(0, max_count * 1.2)
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


# ══════════════════════════════════════════════════════════════════════════════
# Figure 5 — Statistical significance results (3 subplots)
# ══════════════════════════════════════════════════════════════════════════════

_H_CRITICAL = 5.99  # chi2.ppf(0.95, df=2)
_RICHNESS_PAIRS = [("L1", "L2"), ("L1", "L3"), ("L2", "L3")]
_N_COMPARISONS  = len(_RICHNESS_PAIRS)


def _draw_bracket(ax, x1: float, x2: float, y: float, text: str,
                  tick: float = 0.008) -> None:
    """Draw a significance bracket between bar positions x1 and x2 at height y."""
    ax.plot([x1, x1, x2, x2], [y - tick, y, y, y - tick],
            color="black", lw=1.1, clip_on=False)
    ax.text((x1 + x2) / 2, y + 0.004, text,
            ha="center", va="bottom", fontsize=8.5)


def _cohens_d(a: np.ndarray, b: np.ndarray) -> float:
    n1, n2 = len(a), len(b)
    if n1 < 2 or n2 < 2:
        return float("nan")
    pooled = math.sqrt(
        ((n1 - 1) * float(np.var(a, ddof=1)) + (n2 - 1) * float(np.var(b, ddof=1)))
        / (n1 + n2 - 2)
    )
    return 0.0 if pooled == 0 else abs(float(np.mean(a) - np.mean(b)) / pooled)


def _sig_annotation(p_corr: float) -> str:
    if math.isnan(p_corr):
        return "n/a"
    if p_corr < 0.001:
        return "p<0.001 ***"
    if p_corr < 0.05:
        return f"p={p_corr:.3f} *"
    return f"p={p_corr:.3f} n.s."


def _compute_sig_pairs(
    groups: dict[str, list[float]]
) -> list[tuple[str, str, float, str]]:
    """Pairwise MWU with Bonferroni correction. Returns (l1, l2, cohens_d, annotation)."""
    results = []
    for l1, l2 in _RICHNESS_PAIRS:
        a = np.array(groups.get(l1, []))
        b = np.array(groups.get(l2, []))
        if len(a) < 2 or len(b) < 2:
            results.append((l1, l2, float("nan"), "n/a"))
            continue
        _, p_raw = _stats.mannwhitneyu(a, b, alternative="two-sided")
        p_corr = min(float(p_raw) * _N_COMPARISONS, 1.0)
        d = _cohens_d(a, b)
        results.append((l1, l2, d, _sig_annotation(p_corr)))
    return results


def _compute_context_h(records: list[dict]) -> dict[str, float]:
    """Kruskal-Wallis H per context across richness levels."""
    h_map = {}
    for ctx, label in CONTEXT_LABELS.items():
        sub_groups = [
            np.array([
                float(r["kqs_partial"])
                for r in records
                if str(r.get("context", "")) == ctx
                and str(r.get("richness", "")) == rn
                and r.get("kqs_partial") is not None
            ])
            for rn in ["L1", "L2", "L3"]
        ]
        valid = [g for g in sub_groups if len(g) >= 2]
        h = float(_stats.kruskal(*valid).statistic) if len(valid) >= 2 else 0.0
        h_map[f"{label} ({ctx})"] = h
    return h_map


def fig5_significance(records: list[dict]) -> None:
    """
    Figure 5: three-subplot significance summary. All statistics are computed
    from the records data at render time — nothing is hardcoded.

    Subplot 1 — Mean KQS by richness with significance brackets.
    Subplot 2 — Cohen's d effect sizes as a horizontal bar chart.
    Subplot 3 — Per-context Kruskal-Wallis H-statistics.

    Args:
        records: rows from all_scores.csv (used for mean/CI computation).

    Output:
        eval/results/figures/significance_results.png
    """
    richness_levels = ["L1", "L2", "L3"]
    bar_colors = {"L1": "#4878cf", "L2": "#6acc65", "L3": "#d65f5f"}

    # ── Compute means and 95% CI ───────────────────────────────────────────────
    kqs_groups: dict[str, list[float]] = {r: [] for r in richness_levels}
    for row in records:
        rn = str(row.get("richness", ""))
        kqs = row.get("kqs_partial")
        if rn in kqs_groups and kqs is not None:
            kqs_groups[rn].append(float(kqs))

    means, cis = {}, {}
    for rn, vals in kqs_groups.items():
        arr = np.array(vals)
        means[rn] = float(np.mean(arr)) if len(arr) else 0.0
        cis[rn]   = (1.96 * np.std(arr, ddof=1) / np.sqrt(len(arr))
                     if len(arr) > 1 else 0.0)

    # ── Compute stats from data ────────────────────────────────────────────────
    sig_pairs  = _compute_sig_pairs(kqs_groups)
    context_h  = _compute_context_h(records)

    fig, axes = plt.subplots(1, 3, figsize=(15, 5))
    fig.suptitle(
        "Statistical Significance of KPI Quality Score Differences\nacross FR Richness Levels",
        fontsize=13, fontweight="bold",
    )

    # ── Subplot 1: Mean KQS bars + significance brackets ──────────────────────
    ax1 = axes[0]
    x_pos = {rn: i for i, rn in enumerate(richness_levels)}
    ax1.bar(
        richness_levels,
        [means[rn] for rn in richness_levels],
        color=[bar_colors[rn] for rn in richness_levels],
        yerr=[cis[rn] for rn in richness_levels],
        capsize=5, alpha=0.85, error_kw={"linewidth": 1.5},
    )

    ax1.set_ylim(0.5, 1.14)
    ax1.set_xlabel("Richness Level")
    ax1.set_ylabel("Mean KQS (0–1)")
    ax1.set_title("Mean KQS by Richness Level")

    # Stacked brackets: adjacent pairs lower, wide pair highest
    bracket_y = {"L1_L2": 0.985, "L2_L3": 1.025, "L1_L3": 1.065}
    for l1, l2, _d, ann in sig_pairs:
        y_h = bracket_y.get(f"{l1}_{l2}", 1.065)
        _draw_bracket(ax1, x_pos[l1], x_pos[l2], y_h, ann)

    # ── Subplot 2: Cohen's d horizontal bar chart ──────────────────────────────
    ax2 = axes[1]
    pair_labels = [f"{l1} vs {l2}" for l1, l2, _, _ in sig_pairs]
    d_values    = [d for _, _, d, _ in sig_pairs]

    def _d_color(d: float) -> str:
        if math.isnan(d) or d < 0.5:  return "#888888"
        if d < 0.8:                    return "#f5a623"
        return "#d65f5f"

    y_pos = np.arange(len(pair_labels))
    ax2.barh(y_pos, [d if not math.isnan(d) else 0 for d in d_values],
             color=[_d_color(d) for d in d_values], alpha=0.85)
    ax2.set_yticks(y_pos)
    ax2.set_yticklabels(pair_labels)
    ax2.set_xlabel("Cohen's d")
    ax2.set_title("Effect Size (Cohen's d)")

    for thresh, label in [(0.2, "small"), (0.5, "medium"), (0.8, "large")]:
        ax2.axvline(thresh, color="grey", linestyle="--", linewidth=0.9, alpha=0.7)
        ax2.text(thresh + 0.02, len(pair_labels) - 0.55, label,
                 color="grey", fontsize=8, va="top")

    valid_d = [d for d in d_values if not math.isnan(d)]
    ax2.set_xlim(0, (max(valid_d) * 1.15) if valid_d else 2.0)

    for i, d in enumerate(d_values):
        label_d = f"d={d:.2f}" if not math.isnan(d) else "n/a"
        x_offset = (d if not math.isnan(d) else 0) + 0.02
        ax2.text(x_offset, i, label_d, va="center", fontsize=8.5)

    # ── Subplot 3: Per-context H-statistics ───────────────────────────────────
    ax3 = axes[2]
    ctx_labels = list(context_h.keys())
    h_values   = list(context_h.values())
    h_colors   = ["#6acc65" if h > _H_CRITICAL else "#888888" for h in h_values]
    h_annots   = ["***" if h > _H_CRITICAL else "n.s." for h in h_values]

    ax3.barh(np.arange(len(ctx_labels)), h_values, color=h_colors, alpha=0.85)
    ax3.set_yticks(np.arange(len(ctx_labels)))
    ax3.set_yticklabels(ctx_labels)
    ax3.set_xlabel("Kruskal-Wallis H")
    ax3.set_title("Domain Sensitivity (Kruskal-Wallis H)")

    ax3.axvline(_H_CRITICAL, color="red", linestyle="--", linewidth=1.2)
    ax3.text(_H_CRITICAL + 0.5, len(ctx_labels) - 0.6,
             f"p=0.05\n(H={_H_CRITICAL})", color="red", fontsize=8, va="top")

    for i, (h, ann) in enumerate(zip(h_values, h_annots)):
        ax3.text(h + 0.5, i, ann, va="center", fontsize=9,
                 fontweight="bold" if ann == "***" else "normal")

    ax3.set_xlim(0, max(h_values) * 1.2 if h_values else 10)

    plt.tight_layout()
    out = FIGURES_DIR / "significance_results.png"
    plt.savefig(out, dpi=300, bbox_inches="tight")
    plt.close()
    print(f"  Saved: {out}")


# ══════════════════════════════════════════════════════════════════════════════
# Figure 6 — Grouped bar: mean KQS by framework and richness level
# ══════════════════════════════════════════════════════════════════════════════

def fig6_framework_comparison(records: list[dict]) -> None:
    """
    Figure 6: mean KQS by architectural framework (x-axis), grouped bars by
    richness level (L1/L2/L3), with 95% CI error bars.

    Args:
        records: rows from all_scores.csv (one per kpi record per run).
                 Must contain framework_id, richness, kqs_partial columns.

    Output:
        eval/results/figures/framework_comparison.png

    Edge cases:
        - Missing (framework, richness) combinations produce zero-height bars.
        - Only frameworks present in the data are plotted; empty frameworks are skipped.
    """
    richness_levels = ["L1", "L2", "L3"]

    groups: dict[tuple, list[float]] = {}
    for r in records:
        fw = str(r.get("framework_id", ""))
        rn = str(r.get("richness", ""))
        kqs = r.get("kqs_partial")
        if fw and rn in richness_levels and kqs is not None:
            groups.setdefault((fw, rn), []).append(float(kqs))

    # Only include frameworks that have data
    present_frameworks = [fw for fw in FRAMEWORK_ORDER if any(k[0] == fw for k in groups)]
    if not present_frameworks:
        print("  Skipping Fig 6 — no framework_id data found in all_scores.csv")
        return

    fig, ax = plt.subplots(figsize=(10, 6))
    x = np.arange(len(present_frameworks))
    bar_width = 0.25
    n_richness = len(richness_levels)

    for i, rn in enumerate(richness_levels):
        means, cis = [], []
        for fw in present_frameworks:
            vals = groups.get((fw, rn), [])
            if vals:
                mean = np.mean(vals)
                ci95 = 1.96 * np.std(vals, ddof=1) / np.sqrt(len(vals)) if len(vals) > 1 else 0
            else:
                mean, ci95 = 0, 0
            means.append(mean)
            cis.append(ci95)

        offset = x + (i - (n_richness - 1) / 2) * bar_width
        ax.bar(
            offset, means, bar_width,
            label=rn,
            color=RICHNESS_COLORS[rn],
            yerr=cis, capsize=4, alpha=0.85, error_kw={"linewidth": 1.5},
        )

    ax.set_xlabel("Architectural Framework")
    ax.set_ylabel("Mean KQS (0–1)")
    ax.set_title("KPI Quality Score by Architectural Framework and FR Richness Level")
    ax.set_xticks(x)
    ax.set_xticklabels([FRAMEWORK_LABELS.get(fw, fw) for fw in present_frameworks])
    ax.set_ylim(0, 1.15)
    ax.legend(title="Richness Level")
    plt.tight_layout()

    out = FIGURES_DIR / "framework_comparison.png"
    plt.savefig(out, dpi=300, bbox_inches="tight")
    plt.close()
    print(f"  Saved: {out}")


# ══════════════════════════════════════════════════════════════════════════════
# Figure 7 — Stacked bar: distinct pillar_ids activated per framework
# ══════════════════════════════════════════════════════════════════════════════

def fig7_framework_pillar_coverage(records: list[dict]) -> None:
    """
    Figure 7: number of distinct pillar_ids activated per framework (x-axis),
    stacked by richness level, showing absolute pillar counts (not WAF pillar names
    so results are comparable across frameworks).

    Args:
        records: rows from all_scores.csv.

    Output:
        eval/results/figures/framework_pillar_coverage.png

    Edge cases:
        - pillar_id=None records are excluded.
        - Pillar names differ across frameworks; counts distinct pillar_ids per
          (framework, richness) combination for cross-framework comparability.
        - Frameworks with no data are skipped.
    """
    richness_levels = ["L1", "L2", "L3"]

    # Collect distinct pillar_ids per (framework, richness)
    fw_richness_pillars: dict[tuple, set] = {}
    for r in records:
        fw = str(r.get("framework_id", ""))
        rn = str(r.get("richness", ""))
        pillar = r.get("pillar_id")
        if fw and rn in richness_levels and pillar and isinstance(pillar, str):
            fw_richness_pillars.setdefault((fw, rn), set()).add(pillar)

    present_frameworks = [fw for fw in FRAMEWORK_ORDER
                          if any(k[0] == fw for k in fw_richness_pillars)]
    if not present_frameworks:
        print("  Skipping Fig 7 — no framework_id data found in all_scores.csv")
        return

    fig, ax = plt.subplots(figsize=(10, 6))
    x = np.arange(len(present_frameworks))
    bar_width = 0.55

    bottoms = np.zeros(len(present_frameworks))
    for rn in richness_levels:
        heights = [
            len(fw_richness_pillars.get((fw, rn), set()))
            for fw in present_frameworks
        ]
        ax.bar(
            x, heights, bar_width,
            bottom=bottoms,
            label=rn,
            color=RICHNESS_COLORS[rn],
            alpha=0.85,
        )
        bottoms += np.array(heights, dtype=float)

    # Annotate total on top of each bar
    for i, total in enumerate(bottoms):
        ax.text(i, total + 0.1, str(int(total)), ha="center", va="bottom", fontsize=10)

    patches = [
        mpatches.Patch(color=RICHNESS_COLORS[r],
                       label=f"{r} — {'Sparse' if r == 'L1' else 'Standard' if r == 'L2' else 'Rich'}")
        for r in richness_levels
    ]
    ax.legend(handles=patches, title="Richness")
    ax.set_xlabel("Architectural Framework")
    ax.set_ylabel("Number of Distinct Pillars Activated")
    ax.set_title("Distinct Pillar Coverage by Framework")
    ax.set_xticks(x)
    ax.set_xticklabels([FRAMEWORK_LABELS.get(fw, fw) for fw in present_frameworks])
    ax.set_ylim(0, max(bottoms) * 1.2 if bottoms.any() else 10)
    plt.tight_layout()

    out = FIGURES_DIR / "framework_pillar_coverage.png"
    plt.savefig(out, dpi=300, bbox_inches="tight")
    plt.close()
    print(f"  Saved: {out}")


# ── Main ───────────────────────────────────────────────────────────────────────

def main() -> None:
    """Load CSVs and generate all five figures."""
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
    fig5_significance(records)
    fig6_framework_comparison(records)
    fig7_framework_pillar_coverage(records)

    print(f"\nAll figures saved to {FIGURES_DIR}")


if __name__ == "__main__":
    main()
