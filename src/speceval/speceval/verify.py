"""speceval.verify — core design-mode verification pipeline.

Extracted from cli.py to allow unified_run.py (and other callers) to
import run_verification() without pulling in Click or triggering
circular dependencies.
"""

from __future__ import annotations

from pathlib import Path

from speceval.kpi_extractor import extract_all_kpis, save_kpis_json
from speceval.lifter_design import (
    DesignLiftError,
    emit_mutated_als,
    extract_anchors,
    fr_coverage,
    lift_design,
    list_assertions,
    load_design_inputs,
    parse_mutation_targets,
    write_feature_model,
)
from speceval.parser import parse_spec
from speceval.providers.anthropic import AnthropicProvider
from speceval.runner import default_alloy_jar, run_alloy_file


def _project_root() -> Path:
    """The speceval package root (src/speceval/)."""
    return Path(__file__).resolve().parent.parent


def _design_cache_dir() -> Path:
    p = _project_root() / "cache" / "lifts_design"
    p.mkdir(parents=True, exist_ok=True)
    return p


def get_run_dir(feature_id: str) -> Path:
    p = _project_root().parent.parent / "runs" / feature_id
    p.mkdir(parents=True, exist_ok=True)
    return p


def _patterns_md_path() -> Path:
    return _project_root() / "patterns.md"


def run_verification(
    feature_dir: Path,
    *,
    alloy_jar: Path | None = None,
    no_cache: bool = False,
    no_mutate: bool = False,
    java_bin: str = "java",
    echo=None,
) -> dict:
    """Run design-mode verification and return a result dict."""
    if echo is None:
        def echo(_msg, *args, **kwargs):  # noqa: ARG001
            return None

    feature_dir = Path(feature_dir).resolve()
    patterns_md = _patterns_md_path()

    # --- Load inputs and FR list (for coverage analysis) ---
    inputs = load_design_inputs(feature_dir, patterns_md_path=patterns_md)
    parsed = parse_spec(feature_dir / "spec.md")
    fr_ids = [fr.id for fr in parsed.requirements]
    echo(
        f"[parse]   feature {inputs.feature_id!r}, "
        f"{len(fr_ids)} FRs, {len(parsed.user_stories)} user stories"
    )

    # --- Lift via LLM ---
    provider = AnthropicProvider.from_env()
    echo(f"[lift]    calling LLM ({provider.name}: {provider.model})...")
    pkg = lift_design(
        inputs,
        provider=provider,
        cache_dir=_design_cache_dir(),
        use_cache=(not no_cache),
    )

    if pkg.cache_hit:
        echo(f"[lift]    cache hit (sha={pkg.sha[:12]})")
    else:
        echo(f"[lift]    fresh lift (sha={pkg.sha[:12]})")

    # --- Persist the .als + manifest into runs/<feature-id>/ ---
    run_dir = get_run_dir(inputs.feature_id)
    als_path = write_feature_model(pkg, run_dir)
    echo(f"[write]   {als_path}")

    # --- Run Alloy on feature_model.als ---
    jar = alloy_jar or default_alloy_jar()
    if not jar.exists():
        raise FileNotFoundError(
            f"Alloy jar not found at {jar}. Pass --alloy-jar=<path> or place "
            "the jar at tools/alloy.jar."
        )

    echo(f"[alloy]   running {jar.name} on {als_path.name}...")
    outcome = run_alloy_file(als_path, alloy_jar=jar, java_bin=java_bin)

    if not outcome.results:
        raise RuntimeError(
            "Alloy produced no parseable verdicts.\n"
            f"--- alloy stdout ---\n{outcome.stdout}\n"
            f"--- alloy stderr ---\n{outcome.stderr}\n"
        )

    # --- Compliance matrix ---
    assertions = list_assertions(pkg.feature_model_als)
    anchors = extract_anchors(pkg.feature_model_als)
    coverage = fr_coverage(fr_ids, pkg.manifest, assertions)

    report_lines = _render_design_report(
        feature_id=inputs.feature_id,
        feature_dir=feature_dir,
        als_path=als_path,
        outcome=outcome,
        assertions=assertions,
        anchors=anchors,
        manifest=pkg.manifest,
        fr_ids=fr_ids,
        coverage=coverage,
    )

    # --- Optional: mutation testing ---
    mutation_results: list[dict] = []
    if not no_mutate:
        mut_lines, mutation_results = _run_mutation_tests(
            pkg=pkg,
            run_dir=run_dir,
            jar=jar,
            java_bin=java_bin,
            return_structured=True,
        )
        report_lines.extend(mut_lines)

    # --- Extract KPIs from spec.md and save to JSON ---
    kpi_collection = extract_all_kpis(
        feature_id=inputs.feature_id,
        spec_md=inputs.spec_md,
        user_prompt="",  # User prompt not available in verification mode
        feature_name=inputs.feature_id.replace("-", " ").title(),
        alloy_code=pkg.feature_model_als,  # Pass Alloy code for KPI matching
    )
    kpi_output = run_dir / "kpis.json"
    save_kpis_json(kpi_collection, kpi_output)
    echo(
        f"[kpi]     extracted {len(kpi_collection.merged_kpis)} KPIs "
        f"({len(kpi_collection.speckit_kpis)} from spec.md) → {kpi_output}"
    )
    kpi_lines = _render_kpi_section(kpi_collection)
    report_lines.extend(kpi_lines)

    report_text = "\n".join(report_lines) + "\n"

    return {
        "feature_id": inputs.feature_id,
        "feature_dir": feature_dir,
        "als_path": als_path,
        "run_dir": run_dir,
        "pkg": pkg,
        "outcome": outcome,
        "assertions": assertions,
        "anchors": anchors,
        "manifest": pkg.manifest,
        "fr_ids": fr_ids,
        "coverage": coverage,
        "mutation_results": mutation_results,
        "kpi_collection": kpi_collection,
        "kpi_output": kpi_output,
        "report_text": report_text,
    }


