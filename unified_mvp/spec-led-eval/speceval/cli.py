"""cli.py — `speceval` command-line entry point.

Subcommands:
    speceval check <spec.md>     Run the full pipeline and print a report.
    speceval lift  <spec.md>     Print the generated snapshot.als (no Alloy run).
    speceval verify-alloy        Sanity-check that Java + alloy.jar are installed
                                 and can run the bundled tiny snapshots.

`check` and `lift` use the LLM-driven lifter (Anthropic Claude) by
default. Pass `--hardcoded` to use the Phase-1 Pomodoro-only mapping
(useful for offline development or to compare against the LLM output).
"""

from __future__ import annotations

import sys
from pathlib import Path

import click

from speceval.lifter import LiftError, lift_with_llm, render_review
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
from speceval.parser import ParsedSpec, parse_spec, summarise
from speceval.providers.anthropic import AnthropicProvider
from speceval.reporter import ReportInputs, print_report
from speceval.runner import (
    default_alloy_dir,
    default_alloy_jar,
    run_alloy,
    run_alloy_file,
)
from speceval.snapshot import (
    LiftResult,
    lift_pomodoro_hardcoded,
    render_snapshot,
)


# ---------------------------------------------------------------------------
# Lifter dispatch
# ---------------------------------------------------------------------------

def _default_cache_dir() -> Path:
    here = Path(__file__).resolve().parent.parent
    p = here / "cache" / "lifts"
    p.mkdir(parents=True, exist_ok=True)
    return p


def _do_lift(
    parsed: ParsedSpec,
    *,
    use_hardcoded: bool,
    use_cache: bool,
    review_mode: bool,
) -> LiftResult:
    """Run the configured lifter and (if review_mode) ask for confirmation.

    Returns the LiftResult ready for snapshot generation. May call
    `click.Abort` if the user declines the lift.
    """
    if use_hardcoded:
        click.echo("[lift]   using hardcoded Pomodoro mapping (--hardcoded)")
        return lift_pomodoro_hardcoded(parsed)

    try:
        provider = AnthropicProvider.from_env()
    except RuntimeError as e:
        raise click.ClickException(
            f"{e}\nTip: copy .env.example to .env and fill in your key, "
            f"or pass --hardcoded for an offline run on the Pomodoro spec."
        )

    click.echo(f"[lift]   calling LLM ({provider.name}: {provider.model})...")
    try:
        pkg = lift_with_llm(
            parsed,
            provider=provider,
            cache_dir=_default_cache_dir(),
            use_cache=use_cache,
        )
    except LiftError as e:
        raise click.ClickException(str(e))

    if pkg.cache_hit:
        click.echo(f"[lift]   cache hit (sha256={pkg.spec_hash[:12]})")
    else:
        click.echo(f"[lift]   fresh extraction + validation done")

    if review_mode:
        click.echo("")
        click.echo(render_review(pkg, parsed))
        if not click.confirm("Proceed with this lift?", default=True):
            raise click.Abort()

    return pkg.lift


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

@click.group()
@click.version_option("0.1.0", prog_name="speceval")
def main() -> None:
    """Lift a SpecKit spec.md into Alloy and check generic KPIs."""


