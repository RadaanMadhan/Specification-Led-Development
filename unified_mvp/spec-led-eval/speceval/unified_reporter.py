"""speceval.unified_reporter — formatter for the unified MVP report.

Takes the combined result dict produced by `unified_run.run_unified()` and
emits a presentation-ready Markdown report (plus a plain-text mirror).

Layout:

  # Unified Compliance Report — <feature-id>

  ## 1. Structural Verification (Alloy)
     - summary line + pattern list
     - compliance matrix
     - counterexamples (if any)
     - FR coverage
     - mutation tests

  ## 2. Runtime KPI Targets (WAF-derived)
     - summary line + pillar breakdown
     - per-pillar KPI tables

The two halves are reported INDEPENDENTLY — there is no cross-cutting
synthesis that constrains either side. Each pipeline is the source of
truth for its own findings.
"""

from __future__ import annotations

from collections import defaultdict
from pathlib import Path


# ---------------------------------------------------------------------------
# Public entry points
# ---------------------------------------------------------------------------

def render_unified_report_md(result: dict) -> str:
    """Render the unified report as Markdown."""
    feature_id = result.get("feature_id", "<unknown>")
    feature_dir = result.get("feature_dir", "")
    alloy = result.get("alloy")
    kpi = result.get("kpi")

    lines: list[str] = []
    lines.append(f"# Unified Compliance Report — `{feature_id}`")
    lines.append("")
    lines.append(f"*Feature folder:* `{feature_dir}`")
    lines.append("")
    lines.append(_executive_summary(alloy, kpi))
    lines.append("")
    lines.append("---")
    lines.append("")

    # --- 1. Structural Verification (Alloy) ---
    lines.append("## 1. Structural Verification (Alloy)")
    lines.append("")
    if alloy is None:
        lines.append("_Skipped via `--skip-alloy`._")
        lines.append("")
    else:
        lines.extend(_alloy_section_md(alloy))

    lines.append("---")
    lines.append("")

    # --- 2. Runtime KPI Targets (WAF-derived) ---
    lines.append("## 2. Runtime KPI Targets (WAF-derived)")
    lines.append("")
    if kpi is None:
        lines.append("_Skipped via `--skip-kpi`._")
        lines.append("")
    else:
        lines.extend(_kpi_section_md(kpi))

    return "\n".join(lines).rstrip() + "\n"


def render_unified_report_txt(result: dict) -> str:
    """Render a plain-text mirror of the unified report.

    Reuses the existing legacy text blocks where available (the Alloy half
    already produces a polished txt block via `run_verification`) and adds a
    plain-text KPI section underneath.
    """
    feature_id = result.get("feature_id", "<unknown>")
    feature_dir = result.get("feature_dir", "")
    alloy = result.get("alloy")
    kpi = result.get("kpi")

    bar = "=" * 78
    out: list[str] = []
    out.append(bar)
    out.append(f"  Unified Compliance Report  —  {feature_id}")
    out.append(f"  feature folder : {feature_dir}")
    out.append(bar)
    out.append("")
    out.append(_executive_summary_plain(alloy, kpi))
    out.append("")

    out.append(bar)
    out.append("  1. Structural Verification (Alloy)")
    out.append(bar)
    out.append("")
    if alloy is None:
        out.append("  Skipped via --skip-alloy.")
    else:
        out.append(alloy.get("report_text", "").rstrip())
    out.append("")

    out.append(bar)
    out.append("  2. Runtime KPI Targets (WAF-derived)")
    out.append(bar)
    out.append("")
    if kpi is None:
        out.append("  Skipped via --skip-kpi.")
    else:
        out.extend(_kpi_section_plain(kpi))

    return "\n".join(out).rstrip() + "\n"