def _render_design_report(
    *,
    feature_id: str,
    feature_dir: Path,
    als_path: Path,
    outcome,
    assertions: list[str],
    anchors: dict,
    manifest: dict,
    fr_ids: list[str],
    coverage: dict,
) -> list[str]:
    by_name = outcome.by_name()
    pass_count = sum(1 for cr in outcome.results if cr.passed)
    total = len(outcome.results)

    lines: list[str] = []
    bar = "=" * 78
    lines.append(bar)
    lines.append("  Design Compliance Report  (Phase 3 — feature_model.als)")
    lines.append(f"  feature       : {feature_id}")
    lines.append(f"  spec source   : {feature_dir}")
    lines.append(f"  alloy model   : {als_path}")
    lines.append(
        f"  patterns      : "
        f"{', '.join(manifest.get('patterns_applied', [])) or '(none declared)'}"
    )
    lines.append(
        f"  fr count      : {len(fr_ids)} declared in spec.md"
    )
    lines.append(
        f"  assertions    : {len(assertions)} total "
        f"({pass_count}/{total} PASS via Alloy)"
    )
    lines.append(bar)
    lines.append("")

    # Compliance matrix
    lines.append("  Compliance matrix")
    lines.append("  " + "-" * 76)
    col_a = max(20, max((len(a) for a in assertions), default=0))
    col_v = 8
    header = f"  {'Assertion':<{col_a}}  {'Verdict':<{col_v}}  Anchor"
    lines.append(header)
    lines.append("  " + "-" * (col_a + col_v + 30))
    for a in assertions:
        cr = by_name.get(a)
        if cr is None:
            verdict = "MISSING"
        elif cr.passed:
            verdict = "PASS"
        else:
            verdict = "FAIL"
        anchor = anchors.get(a, "(no anchor comment found)")
        lines.append(f"  {a:<{col_a}}  {verdict:<{col_v}}  {anchor}")
    lines.append("")

    # Failure details
    failures = [cr for cr in outcome.results if not cr.passed]
    if failures:
        lines.append("  Counterexamples (Alloy SAT)")
        lines.append("  " + "-" * 76)
        for cr in failures:
            anchor = anchors.get(cr.name, "(no anchor)")
            lines.append(f"  {cr.name}  [{anchor}]")
            lines.append(f"    Alloy: {cr.raw_line}")
            lines.append(
                "    A counterexample exists within the Alloy scope; the "
                "encoded invariant is violated by some structurally-valid "
                "world. Review the encoding."
            )
            lines.append("")

    # FR coverage matrix
    lines.append("  FR coverage")
    lines.append("  " + "-" * 76)
    uncovered: list[str] = []
    for fr in fr_ids:
        covers = coverage.get(fr) or []
        if not covers:
            uncovered.append(fr)
            lines.append(f"  {fr}  [uncovered]")
        else:
            verdicts = []
            for a in covers:
                cr = by_name.get(a)
                v = "PASS" if (cr and cr.passed) else (
                    "FAIL" if cr else "MISSING")
                verdicts.append(f"{a}={v}")
            lines.append(f"  {fr}  →  {', '.join(verdicts)}")
    lines.append("")
    if uncovered:
        lines.append(
            f"  WARNING: {len(uncovered)} FR(s) without any matching assertion: "
            f"{', '.join(uncovered)}"
        )
    else:
        lines.append("  All FRs have at least one matching assertion.")
    lines.append("")
    return lines