@main.command("check")
@click.argument("spec_path", type=click.Path(exists=True, dir_okay=False, path_type=Path))
@click.option(
    "--alloy-jar",
    type=click.Path(exists=True, dir_okay=False, path_type=Path),
    default=None,
    help="Path to the Alloy Analyzer jar. Defaults to tools/alloy.jar.",
)
@click.option(
    "--keep-assembled",
    type=click.Path(dir_okay=False, path_type=Path),
    default=None,
    help="If set, write a copy of the assembled .als file here for inspection.",
)
@click.option(
    "--hardcoded",
    is_flag=True,
    default=False,
    help="Use the offline hardcoded Pomodoro lifter instead of the LLM.",
)
@click.option(
    "--review/--no-review",
    default=True,
    help="Pause after lifting to confirm before running Alloy (default: review).",
)
@click.option(
    "--no-cache",
    is_flag=True,
    default=False,
    help="Force a fresh LLM lift even if a cached result is available.",
)
def cmd_check(
    spec_path: Path,
    alloy_jar: Path | None,
    keep_assembled: Path | None,
    hardcoded: bool,
    review: bool,
    no_cache: bool,
) -> None:
    """Run the full pipeline: parse → lift → snapshot → Alloy → report."""
    parsed = parse_spec(spec_path)
    click.echo(f"[parse]  {summarise(parsed)}")

    lift = _do_lift(
        parsed,
        use_hardcoded=hardcoded,
        use_cache=(not no_cache),
        review_mode=review,
    )
    click.echo(
        f"[lift]   {len(lift.scenarios)} scenarios, "
        f"{len(lift.states)} states, "
        f"{len(lift.actions)} actions, "
        f"{len(lift.requirements)} requirements, "
        f"{len(lift.stories)} stories"
    )

    snapshot_text = render_snapshot(
        lift,
        header_comment=f"Snapshot lifted from {spec_path.name}",
    )
    snap_path = Path(_tmp_snapshot())
    snap_path.write_text(snapshot_text, encoding="utf-8")
    click.echo(f"[snap]   wrote {snap_path}")

    jar = alloy_jar or default_alloy_jar()
    if not jar.exists():
        raise click.ClickException(
            f"Alloy jar not found at {jar}. Either pass --alloy-jar=<path> "
            f"or place the jar at tools/alloy.jar.\n"
            f"You can fetch it from:\n"
            f"  https://github.com/AlloyTools/org.alloytools.alloy/releases"
        )

    click.echo(f"[alloy]  running {jar.name}...")
    outcome = run_alloy(
        domain_als=default_alloy_dir() / "domain.als",
        kpi_library_als=default_alloy_dir() / "kpi_library.als",
        snapshot_als=snap_path,
        alloy_jar=jar,
        keep_assembled_path=keep_assembled,
    )

    # If Alloy ran but produced no parseable verdicts, surface its raw
    # output so the user (or maintainer) can diagnose. This typically
    # signals an Alloy syntax error in the snapshot or a CLI version
    # mismatch.
    if not outcome.results:
        click.echo(
            "[error] Alloy produced no parseable verdicts. "
            "Raw output below for diagnosis:",
            err=True,
        )
        click.echo("--- alloy stdout ---", err=True)
        click.echo(outcome.stdout, err=True)
        click.echo("--- alloy stderr ---", err=True)
        click.echo(outcome.stderr, err=True)
        sys.exit(2)

    print_report(ReportInputs(
        parsed=parsed,
        lift=lift,
        outcome=outcome,
        spec_path=str(spec_path),
    ))


@main.command("lift")
@click.argument("spec_path", type=click.Path(exists=True, dir_okay=False, path_type=Path))
@click.option("--hardcoded", is_flag=True, default=False,
              help="Use the offline hardcoded Pomodoro lifter instead of the LLM.")
@click.option("--no-cache", is_flag=True, default=False,
              help="Force a fresh LLM lift.")
def cmd_lift(spec_path: Path, hardcoded: bool, no_cache: bool) -> None:
    """Print the generated snapshot.als for a spec, without running Alloy."""
    parsed = parse_spec(spec_path)
    lift = _do_lift(
        parsed,
        use_hardcoded=hardcoded,
        use_cache=(not no_cache),
        review_mode=False,
    )
    click.echo(render_snapshot(
        lift,
        header_comment=f"Snapshot lifted from {spec_path.name}",
    ))


