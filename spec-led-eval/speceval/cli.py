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

import json
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
    write_cost_log,
    write_feature_model,
)
from speceval.parser import ParsedSpec, parse_spec, summarise
from speceval.providers.anthropic import TIER_CONFIG, AnthropicProvider
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
@click.option(
    "--model",
    "tier",
    type=click.Choice(["M-best", "M-mid", "M-small"], case_sensitive=True),
    default="M-best",
    show_default=True,
    help=(
        "Model tier from eval/MODEL_SELECTION.md. M-best=Opus 4.7 (adaptive), "
        "M-mid=Sonnet 4.6 (adaptive), M-small=Haiku 4.5 (manual)."
    ),
)
def cmd_verify_design(
    feature_dir: Path,
    alloy_jar: Path | None,
    no_cache: bool,
    no_mutate: bool,
    report_out: Path | None,
    java_bin: str,
    tier: str,
) -> None:
    """Phase-3 design-mode verification of a Speckit feature folder.

    FEATURE_DIR is a Speckit feature folder containing spec.md,
    data-model.md, and contracts/http-api.md. Calls the configured tier's
    Claude model to author a `feature_model.als`, runs Alloy on it, and
    prints a compliance matrix mapping each assertion to its anchor.
    """
    feature_dir = feature_dir.resolve()
    patterns_md = _patterns_md_path()

    # --- Load inputs and FR list (for coverage analysis) ---
    try:
        inputs = load_design_inputs(feature_dir, patterns_md_path=patterns_md)
    except DesignLiftError as e:
        raise click.ClickException(str(e))

    parsed = parse_spec(feature_dir / "spec.md")
    fr_ids = [fr.id for fr in parsed.requirements]
    click.echo(
        f"[parse]   feature {inputs.feature_id!r}, "
        f"{len(fr_ids)} FRs, {len(parsed.user_stories)} user stories"
    )

    # --- Lift via LLM ---
    try:
        provider = AnthropicProvider.from_env(tier=tier)
    except RuntimeError as e:
        raise click.ClickException(
            f"{e}\nTip: copy .env.example to .env and fill in your key."
        )
    click.echo(
        f"[lift]    calling LLM ({provider.name}: tier={provider.tier}, "
        f"model={provider.model})..."
    )
    try:
        pkg = lift_design(
            inputs,
            provider=provider,
            cache_dir=_design_cache_dir(),
            use_cache=(not no_cache),
        )
    except DesignLiftError as e:
        raise click.ClickException(str(e))

    if pkg.cache_hit:
        click.echo(f"[lift]    cache hit (sha={pkg.sha[:12]})")
    else:
        click.echo(f"[lift]    fresh lift (sha={pkg.sha[:12]})")

    # --- Persist the .als + manifest into runs/<feature-id>/ ---
    run_dir = _design_run_dir(inputs.feature_id)
    als_path = write_feature_model(pkg, run_dir)
    click.echo(f"[write]   {als_path}")

    # --- Write cost_log.json BEFORE Alloy runs ---
    # We've already paid for the API call regardless of whether Alloy
    # parses the .als; record the cost up front so an Alloy parse error
    # (e.g. M-small dropping `sig Bool` in E0b sanity) doesn't lose the
    # spend record. Re-written below after mutations to include the D3
    # probe runs if Alloy succeeded.
    cost_log_path = write_cost_log(pkg, run_dir, run_id=inputs.feature_id)
    click.echo(f"[write]   {cost_log_path}")

    # --- Run Alloy on feature_model.als ---
    jar = alloy_jar or default_alloy_jar()
    if not jar.exists():
        raise click.ClickException(
            f"Alloy jar not found at {jar}. Pass --alloy-jar=<path> or place "
            "the jar at tools/alloy.jar."
        )

    click.echo(f"[alloy]   running {jar.name} on {als_path.name}...")
    outcome = run_alloy_file(als_path, alloy_jar=jar, java_bin=java_bin)

    if not outcome.results:
        click.echo(
            "[error]   Alloy produced no parseable verdicts. Raw output:",
            err=True,
        )
        click.echo("--- alloy stdout ---", err=True)
        click.echo(outcome.stdout, err=True)
        click.echo("--- alloy stderr ---", err=True)
        click.echo(outcome.stderr, err=True)
        sys.exit(2)

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

    # --- Additive E0b artefact: alloy_verdicts.json -----------------------
    # `{assertion_name: "PASS"|"FAIL"}` mapping over the canonical
    # (non-mutated) run. Consumed by the AQS scorer in E3.
    alloy_verdicts: dict[str, str] = {
        cr.name: ("PASS" if cr.passed else "FAIL") for cr in outcome.results
    }
    alloy_verdicts_path = run_dir / "alloy_verdicts.json"
    alloy_verdicts_path.write_text(
        json.dumps(alloy_verdicts, indent=2), encoding="utf-8"
    )
    click.echo(f"[write]   {alloy_verdicts_path}")

    # --- Optional: mutation testing ---
    mutation_outcomes: dict[str, dict] = {}
    if not no_mutate:
        mutation_lines, mutation_outcomes = _run_mutation_tests(
            pkg=pkg,
            run_dir=run_dir,
            jar=jar,
            java_bin=java_bin,
        )
        report_lines.extend(mutation_lines)

    # --- Additive E0b artefact: mutation_outcomes.json --------------------
    # Always emitted (empty dict if --no-mutate). Three-valued verdicts
    # per assertion: BIT | VACUOUS_OVERCONSTRAINT | VACUOUS_TAUTOLOGY.
    mutation_outcomes_path = run_dir / "mutation_outcomes.json"
    mutation_outcomes_path.write_text(
        json.dumps(mutation_outcomes, indent=2), encoding="utf-8"
    )
    click.echo(f"[write]   {mutation_outcomes_path}")

    # --- cost_log.json was written pre-Alloy; nothing to refresh here ---

    report_text = "\n".join(report_lines) + "\n"
    click.echo("\n" + report_text)

    # Always also write report.txt to the run dir
    default_report_path = run_dir / "report.txt"
    default_report_path.write_text(report_text, encoding="utf-8")
    click.echo(f"[write]   {default_report_path}")
    if report_out is not None:
        report_out.write_text(report_text, encoding="utf-8")
        click.echo(f"[write]   {report_out}")


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
) -> tuple[list[str], dict[str, dict]]:
    """Apply each mutation_target, re-run Alloy, classify targeted asserts.

    Returns ``(report_lines, mutation_outcomes)``.

    ``mutation_outcomes`` shape (E0b — per EVALUATION_PLAN.md §3.1 D3):

        {
          "<fact_name>": {
            "targeted_asserts": {
              "<assertion>": "BIT"
                            | "VACUOUS_OVERCONSTRAINT"
                            | "VACUOUS_TAUTOLOGY"
            },
            "all_bit": bool
          }
        }

    Per-assertion three-valued verdict:

    - **BIT**  — clearing the named fact + appending ``inject_violation``
      causes the assertion to FAIL on the mutated model. Healthy.
    - **VACUOUS_OVERCONSTRAINT** — assertion still PASSes on the mutant,
      AND when ``inject_violation`` is appended to the *un-mutated* model
      no satisfying instance exists. Some other named fact independently
      enforces the same invariant — defensible engineering, not a bug.
    - **VACUOUS_TAUTOLOGY** — assertion still PASSes on the mutant, AND
      the un-mutated model + ``inject_violation`` IS satisfiable. The
      predicate is tautological: a counterexample exists in the augmented
      universe but the assertion doesn't catch it.

    The report.txt rendering is unchanged from the pre-E0b shape (two-
    valued "BIT" vs "VACUOUS"); the three-valued verdicts flow only into
    ``mutation_outcomes.json`` for the AQS scorer.
    """
    out: list[str] = []
    outcomes: dict[str, dict] = {}
    bar = "=" * 78
    out.append(bar)
    out.append("  Mutation tests  (assertion-strength validation)")
    out.append(bar)
    out.append("")

    mutations = parse_mutation_targets(pkg.manifest)
    if not mutations:
        out.append("  No mutation_targets in manifest. Skipped.")
        out.append("")
        return out, outcomes

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
            outcomes[mut.fact_name] = {
                "targeted_asserts": {},
                "all_bit": False,
                "skipped": True,
                "skip_reason": str(e),
            }
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

        # Per-assertion two-valued verdict for the report; collect VACUOUS
        # names for the (lazy) D3 disambiguation Alloy run below.
        bit_assertions: list[str] = []
        vacuous_assertions: list[str] = []
        for a in mut.asserts_violated:
            cr = by_name.get(a)
            if cr is None:
                verdict = "MISSING"
                # Treat MISSING as VACUOUS for D3 purposes — the assertion
                # didn't fail on the mutant, so it's at least not a clean
                # BIT.
                vacuous_assertions.append(a)
            elif not cr.passed:
                verdict = "FAIL (expected)"
                bit_assertions.append(a)
            else:
                verdict = "PASS (vacuous?)"
                vacuous_assertions.append(a)
            out.append(f"      - {a}: {verdict}")
        # Note: many other assertions may also FAIL once a fact is removed —
        # that's normal collateral damage and not a problem. We only validate
        # the targeted assertions.
        if not outcome.results:
            out.append(
                "    WARNING: Alloy returned no verdicts for this mutant; "
                "stderr below."
            )
            out.append("    " + outcome.stderr.replace("\n", "\n    ")[:400])
        out.append("")

        # ---- D3 disambiguation -----------------------------------------
        # Only runs when at least one targeted assertion was VACUOUS on
        # the mutant. Costs ~3 extra seconds per target (one Alloy run).
        three_valued: dict[str, str] = {a: "BIT" for a in bit_assertions}
        if vacuous_assertions and mut.inject_violation:
            d3_verdict = _d3_over_constraint_check(
                feature_model_als=pkg.feature_model_als,
                inject_violation=mut.inject_violation,
                fact_name=mut.fact_name,
                run_dir=run_dir,
                jar=jar,
                java_bin=java_bin,
            )
            for a in vacuous_assertions:
                three_valued[a] = d3_verdict
        else:
            # No inject_violation to probe with → can't disambiguate.
            # Default to OVERCONSTRAINT (the more conservative 0.5
            # outcome) for any remaining VACUOUS assertions; this
            # matches the prior behaviour of "VACUOUS = not-zero" and
            # avoids penalising lifts that omit the snippet.
            for a in vacuous_assertions:
                three_valued.setdefault(a, "VACUOUS_OVERCONSTRAINT")

        all_bit = bool(three_valued) and all(
            v == "BIT" for v in three_valued.values()
        )
        outcomes[mut.fact_name] = {
            "targeted_asserts": three_valued,
            "all_bit": all_bit,
        }

        verdict_line = "ASSERTIONS BIT" if all_bit else "ASSERTION VACUOUS"
        summary_lines.append(
            f"  - {mut.fact_name}: {verdict_line} "
            f"({', '.join(mut.asserts_violated)})"
        )

    out.append("  Mutation summary")
    out.append("  " + "-" * 76)
    out.extend(summary_lines)
    out.append("")
    return out, outcomes