def _render_kpi_section(kpi_collection) -> list[str]:
    """Render KPI extraction results with fulfillment status for the report."""
    lines: list[str] = []
    bar = "=" * 78
    lines.append(bar)
    lines.append("  KPI Extraction & Fulfillment Analysis")
    lines.append(bar)
    lines.append("")

    total_unique = len(kpi_collection.merged_kpis)
    fulfilled = sum(1 for kpi in kpi_collection.merged_kpis if kpi.status == "Fulfilled")
    to_measure = sum(1 for kpi in kpi_collection.merged_kpis if kpi.status == "To be measured")
    missing = sum(1 for kpi in kpi_collection.merged_kpis if kpi.status == "Missing")
    technical = sum(1 for kpi in kpi_collection.merged_kpis if kpi.kpi_type == "Technical")
    business = sum(1 for kpi in kpi_collection.merged_kpis if kpi.kpi_type == "Business")

    lines.append(
        f"  Extracted {total_unique} KPIs ({technical} Technical, {business} Business)"
    )
    lines.append(
        f"    ({len(kpi_collection.speckit_kpis)} from SpecKit spec)"
    )
    lines.append("")
    lines.append("  Status Summary")
    lines.append("  " + "-" * 76)
    lines.append(f"    ✓ Fulfilled (addressed by Alloy code):      {fulfilled}")
    lines.append(f"    ○ To be measured (runtime metrics):         {to_measure}")
    lines.append(f"    ✗ Missing (not addressed):                  {missing}")
    lines.append("")

    if kpi_collection.merged_kpis:
        lines.append("  KPI Details")
        lines.append("  " + "-" * 76)
        
        # Group by status for clarity
        status_groups = {
            "Fulfilled": [],
            "To be measured": [],
            "Missing": [],
        }
        for kpi in kpi_collection.merged_kpis:
            status_groups[kpi.status].append(kpi)
        
        for status_label, status_emoji in [
            ("Fulfilled", "✓"),
            ("To be measured", "○"),
            ("Missing", "✗"),
        ]:
            kpis = status_groups[status_label]
            if not kpis:
                continue
            
            lines.append(f"  {status_emoji} {status_label}")
            for kpi in sorted(kpis, key=lambda k: k.name):
                lines.append(
                    f"      [{kpi.kpi_type} | {kpi.category}] {kpi.name}"
                )
                if kpi.matched_constraint:
                    lines.append(
                        f"          → Matched to: {kpi.matched_constraint}"
                    )
                if kpi.measurement_strategy:
                    lines.append(
                        f"          → Measurement: {kpi.measurement_strategy[:60]}"
                    )
            lines.append("")
    else:
        lines.append("  No KPIs extracted from spec.md.")
        lines.append("")

    return lines