@main.command("verify-alloy")
@click.option(
    "--alloy-jar",
    type=click.Path(exists=True, dir_okay=False, path_type=Path),
    default=None,
)
def cmd_verify_alloy(alloy_jar: Path | None) -> None:
    """Run Alloy on the bundled tiny snapshots to confirm the toolchain."""
    here = Path(__file__).resolve().parent.parent
    jar = alloy_jar or default_alloy_jar()
    if not jar.exists():
        raise click.ClickException(f"Alloy jar not found at {jar}")

    for example in ("tiny_passing_snapshot.als", "tiny_failing_snapshot.als"):
        snap = here / "examples" / example
        click.echo(f"\n=== {example} ===")
        outcome = run_alloy(
            domain_als=default_alloy_dir() / "domain.als",
            kpi_library_als=default_alloy_dir() / "kpi_library.als",
            snapshot_als=snap,
            alloy_jar=jar,
        )
        for cr in outcome.results:
            verdict = "PASS" if cr.passed else "FAIL"
            click.echo(f"  {cr.name:12s}  {verdict}")
        if outcome.returncode != 0:
            click.echo(f"  (alloy exit code: {outcome.returncode})")


def _tmp_snapshot() -> Path:
    """Path to a stable scratch file for the per-run generated snapshot."""
    here = Path(__file__).resolve().parent.parent
    out = here / "cache" / "last_snapshot.als"
    out.parent.mkdir(exist_ok=True)
    return out


# ---------------------------------------------------------------------------
# Phase 3 — verify-design
#
# Drives the LLM-driven feature_model.als lifter, runs Alloy, prints a
# compliance matrix mapping each assertion to its anchor (PATTERN or FR)
# with PASS/FAIL, and (optionally) does mutation testing to confirm
# assertions are non-vacuous.
# ---------------------------------------------------------------------------

def _project_root() -> Path:
    return Path(__file__).resolve().parent.parent


def _design_cache_dir() -> Path:
    p = _project_root() / "cache" / "lifts_design"
    p.mkdir(parents=True, exist_ok=True)
    return p


def _design_run_dir(feature_id: str) -> Path:
    p = _project_root() / "runs" / feature_id
    p.mkdir(parents=True, exist_ok=True)
    return p


def _patterns_md_path() -> Path:
    return _project_root() / "patterns.md"


@main.command("verify-design")
@click.argument(
    "feature_dir",
    type=click.Path(exists=True, file_okay=False, path_type=Path),
)
@click.option(
    "--alloy-jar",
    type=click.Path(exists=True, dir_okay=False, path_type=Path),
    default=None,
    help="Path to the Alloy Analyzer jar. Defaults to tools/alloy.jar.",
)
@click.option(
    "--no-cache",
    is_flag=True,
    default=False,
    help="Force a fresh LLM lift even if a cached result is available.",
)
@click.option(
    "--no-mutate",
    is_flag=True,
    default=False,
    help="Skip the mutation-test pass (useful for fast iteration).",
)
@click.option(
    "--report-out",
    type=click.Path(dir_okay=False, path_type=Path),
    default=None,
    help="If set, also write the compliance report to this file.",
)
@click.option(
    "--java-bin",
    default="java",
    help="Java executable to use (default: `java` on PATH).",
)
def cmd_verify_design(
    feature_dir: Path,
    alloy_jar: Path | None,
    no_cache: bool,
    no_mutate: bool,
    report_out: Path | None,
    java_bin: str,
) -> None:
    """Phase-3 design-mode verification of a Speckit feature folder.

    FEATURE_DIR is a Speckit feature folder containing spec.md,
    data-model.md, and contracts/http-api.md. Calls Claude Opus to
    author a `feature_model.als`, runs Alloy on it, and prints a
    compliance matrix mapping each assertion to its anchor.
    """
    try:
        result = run_verification(
            feature_dir,
            alloy_jar=alloy_jar,
            no_cache=no_cache,
            no_mutate=no_mutate,
            java_bin=java_bin,
            echo=click.echo,
        )
    except (DesignLiftError, FileNotFoundError, RuntimeError) as e:
        raise click.ClickException(str(e))

    report_text = result["report_text"]
    click.echo("\n" + report_text)

    run_dir: Path = result["run_dir"]
    default_report_path = run_dir / "report.txt"
    default_report_path.write_text(report_text, encoding="utf-8")
    click.echo(f"[write]   {default_report_path}")
    if report_out is not None:
        report_out.write_text(report_text, encoding="utf-8")
        click.echo(f"[write]   {report_out}")


