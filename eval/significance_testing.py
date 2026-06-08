"""
significance_testing.py
-----------------------
Statistical significance analysis on KQS scores from eval/results/all_scores.csv.

Runs:
    1. Kruskal-Wallis H-test across richness levels (L1/L2/L3)
    2. Post-hoc pairwise Mann-Whitney U tests with Bonferroni correction
    3. Cohen's d effect sizes for significant pairs
    4. Per-context Kruskal-Wallis breakdown
    5. D4 Monte Carlo stability significance tests

Writes:
    eval/results/significance_report.md

Usage:
    python eval/significance_testing.py

Run from project root.
"""

import math
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")

import numpy as np
import pandas as pd
from scipy import stats

EVAL_DIR    = Path(__file__).parent
RESULTS_DIR = EVAL_DIR / "results"
CSV_PATH    = RESULTS_DIR / "all_scores.csv"
REPORT_PATH = RESULTS_DIR / "significance_report.md"

CONTEXT_LABELS  = {"A": "Banking", "B": "SaaS", "C": "Healthcare"}
RICHNESS_PAIRS  = [("L1", "L2"), ("L1", "L3"), ("L2", "L3")]
N_COMPARISONS   = len(RICHNESS_PAIRS)

FRAMEWORK_ORDER  = ["waf", "iso25010", "nist_csf", "sre"]
FRAMEWORK_LABELS = {"waf": "WAF", "iso25010": "ISO 25010", "nist_csf": "NIST CSF", "sre": "SRE"}
N_FW_COMPARISONS = 6  # C(4,2)


# ── Helpers ────────────────────────────────────────────────────────────────────

def cohens_d(a: np.ndarray, b: np.ndarray) -> float:
    """
    Cohen's d using pooled standard deviation.

    Args:
        a, b: 1-D arrays of observations.

    Returns:
        Absolute value of Cohen's d (magnitude only).

    Edge cases:
        - Pooled std == 0 → returns 0.0.
    """
    n1, n2 = len(a), len(b)
    if n1 < 2 or n2 < 2:
        return float("nan")
    var1 = np.var(a, ddof=1)
    var2 = np.var(b, ddof=1)
    pooled_std = math.sqrt(((n1 - 1) * var1 + (n2 - 1) * var2) / (n1 + n2 - 2))
    if pooled_std == 0:
        return 0.0
    return abs((np.mean(a) - np.mean(b)) / pooled_std)


def interpret_d(d: float) -> str:
    if math.isnan(d):
        return "n/a"
    if d < 0.2:
        return "negligible"
    if d < 0.5:
        return "small"
    if d < 0.8:
        return "medium"
    return "large"


def sig_label(p: float, threshold: float = 0.05) -> str:
    return "significant" if p < threshold else "not significant"


def kruskal_result(groups: list[np.ndarray]) -> tuple[float, float]:
    """Run Kruskal-Wallis; returns (H, p). H=0, p=1.0 if insufficient data."""
    valid = [g for g in groups if len(g) >= 2]
    if len(valid) < 2:
        return 0.0, 1.0
    h, p = stats.kruskal(*valid)
    return float(h), float(p)


def pairwise_mwu(
    groups: dict[str, np.ndarray]
) -> list[tuple[str, str, float, float, float]]:
    """
    Pairwise Mann-Whitney U with Bonferroni correction.

    Returns list of (label1, label2, U, p_corrected, d).
    """
    results = []
    for l1, l2 in RICHNESS_PAIRS:
        a, b = groups.get(l1, np.array([])), groups.get(l2, np.array([]))
        if len(a) < 2 or len(b) < 2:
            results.append((l1, l2, float("nan"), float("nan"), float("nan")))
            continue
        u, p_raw = stats.mannwhitneyu(a, b, alternative="two-sided")
        p_corr = min(p_raw * N_COMPARISONS, 1.0)
        d = cohens_d(a, b)
        results.append((l1, l2, float(u), p_corr, d))
    return results


# ── Report sections ────────────────────────────────────────────────────────────

def section_overall_kqs(df: pd.DataFrame) -> tuple[str, float, float, dict]:
    groups = {r: df.loc[df["richness"] == r, "kqs_partial"].dropna().to_numpy()
              for r in ["L1", "L2", "L3"]}
    h, p = kruskal_result(list(groups.values()))

    lines = [
        "## Overall KQS — Kruskal-Wallis",
        f"H = {h:.2f}, p = {p:.4f}",
        f"Result: {sig_label(p)} at p < 0.05",
    ]
    return "\n".join(lines), h, p, groups


