"""speceval.cli — command-line entry point.

Commands: run, generate, doctor.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import click

from speceval.lifter_design import DesignLiftError
from speceval.providers.anthropic import AnthropicProvider
from speceval.runner import (
    default_alloy_dir,
    default_alloy_jar,
    run_alloy,
)
from speceval.verify import get_run_dir


def _project_root() -> Path:
    """The speceval package root (src/speceval/)."""
    return Path(__file__).resolve().parent.parent


def _default_gen_cache_dir() -> Path:
    p = _project_root() / "cache" / "speckit_gen"
    p.mkdir(parents=True, exist_ok=True)
    return p


def _default_specs_dir() -> Path:
    return _project_root().parent.parent / "specs"


@click.group()
@click.version_option("0.1.0", prog_name="speceval")
@click.option(
    "--alloy-jar",
    type=click.Path(exists=True, dir_okay=False, path_type=Path),
    default=None,
    help="Path to the Alloy Analyzer jar. Defaults to tools/alloy.jar.",
)
@click.option(
    "--java-bin",
    default="java",
    help="Java executable to use (default: `java` on PATH).",
)
@click.pass_context
def main(ctx, alloy_jar, java_bin) -> None:
    """Specification-led evaluation: lift SpecKit artefacts into Alloy and verify."""
    ctx.ensure_object(dict)
    ctx.obj["alloy_jar"] = alloy_jar
    ctx.obj["java_bin"] = java_bin


# ---------------------------------------------------------------------------
# run — unified verification (Alloy + KPI)
# ---------------------------------------------------------------------------

@main.command("run")
@click.argument(
    "feature_dir",
    type=click.Path(exists=True, file_okay=False, path_type=Path),
    required=False,
    default=None,
)
@click.option(
    "--from-description",
    "from_description",
    default=None,
    type=str,
    help="Generate SpecKit artefacts from this description before verification.",
)
@click.option(
    "--project-type",
    default="web-api",
    help="Project type for generation (used with --from-description).",
)
@click.option(
    "--tech-stack",
    default="",
    help="Tech stack for generation (used with --from-description).",
)
@click.option(
    "--target-frs",
    default=10,
    type=int,
    help="Target FR count for generation (used with --from-description).",
)
@click.option(
    "--gen-feature-id",
    default="",
    help="Override auto-derived feature ID for generation.",
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
    help="Skip the mutation-test pass on the Alloy half.",
)
@click.option(
    "--skip-alloy",
    is_flag=True,
    default=False,
    help="Run only the WAF-KPI half (skip Alloy structural verification).",
)
@click.option(
    "--skip-kpi",
    is_flag=True,
    default=False,
    help="Run only the Alloy structural half (skip WAF-KPI derivation).",
)
@click.option(
    "--report-out",
    type=click.Path(dir_okay=False, path_type=Path),
    default=None,
    help="Optional extra path to write the unified Markdown report to.",
)
@click.pass_context
def cmd_run(
    ctx,
    feature_dir: Path | None,
    from_description: str | None,
    project_type: str,
    tech_stack: str,
    target_frs: int,
    gen_feature_id: str,
    no_cache: bool,
    no_mutate: bool,
    skip_alloy: bool,
    skip_kpi: bool,
    report_out: Path | None,
) -> None:
    """Run unified verification (Alloy + KPI) on a Speckit feature folder.

    Either provide FEATURE_DIR (path to an existing Speckit feature folder)
    or use --from-description to generate artefacts first.

    \b
    Examples:
      speceval run specs/002-bank-transfer-audit
      speceval run --from-description "A banking transfer system"
      speceval run specs/002-bank-transfer-audit --skip-kpi
      speceval run specs/002-bank-transfer-audit --skip-alloy
    """
    if feature_dir is None and from_description is None:
        raise click.ClickException(
            "Either provide FEATURE_DIR as an argument or use "
            "--from-description to generate artefacts."
        )

    alloy_jar = ctx.obj["alloy_jar"]
    java_bin = ctx.obj["java_bin"]

    from speceval.unified_run import run_unified
    from speceval.unified_reporter import write_unified_report

    # Build generation config if --from-description is used
    gen_config = None
    description = None
    if from_description is not None:
        from speceval.speckit_generator import GeneratorConfig
        description = from_description
        gen_config = GeneratorConfig(
            project_type=project_type,
            tech_stack=tech_stack,
            target_fr_count=target_frs,
            feature_id=gen_feature_id,
        )

    resolved_dir = feature_dir.resolve() if feature_dir is not None else None
    try:
        result = run_unified(
            resolved_dir,
            alloy_jar=alloy_jar,
            java_bin=java_bin,
            no_cache=no_cache,
            no_mutate=no_mutate,
            skip_alloy=skip_alloy,
            skip_kpi=skip_kpi,
            description=description,
            gen_config=gen_config,
            echo=click.echo,
        )
    except (DesignLiftError, FileNotFoundError, RuntimeError) as e:
        raise click.ClickException(str(e))

    run_dir = get_run_dir(result["feature_id"])
    md_path, txt_path = write_unified_report(result, out_dir=run_dir)
    click.echo("")
    click.echo(f"[write]   {md_path}")
    click.echo(f"[write]   {txt_path}")

    if report_out is not None:
        from speceval.unified_reporter import render_unified_report_md
        report_out.write_text(render_unified_report_md(result), encoding="utf-8")
        click.echo(f"[write]   {report_out}")


# ---------------------------------------------------------------------------
# generate — standalone SpecKit artefact generation
# ---------------------------------------------------------------------------

@main.command("generate")
@click.argument("description")
@click.option(
    "--project-type",
    default="web-api",
    help="Project type hint for the generator (default: web-api).",
)
@click.option(
    "--tech-stack",
    default="",
    help="Tech stack hint (e.g. 'Python, FastAPI, PostgreSQL').",
)
@click.option(
    "--target-frs",
    default=10,
    type=int,
    help="Target number of functional requirements to generate (default: 10).",
)
@click.option(
    "--feature-name",
    default="",
    help="Override the feature name in the generated spec.",
)
@click.option(
    "--feature-id",
    default="",
    help="Override the auto-derived feature ID (e.g. '004-my-feature').",
)
@click.option(
    "--output-dir",
    type=click.Path(path_type=Path),
    default=None,
    help="Base output directory for specs (default: <project-root>/specs/).",
)
@click.option(
    "--no-cache",
    is_flag=True,
    default=False,
    help="Force fresh LLM generation even if a cached result is available.",
)
def cmd_generate(
    description: str,
    project_type: str,
    tech_stack: str,
    target_frs: int,
    feature_name: str,
    feature_id: str,
    output_dir: Path | None,
    no_cache: bool,
) -> None:
    """Generate SpecKit artefacts (spec.md, data-model.md, http-api.md) from a description.

    DESCRIPTION is a free-text description of the feature or project.
    The generated artefacts are written to specs/<feature-id>/ and can be
    fed directly into `speceval run`.
    """
    from speceval.speckit_generator import (
        GenerationError,
        GeneratorConfig,
        generate_speckit,
    )

    try:
        provider = AnthropicProvider.from_env()
    except RuntimeError as e:
        raise click.ClickException(
            f"{e}\nTip: copy .env.example to .env and fill in your key."
        )

    cfg = GeneratorConfig(
        project_type=project_type,
        tech_stack=tech_stack,
        target_fr_count=target_frs,
        feature_name=feature_name,
        feature_id=feature_id,
    )

    output_base = output_dir or _default_specs_dir()

    click.echo(f"[gen]     generating SpecKit artefacts...")
    click.echo(f"[gen]     provider: {provider.name} ({provider.model})")
    click.echo(f"[gen]     output:   {output_base}")
    try:
        result = generate_speckit(
            description,
            config=cfg,
            provider=provider,
            output_base=output_base,
            cache_dir=_default_gen_cache_dir(),
            use_cache=(not no_cache),
            echo=click.echo,
        )
    except GenerationError as e:
        raise click.ClickException(str(e))

    click.echo("")
    click.echo(f"[done]    feature_id: {result.feature_id}")
    click.echo(f"[done]    feature_dir: {result.feature_dir}")
    click.echo(f"[done]    cache {'hit' if result.cache_hit else 'miss'} (sha={result.sha[:12]})")
    click.echo(f"[done]    artefacts:")
    click.echo(f"            spec.md")
    click.echo(f"            data-model.md")
    click.echo(f"            contracts/http-api.md")
    if result.usage:
        click.echo("")
        click.echo("[usage]   token consumption:")
        total_in = total_out = 0
        total_time = 0.0
        for p in result.usage:
            click.echo(
                f"            {p.artefact:<20s} "
                f"{p.input_tokens:>6,}in  {p.output_tokens:>6,}out  "
                f"{p.elapsed_seconds:>5.1f}s  {p.stop_reason}"
            )
            total_in += p.input_tokens
            total_out += p.output_tokens
            total_time += p.elapsed_seconds
        click.echo(
            f"            {'TOTAL':<20s} "
            f"{total_in:>6,}in  {total_out:>6,}out  "
            f"{total_time:>5.1f}s"
        )


# ---------------------------------------------------------------------------
# doctor — check toolchain (Java, Alloy jar)
# ---------------------------------------------------------------------------

@main.command("doctor")
@click.pass_context
def cmd_doctor(ctx) -> None:
    """Check the toolchain: Java, Alloy jar, and bundled test snapshots."""
    alloy_jar = ctx.obj["alloy_jar"]
    java_bin = ctx.obj["java_bin"]

    # --- Check Java ---
    click.echo("[doctor]  checking Java...")
    try:
        proc = subprocess.run(
            [java_bin, "-version"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        version_line = (proc.stderr or proc.stdout or "").strip().splitlines()[0]
        click.echo(f"[doctor]  Java OK: {version_line}")
    except FileNotFoundError:
        click.echo(
            f"[doctor]  Java NOT FOUND at '{java_bin}'. "
            "Install Java or pass --java-bin.",
            err=True,
        )
        sys.exit(1)
    except Exception as e:
        click.echo(f"[doctor]  Java check failed: {e}", err=True)
        sys.exit(1)

    # --- Check Alloy jar ---
    jar = alloy_jar or default_alloy_jar()
    if not jar.exists():
        click.echo(
            f"[doctor]  Alloy jar NOT FOUND at {jar}. "
            "Pass --alloy-jar=<path> or place the jar at tools/alloy.jar.",
            err=True,
        )
        sys.exit(1)
    click.echo(f"[doctor]  Alloy jar OK: {jar}")

    # --- Run bundled test snapshots ---
    for example in ("tiny_passing_snapshot.als", "tiny_failing_snapshot.als"):
        snap = _project_root() / "examples" / example
        if not snap.exists():
            click.echo(f"[doctor]  {example}: file not found at {snap}", err=True)
            continue
        click.echo(f"\n=== {example} ===")
        outcome = run_alloy(
            domain_als=default_alloy_dir() / "domain.als",
            kpi_library_als=default_alloy_dir() / "kpi_library.als",
            snapshot_als=snap,
            alloy_jar=jar,
            java_bin=java_bin,
        )
        for cr in outcome.results:
            verdict = "PASS" if cr.passed else "FAIL"
            click.echo(f"  {cr.name:12s}  {verdict}")
        if outcome.returncode != 0:
            click.echo(f"  (alloy exit code: {outcome.returncode})")

    click.echo("")
    click.echo("[doctor]  all checks passed.")


if __name__ == "__main__":
    main()