# Probe assertion used by the D3 over-constraint check. `some none` is
# always false, so a counterexample to this assertion exists iff *any*
# instance satisfies the model — i.e., the probe doubles as a
# satisfiability check that re-uses the existing `check` parser in
# runner.py without needing a `run` keyword.
_D3_PROBE_NAME = "__D3_OverConstraintProbe"
_D3_PROBE_SCOPE = 5
_D3_PROBE_SNIPPET = (
    f"// === D3 over-constraint probe (validator-appended) ===\n"
    f"assert {_D3_PROBE_NAME} {{ some none }}\n"
    f"check {_D3_PROBE_NAME} for {_D3_PROBE_SCOPE}\n"
)


def _d3_over_constraint_check(
    *,
    feature_model_als: str,
    inject_violation: str,
    fact_name: str,
    run_dir: Path,
    jar: Path,
    java_bin: str,
) -> str:
    """Run the D3 disambiguation probe and return a three-valued verdict.

    Takes the **un-mutated** model, appends only the ``inject_violation``
    snippet (the named fact is left intact), appends a satisfiability
    probe, then runs Alloy.

    Returns:
      - ``"VACUOUS_OVERCONSTRAINT"`` if the probe is UNSAT (no instance
        satisfies the augmented model — some other fact independently
        forbids the violation).
      - ``"VACUOUS_TAUTOLOGY"`` if the probe is SAT (an instance exists
        but the targeted assertion still passes — the predicate is
        tautological).

    On parse failure or missing probe verdict, defaults to
    ``VACUOUS_OVERCONSTRAINT`` (the more conservative 0.5 outcome).
    """
    augmented = (
        feature_model_als.rstrip()
        + "\n\n// === D3 inject_violation (validator-appended) ===\n"
        + inject_violation.strip()
        + "\n\n"
        + _D3_PROBE_SNIPPET
    )
    probe_path = run_dir / f"d3_probe_{fact_name}.als"
    probe_path.write_text(augmented, encoding="utf-8")

    outcome = run_alloy_file(probe_path, alloy_jar=jar, java_bin=java_bin)
    cr = outcome.by_name().get(_D3_PROBE_NAME)
    if cr is None:
        return "VACUOUS_OVERCONSTRAINT"
    # cr.passed == True  → check returned UNSAT → no counterexample to
    # `some none` exists → no instance satisfies the model → OVERCONSTRAINT.
    # cr.passed == False → SAT → some instance exists → TAUTOLOGY.
    return "VACUOUS_OVERCONSTRAINT" if cr.passed else "VACUOUS_TAUTOLOGY"


if __name__ == "__main__":
    main()