def section_pairwise(groups: dict, metric_label: str = "KQS") -> str:
    pairs = pairwise_mwu(groups)
    lines = [f"## Pairwise {metric_label} comparisons (Bonferroni corrected)"]
    for l1, l2, u, p_corr, d in pairs:
        u_str = f"U = {u:.0f}" if not math.isnan(u) else "U = n/a"
        p_str = f"p = {p_corr:.4f}" if not math.isnan(p_corr) else "p = n/a"
        d_str = f"d = {d:.2f} ({interpret_d(d)})" if not math.isnan(d) else "d = n/a"
        sig = sig_label(p_corr) if not math.isnan(p_corr) else "n/a"
        lines.append(f"{l1} vs {l2}: {u_str}, {p_str} -> {sig} - {d_str}")
    return "\n".join(lines)


def section_per_context(df: pd.DataFrame) -> str:
    lines = ["## Per-context Kruskal-Wallis"]
    for ctx, label in CONTEXT_LABELS.items():
        sub = df[df["context"] == ctx]
        groups = [sub.loc[sub["richness"] == r, "kqs_partial"].dropna().to_numpy()
                  for r in ["L1", "L2", "L3"]]
        h, p = kruskal_result(groups)
        lines.append(f"{label} ({ctx}):   H = {h:.2f}, p = {p:.4f} -> {sig_label(p)}")
    return "\n".join(lines)


def section_d4(df: pd.DataFrame) -> tuple[str, float, float, dict]:
    groups = {r: df.loc[df["richness"] == r, "d4"].dropna().to_numpy()
              for r in ["L1", "L2", "L3"]}
    h, p = kruskal_result(list(groups.values()))

    lines = [
        "## D4 Monte Carlo stability — Kruskal-Wallis",
        f"H = {h:.2f}, p = {p:.4f} -> {sig_label(p)}",
    ]
    return "\n".join(lines), h, p, groups


def section_d4_pairwise(groups: dict) -> str:
    pairs = pairwise_mwu(groups)
    lines = ["## Pairwise D4 comparisons (Bonferroni corrected)"]
    for l1, l2, u, p_corr, d in pairs:
        p_str = f"p = {p_corr:.4f}" if not math.isnan(p_corr) else "p = n/a"
        d_str = f"d = {d:.2f} ({interpret_d(d)})" if not math.isnan(d) else "d = n/a"
        lines.append(f"{l1} vs {l2}: {p_str} · {d_str}")
    return "\n".join(lines)


def plain_english_summary(
    kqs_h: float, kqs_p: float,
    kqs_groups: dict,
    d4_h: float, d4_p: float,
) -> str:
    kqs_pairs = pairwise_mwu(kqs_groups)
    pair_map = {(l1, l2): (p, d) for l1, l2, _, p, d in kqs_pairs}

    l1l2_p, l1l2_d = pair_map.get(("L1", "L2"), (1.0, float("nan")))
    l2l3_p, l2l3_d = pair_map.get(("L2", "L3"), (1.0, float("nan")))
    l1l3_p, l1l3_d = pair_map.get(("L1", "L3"), (1.0, float("nan")))

    def p_phrase(p):
        if math.isnan(p): return "could not be assessed"
        if p < 0.001: return f"highly significant (p = {p:.4f})"
        if p < 0.05:  return f"significant (p = {p:.4f})"
        return f"not significant after Bonferroni correction (p = {p:.4f})"

    means = {r: float(np.mean(g)) for r, g in kqs_groups.items() if len(g) > 0}
    l1m, l2m, l3m = means.get("L1", 0), means.get("L2", 0), means.get("L3", 0)
    if l1m < l2m > l3m:
        trend = "peaks at L2 then drops at L3"
    elif l1m < l2m < l3m:
        trend = "increases monotonically"
    elif l1m > l2m > l3m:
        trend = "decreases monotonically"
    else:
        trend = "varies non-monotonically"

    para = (
        f"The Kruskal-Wallis test on overall KQS scores yields H = {kqs_h:.2f} "
        f"(p = {kqs_p:.4f}), indicating that differences across richness levels are "
        f"{sig_label(kqs_p)}. "
        f"Mean KQS {trend} across levels (L1 = {means.get('L1', float('nan')):.3f}, "
        f"L2 = {means.get('L2', float('nan')):.3f}, L3 = {means.get('L3', float('nan')):.3f}). "
        f"The L1→L2 improvement is {p_phrase(l1l2_p)}"
        f"{f' with a {interpret_d(l1l2_d)} effect (d = {l1l2_d:.2f})' if not math.isnan(l1l2_d) else ''}. "
        f"The L2→L3 drop is {p_phrase(l2l3_p)}"
        f"{f' with a {interpret_d(l2l3_d)} effect (d = {l2l3_d:.2f})' if not math.isnan(l2l3_d) else ''}. "
        f"The L1 vs L3 contrast is {p_phrase(l1l3_p)}"
        f"{f' (d = {l1l3_d:.2f})' if not math.isnan(l1l3_d) else ''}. "
        f"For D4 stability, the Kruskal-Wallis test yields H = {d4_h:.2f} (p = {d4_p:.4f}), "
        f"which is {sig_label(d4_p)}, "
        f"{'confirming that richer specs produce more stable numeric thresholds across Monte Carlo runs.' if d4_p < 0.05 else 'suggesting that threshold stability does not vary significantly with specification richness in this sample.'}"
    )
    return "## Interpretation\n" + para