def write_unified_report(
    result: dict,
    *,
    out_dir: Path,
    md_filename: str = "unified_report.md",
    txt_filename: str = "unified_report.txt",
) -> tuple[Path, Path]:
    """Write the .md and .txt reports into `out_dir`. Returns both paths."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    md_path = out_dir / md_filename
    txt_path = out_dir / txt_filename
    md_path.write_text(render_unified_report_md(result), encoding="utf-8")
    txt_path.write_text(render_unified_report_txt(result), encoding="utf-8")
    return md_path, txt_path


# ---------------------------------------------------------------------------
# Executive summary
# ---------------------------------------------------------------------------

def _executive_summary(alloy: dict | None, kpi: dict | None) -> str:
    parts: list[str] = ["## Executive summary", ""]
    if alloy is not None:
        outcome = alloy["outcome"]
        total = len(outcome.results)
        passed = sum(1 for cr in outcome.results if cr.passed)
        n_assertions = len(alloy.get("assertions", []))
        n_patterns = len(alloy.get("manifest", {}).get("patterns_applied", []) or [])
        mut = alloy.get("mutation_results") or []
        n_bit = sum(1 for m in mut if m.get("verdict") == "BIT")
        parts.append(
            f"- **Alloy / structural:** {passed}/{total} assertions PASS "
            f"({n_assertions} declared; {n_patterns} patterns applied). "
            f"Mutation strength: {n_bit}/{len(mut)} targets bit."
            if mut else
            f"- **Alloy / structural:** {passed}/{total} assertions PASS "
            f"({n_assertions} declared; {n_patterns} patterns applied)."
        )
    else:
        parts.append("- **Alloy / structural:** skipped.")

    if kpi is not None:
        n_gqm = len(kpi.get("gqm_records", []))
        n_kpi = len(kpi.get("kpi_records", []))
        n_frs = len(kpi.get("frs", []))
        pillars = sorted({
            row.get("pillar_id", "?") for row in kpi.get("kpi_records", [])
        })
        parts.append(
            f"- **WAF / KPI:** {n_gqm} GQM chains, {n_kpi} KPI rows across "
            f"{n_frs} FRs. Pillars covered: {', '.join(pillars) or '(none)'}."
        )
    else:
        parts.append("- **WAF / KPI:** skipped.")

    return "\n".join(parts)


def _executive_summary_plain(alloy: dict | None, kpi: dict | None) -> str:
    out: list[str] = ["  Executive summary"]
    if alloy is not None:
        outcome = alloy["outcome"]
        total = len(outcome.results)
        passed = sum(1 for cr in outcome.results if cr.passed)
        mut = alloy.get("mutation_results") or []
        n_bit = sum(1 for m in mut if m.get("verdict") == "BIT")
        mut_suffix = f"; mutations {n_bit}/{len(mut)} bit" if mut else ""
        out.append(
            f"    Alloy:  {passed}/{total} assertions PASS{mut_suffix}"
        )
    else:
        out.append("    Alloy:  skipped")
    if kpi is not None:
        n_gqm = len(kpi.get("gqm_records", []))
        n_kpi = len(kpi.get("kpi_records", []))
        n_frs = len(kpi.get("frs", []))
        out.append(
            f"    KPI:    {n_gqm} GQM chains, {n_kpi} KPI rows ({n_frs} FRs)"
        )
    else:
        out.append("    KPI:    skipped")
    return "\n".join(out)


# ---------------------------------------------------------------------------
# Alloy section (Markdown)
# ---------------------------------------------------------------------------

def _alloy_section_md(alloy: dict) -> list[str]:
    lines: list[str] = []
    outcome = alloy["outcome"]
    by_name = outcome.by_name()
    total = len(outcome.results)
    passed = sum(1 for cr in outcome.results if cr.passed)
    feature_id = alloy.get("feature_id", "<unknown>")
    manifest = alloy.get("manifest", {}) or {}
    patterns = manifest.get("patterns_applied", []) or []
    assertions = alloy.get("assertions", []) or []
    anchors = alloy.get("anchors", {}) or {}
    fr_ids = alloy.get("fr_ids", []) or []
    coverage = alloy.get("coverage", {}) or {}
    mutation_results = alloy.get("mutation_results", []) or []

    lines.append(f"**Feature:** `{feature_id}`")
    lines.append("")
    lines.append(f"**Alloy model:** `{alloy.get('als_path', '')}`")
    lines.append("")
    lines.append(
        f"**Verdict:** {passed}/{total} assertions PASS via Alloy "
        f"({len(assertions)} declared in the lifted model)."
    )
    lines.append("")
    if patterns:
        lines.append("**Patterns applied** (from `patterns.md`):")
        lines.append("")
        for p in patterns:
            lines.append(f"- `{p}`")
        lines.append("")

    # Compliance matrix
    lines.append("### Compliance matrix")
    lines.append("")
    lines.append("| Assertion | Verdict | Anchor |")
    lines.append("|---|---|---|")
    for a in assertions:
        cr = by_name.get(a)
        if cr is None:
            verdict = "MISSING"
        elif cr.passed:
            verdict = "PASS"
        else:
            verdict = "FAIL"
        anchor = anchors.get(a, "(no anchor comment found)")
        # Escape pipe characters in anchor text for Markdown table.
        anchor_safe = anchor.replace("|", r"\|")
        lines.append(f"| `{a}` | **{verdict}** | {anchor_safe} |")
    lines.append("")

    # Counterexamples
    failures = [cr for cr in outcome.results if not cr.passed]
    if failures:
        lines.append("### Counterexamples (Alloy SAT)")
        lines.append("")
        lines.append(
            "Each failing assertion has at least one structurally-valid "
            "world inside the Alloy scope that violates the invariant."
        )
        lines.append("")
        for cr in failures:
            anchor = anchors.get(cr.name, "(no anchor)")
            lines.append(f"- **`{cr.name}`** — {anchor}")
            lines.append(f"  - Alloy: `{cr.raw_line}`")
        lines.append("")

    # FR coverage
    lines.append("### FR coverage")
    lines.append("")
    lines.append("| FR | Covering assertions |")
    lines.append("|---|---|")
    uncovered: list[str] = []
    for fr in fr_ids:
        covers = coverage.get(fr) or []
        if not covers:
            uncovered.append(fr)
            lines.append(f"| `{fr}` | _(uncovered)_ |")
        else:
            cells = []
            for a in covers:
                cr = by_name.get(a)
                v = "PASS" if (cr and cr.passed) else (
                    "FAIL" if cr else "MISSING")
                cells.append(f"`{a}`={v}")
            lines.append(f"| `{fr}` | {', '.join(cells)} |")
    lines.append("")
    if uncovered:
        lines.append(
            f"> ⚠️ {len(uncovered)} FR(s) without any matching assertion: "
            f"`{', '.join(uncovered)}`"
        )
    else:
        lines.append("> All FRs have at least one matching assertion.")
    lines.append("")

    # Mutation tests
    if mutation_results:
        n_bit = sum(1 for m in mutation_results if m.get("verdict") == "BIT")
        lines.append("### Mutation tests (assertion-strength validation)")
        lines.append("")
        lines.append(
            f"**Summary:** {n_bit}/{len(mutation_results)} targets bit. "
            "A vacuous target either restates the cleared fact verbatim or "
            "is redundantly enforced by another fact."
        )
        lines.append("")
        lines.append("| Fact mutated | Verdict | Asserts targeted |")
        lines.append("|---|---|---|")
        for m in mutation_results:
            asserts = ", ".join(f"`{a}`" for a in m.get("asserts_violated", []))
            lines.append(
                f"| `{m['fact_name']}` | **{m['verdict']}** | {asserts} |"
            )
        lines.append("")
    return lines


# ---------------------------------------------------------------------------
# KPI section (Markdown)
# ---------------------------------------------------------------------------

_PILLAR_LABELS = {
    "reliability":  "Reliability (RE)",
    "security":     "Security (SE)",
    "cost":         "Cost Optimization (CO)",
    "operations":   "Operational Excellence (OE)",
    "performance":  "Performance Efficiency (PE)",
}


def _pillar_label(p: str) -> str:
    return _PILLAR_LABELS.get(p, p)


def _kpi_section_md(kpi: dict) -> list[str]:
    lines: list[str] = []
    feature_name = kpi.get("feature_name", "<unknown>")
    spec_id = kpi.get("spec_id", "?")
    gqm_records = kpi.get("gqm_records", []) or []
    kpi_records = kpi.get("kpi_records", []) or []
    frs = kpi.get("frs", []) or []
    fr_to_gqm = kpi.get("fr_to_gqm", {}) or {}
    fr_to_kpis = kpi.get("fr_to_kpis", {}) or {}

    lines.append(f"**Feature:** `{feature_name}`")
    lines.append("")
    lines.append(f"**Spec run id:** `{spec_id}`")
    lines.append("")
    lines.append(
        f"**Volume:** {len(gqm_records)} GQM chains, {len(kpi_records)} KPI "
        f"rows across {len(frs)} FRs."
    )
    lines.append("")

    # Pillar breakdown
    by_pillar: dict[str, list[dict]] = defaultdict(list)
    for row in kpi_records:
        by_pillar[row.get("pillar_id", "unknown")].append(row)

    lines.append("**Pillar breakdown:**")
    lines.append("")
    lines.append("| Pillar | KPI rows |")
    lines.append("|---|---|")
    for pillar in sorted(by_pillar.keys()):
        lines.append(f"| {_pillar_label(pillar)} | {len(by_pillar[pillar])} |")
    lines.append("")

    # Per-FR detail
    lines.append("### Per-FR detail")
    lines.append("")
    # Quick gqm_id → gqm record lookup
    gqm_by_id = {g["id"]: g for g in gqm_records}

    for fr in frs:
        fr_id = fr["id"]
        gqm_id = fr_to_gqm.get(fr_id)
        gqm = gqm_by_id.get(gqm_id) if gqm_id else None
        fr_kpis = fr_to_kpis.get(fr_id, []) or []
        lines.append(f"#### `{fr_id}`")
        lines.append("")
        lines.append(f"> {fr.get('text', '').strip()}")
        lines.append("")
        if gqm is None:
            lines.append("_No GQM chain derived._")
            lines.append("")
            continue
        lines.append(f"- **Pillar:** {_pillar_label(gqm.get('pillar_id', '?'))}")
        lines.append(
            f"- **WAF refs:** {', '.join(f'`{c}`' for c in gqm.get('waf_code_refs', [])) or '_(none)_'}"
        )
        lines.append(f"- **Goal:** {gqm.get('goal', '').strip()}")
        lines.append(f"- **Question:** {gqm.get('question', '').strip()}")
        lines.append(
            f"- **Metric:** `{gqm.get('metric_name', '?')}` "
            f"({gqm.get('metric_unit', '?')})"
        )
        lines.append("")
        if fr_kpis:
            lines.append("| Threshold | Direction | Numeric | Measurement |")
            lines.append("|---|---|---|---|")
            for k in fr_kpis:
                direction = (
                    "higher is better"
                    if k.get("threshold_direction") == "gte"
                    else "lower is better"
                )
                lines.append(
                    f"| {k.get('threshold_value', '?')} | "
                    f"{direction} | "
                    f"{k.get('threshold_numeric', '?')} | "
                    f"{k.get('measurement_method', '?')} |"
                )
            lines.append("")
        else:
            lines.append("_No KPI rows derived._")
            lines.append("")

    return lines


def _kpi_section_plain(kpi: dict) -> list[str]:
    lines: list[str] = []
    feature_name = kpi.get("feature_name", "<unknown>")
    spec_id = kpi.get("spec_id", "?")
    gqm_records = kpi.get("gqm_records", []) or []
    kpi_records = kpi.get("kpi_records", []) or []
    frs = kpi.get("frs", []) or []
    fr_to_gqm = kpi.get("fr_to_gqm", {}) or {}
    fr_to_kpis = kpi.get("fr_to_kpis", {}) or {}

    lines.append(f"  feature        : {feature_name}")
    lines.append(f"  spec run id    : {spec_id}")
    lines.append(
        f"  volume         : {len(gqm_records)} GQM chains, "
        f"{len(kpi_records)} KPI rows ({len(frs)} FRs)"
    )
    lines.append("")

    by_pillar: dict[str, int] = defaultdict(int)
    for row in kpi_records:
        by_pillar[row.get("pillar_id", "unknown")] += 1
    lines.append("  pillar breakdown")
    lines.append("  " + "-" * 76)
    for pillar in sorted(by_pillar.keys()):
        lines.append(f"    {_pillar_label(pillar):<32} {by_pillar[pillar]} KPI rows")
    lines.append("")

    gqm_by_id = {g["id"]: g for g in gqm_records}
    lines.append("  per-FR detail")
    lines.append("  " + "-" * 76)
    for fr in frs:
        fr_id = fr["id"]
        gqm_id = fr_to_gqm.get(fr_id)
        gqm = gqm_by_id.get(gqm_id) if gqm_id else None
        fr_kpis = fr_to_kpis.get(fr_id, []) or []
        lines.append(f"    {fr_id}  {fr.get('text', '').strip()[:70]}")
        if gqm is None:
            lines.append("      (no GQM chain)")
            continue
        lines.append(
            f"      pillar={_pillar_label(gqm.get('pillar_id', '?'))}, "
            f"waf={gqm.get('waf_code_refs', [])}"
        )
        lines.append(f"      metric: {gqm.get('metric_name')} ({gqm.get('metric_unit')})")
        for k in fr_kpis:
            direction = (
                "higher is better"
                if k.get("threshold_direction") == "gte"
                else "lower is better"
            )
            lines.append(
                f"        - {k.get('threshold_value', '?'):<14} "
                f"({direction})  via {k.get('measurement_method', '?')}"
            )
        lines.append("")
    return lines
