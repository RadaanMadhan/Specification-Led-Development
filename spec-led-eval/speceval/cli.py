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
from speceval.parser import ParsedSpec, parse_spec, summarise
from speceval.providers.anthropic import AnthropicProvider
from speceval.reporter import ReportInputs, print_report
from speceval.runner import (
    default_alloy_dir,
    default_alloy_jar,
    run_alloy,
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


if __name__ == "__main__":
    main()