# ══════════════════════════════════════════════════════════════════════════════
# Framework comparison — helpers and section builders
# ══════════════════════════════════════════════════════════════════════════════

def _fw_groups(df: pd.DataFrame, richness: str | None = None) -> dict[str, np.ndarray]:
    """
    Build per-framework KQS arrays from df, optionally filtered to one richness level.

    Args:
        df:       full scores dataframe with framework_id and kqs_partial columns.
        richness: if given (e.g. 'L2'), restrict to that richness level only.

    Returns:
        Dict mapping framework identifier → numpy array of kqs_partial values.
        Frameworks with zero observations are included as empty arrays so callers
        can report them without key-error risk.
    """
    sub = df if richness is None else df[df["richness"] == richness]
    return {
        fw: sub.loc[sub["framework_id"] == fw, "kqs_partial"].dropna().to_numpy()
        for fw in FRAMEWORK_ORDER
    }


def _pairwise_mwu_frameworks(
    groups: dict[str, np.ndarray]
) -> list[tuple[str, str, float, float, float]]:
    """
    Pairwise Mann-Whitney U across all C(4,2)=6 framework pairs with Bonferroni correction.

    Only pairs where both groups have ≥ 2 observations are tested; others receive nan.

    Args:
        groups: dict framework_id → KQS array (from _fw_groups).

    Returns:
        List of (label1, label2, U, p_bonferroni, cohens_d) tuples, one per pair.
        p_bonferroni is clamped to 1.0.
    """
    fw_present = [fw for fw in FRAMEWORK_ORDER if len(groups.get(fw, [])) >= 2]
    all_pairs  = [(a, b) for i, a in enumerate(fw_present) for b in fw_present[i + 1:]]

    results = []
    for l1, l2 in all_pairs:
        a = groups.get(l1, np.array([]))
        b = groups.get(l2, np.array([]))
        if len(a) < 2 or len(b) < 2:
            results.append((l1, l2, float("nan"), float("nan"), float("nan")))
            continue
        u, p_raw = stats.mannwhitneyu(a, b, alternative="two-sided")
        p_corr   = min(float(p_raw) * N_FW_COMPARISONS, 1.0)
        d        = cohens_d(a, b)
        results.append((l1, l2, float(u), p_corr, d))
    return results


def section_fw_kruskal(df: pd.DataFrame, richness: str | None = None) -> tuple[str, float, float, dict]:
    """
    Kruskal-Wallis across all four frameworks on KQS scores.

    Args:
        df:       full scores dataframe.
        richness: if given, restrict to that richness level only.

    Returns:
        (markdown_text, H, p, groups_dict)
    """
    level_label = f"L2 only" if richness == "L2" else "all richness levels"
    groups      = _fw_groups(df, richness)
    present     = {fw: v for fw, v in groups.items() if len(v) >= 2}

    if len(present) < 2:
        text = (
            f"### Kruskal-Wallis across frameworks ({level_label})\n"
            f"Insufficient data — need ≥ 2 frameworks with ≥ 2 observations each."
        )
        return text, 0.0, 1.0, groups

    h, p = kruskal_result(list(present.values()))

    means_parts = [
        f"{FRAMEWORK_LABELS[fw]} = {np.mean(v):.3f} (n={len(v)})"
        for fw, v in present.items()
    ]
    lines = [
        f"### Kruskal-Wallis across frameworks ({level_label})",
        f"H = {h:.2f},  p = {p:.4f}  →  {sig_label(p)} at α = 0.05",
        f"Group means:  " + ",  ".join(means_parts),
    ]
    return "\n".join(lines), h, p, groups