def _run_mutation_tests(
    *,
    pkg,
    run_dir: Path,
    jar: Path,
    java_bin: str,
    return_structured: bool = False,
):
    """Apply each mutation target, re-run Alloy, confirm targeted asserts FAIL."""
    out: list[str] = []
    structured: list[dict] = []
    bar = "=" * 78
    out.append(bar)
    out.append("  Mutation tests  (assertion-strength validation)")
    out.append(bar)
    out.append("")

    mutations = parse_mutation_targets(pkg.manifest)
    if not mutations:
        out.append("  No mutation_targets in manifest. Skipped.")
        out.append("")
        if return_structured:
            return out, structured
        return out

    out.append(
        "  Strategy: replace each named fact's body with `{}` (no constraint),"
    )
    out.append(
        "  then re-run Alloy. Each listed assertion should now FAIL on the"
    )
    out.append(
        "  mutated model. If it still PASSes, the assertion is vacuous and"
    )
    out.append("  must be strengthened.")
    out.append("")

    summary_lines: list[str] = []
    for mut in mutations:
        try:
            mutated_als = emit_mutated_als(
                pkg.feature_model_als,
                fact_name=mut.fact_name,
                inject_violation=mut.inject_violation,
            )
        except DesignLiftError as e:
            out.append(f"  - MUTATE {mut.fact_name}: ERROR — {e}")
            summary_lines.append(
                f"  - MUTATE {mut.fact_name}: skipped (fact not found)"
            )
            out.append("")
            structured.append({
                "fact_name": mut.fact_name,
                "asserts_violated": mut.asserts_violated,
                "rationale": mut.rationale,
                "per_assert": {a: "MISSING" for a in mut.asserts_violated},
                "all_bit": False,
                "verdict": "SKIPPED",
                "error": str(e),
            })
            continue

        mut_path = run_dir / f"mutated_{mut.fact_name}.als"
        mut_path.write_text(mutated_als, encoding="utf-8")

        outcome = run_alloy_file(mut_path, alloy_jar=jar, java_bin=java_bin)
        by_name = outcome.by_name()

        out.append(
            f"  - MUTATE {mut.fact_name}  → {mut_path.relative_to(run_dir.parent.parent) if run_dir.is_relative_to(run_dir.parent.parent) else mut_path}"
        )
        out.append(f"    rationale: {mut.rationale or '(none given)'}")
        out.append("    expected to FAIL: " + ", ".join(mut.asserts_violated))
        per_assert: dict[str, str] = {}
        for a in mut.asserts_violated:
            cr = by_name.get(a)
            if cr is None:
                verdict = "MISSING"
            else:
                verdict = "FAIL (expected)" if not cr.passed else "PASS (vacuous?)"
            per_assert[a] = verdict
            out.append(f"      - {a}: {verdict}")
        if not outcome.results:
            out.append(
                "    WARNING: Alloy returned no verdicts for this mutant; "
                "stderr below."
            )
            out.append("    " + outcome.stderr.replace("\n", "\n    ")[:400])
        out.append("")

        all_fail = all(
            (by_name.get(a) is not None and not by_name[a].passed)
            for a in mut.asserts_violated
        )
        verdict_line = "ASSERTIONS BIT" if all_fail else "ASSERTION VACUOUS"
        summary_lines.append(
            f"  - {mut.fact_name}: {verdict_line} "
            f"({', '.join(mut.asserts_violated)})"
        )
        structured.append({
            "fact_name": mut.fact_name,
            "asserts_violated": mut.asserts_violated,
            "rationale": mut.rationale,
            "per_assert": per_assert,
            "all_bit": all_fail,
            "verdict": "BIT" if all_fail else "VACUOUS",
        })

    out.append("  Mutation summary")
    out.append("  " + "-" * 76)
    out.extend(summary_lines)
    out.append("")
    if return_structured:
        return out, structured
    return out