def run_verification(
    feature_dir: Path,
    *,
    alloy_jar: Path | None = None,
    no_cache: bool = False,
    no_mutate: bool = False,
    java_bin: str = "java",
    echo=None,
) -> dict:
    """Run the Phase-3 design-mode verification pipeline and return a result dict.

    This is the in-process API the unified orchestrator drives. It does NOT
    print to stdout unless an `echo` callable is supplied; it does NOT raise
    click exceptions. Returns a dict with all artefacts the reporter needs.
    """
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
    run_dir = _design_run_dir(inputs.feature_id)
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


def _run_mutation_tests(
    *,
    pkg,
    run_dir: Path,
    jar: Path,
    java_bin: str,
    return_structured: bool = False,
):
    """Apply each mutation_target, re-run Alloy, confirm targeted asserts FAIL.

    Returns the human-readable text-block lines. If `return_structured=True`,
    returns a 2-tuple `(lines, mutation_results)` where mutation_results is a
    list of dicts describing each mutation's outcome — one entry per target.
    """
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


# ---------------------------------------------------------------------------
# Phase 3+ — unified-verify (Alloy half + WAF-KPI half, single report)
# ---------------------------------------------------------------------------

@main.command("unified-verify")
@click.argument(
    "feature_dir",
    type=click.Path(exists=True, file_okay=False, path_type=Path),
)
@click.option(
    "--alloy-jar",
    type=click.Path(exists=True, dir_okay=False, path_type=Path),
    default=None,
    help="Path to the Alloy Analyzer jar. Defaults to tools/alloy.jar.",
)
@click.option(
    "--no-cache",
    is_flag=True,
    default=False,
    help="Force a fresh Alloy LLM lift even if a cached result is available.",
)
@click.option(
    "--no-mutate",
    is_flag=True,
    default=False,
    help="Skip the mutation-test pass on the Alloy half.",
)
@click.option(
    "--skip-alloy",
    is_flag=True,
    default=False,
    help="Run only the WAF-KPI half (useful for offline KPI inspection).",
)
@click.option(
    "--skip-kpi",
    is_flag=True,
    default=False,
    help="Run only the Alloy structural half (useful when OpenAI is offline).",
)
@click.option(
    "--java-bin",
    default="java",
    help="Java executable to use for Alloy (default: `java` on PATH).",
)
@click.option(
    "--report-out",
    type=click.Path(dir_okay=False, path_type=Path),
    default=None,
    help="Optional extra path to write the unified Markdown report to.",
)
def cmd_unified_verify(
    feature_dir: Path,
    alloy_jar: Path | None,
    no_cache: bool,
    no_mutate: bool,
    skip_alloy: bool,
    skip_kpi: bool,
    java_bin: str,
    report_out: Path | None,
) -> None:
    """Run both halves of the MVP on a Speckit feature folder and emit ONE report.

    Halves:
      1. Structural verification via Alloy (this package, Phase 3)
      2. WAF-derived runtime KPI targets (kpi_agent, imported in-process)

    Writes unified_report.md and unified_report.txt to
    runs/<feature-id>/ inside this spec-led-eval folder.
    """
    from speceval.unified_run import run_unified
    from speceval.unified_reporter import write_unified_report

    feature_dir = feature_dir.resolve()
    try:
        result = run_unified(
            feature_dir,
            alloy_jar=alloy_jar,
            java_bin=java_bin,
            no_cache=no_cache,
            no_mutate=no_mutate,
            skip_alloy=skip_alloy,
            skip_kpi=skip_kpi,
            echo=click.echo,
        )
    except (DesignLiftError, FileNotFoundError, RuntimeError) as e:
        raise click.ClickException(str(e))

    run_dir = _design_run_dir(result["feature_id"])
    md_path, txt_path = write_unified_report(result, out_dir=run_dir)
    click.echo("")
    click.echo(f"[write]   {md_path}")
    click.echo(f"[write]   {txt_path}")

    if report_out is not None:
        from speceval.unified_reporter import render_unified_report_md
        report_out.write_text(render_unified_report_md(result), encoding="utf-8")
        click.echo(f"[write]   {report_out}")


if __name__ == "__main__":
    main()