def section_fw_pairwise(groups: dict[str, np.ndarray], level_label: str) -> str:
    """
    Pairwise Mann-Whitney U for all 6 framework pairs, Bonferroni-corrected.

    Args:
        groups:      dict from _fw_groups.
        level_label: human-readable label for the richness scope.

    Returns:
        Markdown section string.
    """
    pairs = _pairwise_mwu_frameworks(groups)
    lines = [f"### Pairwise Mann-Whitney U — frameworks (Bonferroni n={N_FW_COMPARISONS}, {level_label})"]
    for l1, l2, u, p_corr, d in pairs:
        l1_lbl = FRAMEWORK_LABELS.get(l1, l1)
        l2_lbl = FRAMEWORK_LABELS.get(l2, l2)
        u_str  = f"U = {u:.0f}"      if not math.isnan(u)      else "U = n/a"
        p_str  = f"p_adj = {p_corr:.4f}" if not math.isnan(p_corr) else "p_adj = n/a"
        d_str  = f"d = {d:.2f} ({interpret_d(d)})" if not math.isnan(d) else "d = n/a"
        sig    = sig_label(p_corr) if not math.isnan(p_corr) else "n/a"
        lines.append(f"{l1_lbl} vs {l2_lbl}:  {u_str},  {p_str}  →  {sig}  —  {d_str}")
    return "\n".join(lines)


def section_fw_interpretation(
    kw_all_h:  float, kw_all_p:  float, groups_all:  dict[str, np.ndarray],
    kw_l2_h:   float, kw_l2_p:   float, groups_l2:   dict[str, np.ndarray],
) -> str:
    """
    Plain-English summary of the framework comparison results.

    Describes the overall K-W result, which pairs are significant after correction,
    and whether framework effects are more pronounced at L2.
    """
    pairs_all = _pairwise_mwu_frameworks(groups_all)
    pairs_l2  = _pairwise_mwu_frameworks(groups_l2)

    sig_all = [(l1, l2, p, d) for l1, l2, _, p, d in pairs_all
               if not math.isnan(p) and p < 0.05]
    sig_l2  = [(l1, l2, p, d) for l1, l2, _, p, d in pairs_l2
               if not math.isnan(p) and p < 0.05]

    def p_phrase(p: float) -> str:
        if math.isnan(p):  return "could not be assessed"
        if p < 0.001:      return f"highly significant (p_adj = {p:.4f})"
        if p < 0.05:       return f"significant (p_adj = {p:.4f})"
        return f"not significant after Bonferroni correction (p_adj = {p:.4f})"

    means_all = {fw: float(np.mean(v)) for fw, v in groups_all.items() if len(v) > 0}
    best_fw   = max(means_all, key=means_all.__getitem__) if means_all else None
    worst_fw  = min(means_all, key=means_all.__getitem__) if means_all else None

    parts: list[str] = []

    parts.append(
        f"The Kruskal-Wallis test across all four frameworks (all richness levels combined) "
        f"yields H = {kw_all_h:.2f} (p = {kw_all_p:.4f}), indicating that framework choice "
        f"{'does' if kw_all_p < 0.05 else 'does not'} significantly affect KPI quality scores "
        f"at α = 0.05. "
    )

    if means_all:
        ranked = sorted(means_all.items(), key=lambda x: -x[1])
        means_str = ",  ".join(
            f"{FRAMEWORK_LABELS[fw]} = {m:.3f}" for fw, m in ranked
        )
        parts.append(f"Mean KQS by framework (descending): {means_str}. ")
        if best_fw and worst_fw:
            parts.append(
                f"{FRAMEWORK_LABELS[best_fw]} produces the highest mean KQS "
                f"and {FRAMEWORK_LABELS[worst_fw]} the lowest. "
            )

    if sig_all:
        sig_str = ";  ".join(
            f"{FRAMEWORK_LABELS.get(l1, l1)} vs {FRAMEWORK_LABELS.get(l2, l2)} "
            f"({interpret_d(d)} effect, d = {d:.2f})"
            for l1, l2, p, d in sig_all
        )
        parts.append(
            f"{len(sig_all)} of {N_FW_COMPARISONS} pairwise comparisons remain significant "
            f"after Bonferroni correction: {sig_str}. "
        )
    else:
        parts.append(
            f"No pairwise comparisons remain significant after Bonferroni correction, "
            f"suggesting observed mean differences may reflect sampling variability rather "
            f"than a systematic framework effect at this sample size. "
        )

    parts.append(
        f"At L2 richness only, the Kruskal-Wallis test yields H = {kw_l2_h:.2f} "
        f"(p = {kw_l2_p:.4f}), which is {sig_label(kw_l2_p)}. "
    )

    if len(sig_l2) > len(sig_all):
        parts.append(
            "Framework differences are more pronounced at L2 than across all richness levels "
            "combined, consistent with the hypothesis that framework choice matters most at "
            "optimal input quality."
        )
    elif len(sig_l2) == 0 and len(sig_all) == 0:
        parts.append(
            "Neither the combined nor the L2-only analysis yields significant framework "
            "differences, suggesting the KPI pipeline is relatively robust to knowledge "
            "base choice at this sample size."
        )
    else:
        parts.append(
            "The significance pattern is similar at L2 and across all richness levels, "
            "suggesting framework effects are not concentrated at a particular input quality."
        )

    return "### Interpretation\n" + "".join(parts)


# ── Main ───────────────────────────────────────────────────────────────────────

def main() -> None:
    print("\nKPI-Spec Evaluation — Significance Testing")
    print("=" * 45)

    if not CSV_PATH.exists():
        print(f"  Missing: {CSV_PATH}")
        print("  Run aggregate.py first.")
        return

    df = pd.read_csv(CSV_PATH)
    print(f"  Loaded {len(df)} records from {CSV_PATH.name}")

    sections = []

    # 1. Overall KQS Kruskal-Wallis
    kqs_kw, kqs_h, kqs_p, kqs_groups = section_overall_kqs(df)
    sections.append(kqs_kw)
    print(f"\n{kqs_kw}")

    # 2. Pairwise KQS
    kqs_pairs_text = section_pairwise(kqs_groups, metric_label="KQS")
    sections.append(kqs_pairs_text)
    print(f"\n{kqs_pairs_text}")

    # 3. Per-context
    ctx_text = section_per_context(df)
    sections.append(ctx_text)
    print(f"\n{ctx_text}")

    # 4 & 5. D4
    d4_kw, d4_h, d4_p, d4_groups = section_d4(df)
    sections.append(d4_kw)
    print(f"\n{d4_kw}")

    d4_pairs_text = section_d4_pairwise(d4_groups)
    sections.append(d4_pairs_text)
    print(f"\n{d4_pairs_text}")

    # Interpretation
    interp = plain_english_summary(kqs_h, kqs_p, kqs_groups, d4_h, d4_p)
    sections.append(interp)
    print(f"\n{interp}")

    # ── Framework comparison (only if framework_id column exists with >1 value) ──
    has_framework_data = (
        "framework_id" in df.columns
        and df["framework_id"].notna().any()
        and df["framework_id"].nunique() > 1
    )

    if has_framework_data:
        n_frameworks = df["framework_id"].nunique()
        print(f"\n  framework_id column present: {n_frameworks} distinct frameworks detected")

        fw_header = "## Framework Comparison — Kruskal-Wallis"
        sections.append(fw_header)
        print(f"\n{fw_header}")

        # 1 — K-W all richness combined
        fw_kw_all_text, fw_kw_all_h, fw_kw_all_p, fw_groups_all = section_fw_kruskal(df)
        sections.append(fw_kw_all_text)
        print(f"\n{fw_kw_all_text}")

        # 2 — Pairwise MWU all richness
        fw_pw_all_text = section_fw_pairwise(fw_groups_all, level_label="all richness levels")
        sections.append(fw_pw_all_text)
        print(f"\n{fw_pw_all_text}")

        # 3 — K-W L2 only
        fw_kw_l2_text, fw_kw_l2_h, fw_kw_l2_p, fw_groups_l2 = section_fw_kruskal(df, richness="L2")
        sections.append(fw_kw_l2_text)
        print(f"\n{fw_kw_l2_text}")

        # 4 — Pairwise MWU L2 only
        fw_pw_l2_text = section_fw_pairwise(fw_groups_l2, level_label="L2 only")
        sections.append(fw_pw_l2_text)
        print(f"\n{fw_pw_l2_text}")

        # 5 — Interpretation
        fw_interp = section_fw_interpretation(
            fw_kw_all_h, fw_kw_all_p, fw_groups_all,
            fw_kw_l2_h,  fw_kw_l2_p,  fw_groups_l2,
        )
        sections.append(fw_interp)
        print(f"\n{fw_interp}")
    else:
        note = (
            "## Framework Comparison — Kruskal-Wallis\n"
            "_No multi-framework data found in all_scores.csv. "
            "Run `python eval/run_experiment.py --mode framework_comparison` "
            "then re-run aggregate.py to populate this section._"
        )
        sections.append(note)
        print(f"\n  Skipping framework comparison — only one framework_id value present")

    report = "\n\n".join(sections) + "\n"
    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(report, encoding="utf-8")
    print(f"\n  Report written -> {REPORT_PATH}")


if __name__ == "__main__":
    main()
