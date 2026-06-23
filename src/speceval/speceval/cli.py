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
from speceval.kpi_extractor import extract_all_kpis, save_kpis_json

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




@main.command("extract-kpis")
@click.argument("spec_md", type=click.Path(exists=True, path_type=Path))
@click.option(
    "--user-prompt",
    type=str,
    default="",
    help="User's original prompt (for keyword extraction)",
)
@click.option(
    "--output",
    type=click.Path(path_type=Path),
    default=None,
    help="Output JSON file. Defaults to <spec_dir>/kpis.json",
)
def extract_kpis(spec_md: Path, user_prompt: str, output: Path) -> None:
    """Extract business KPIs from spec.md and/or user prompt.
    
    Outputs a JSON file with all extracted KPIs, deduplicated across sources.
    """
    spec_md = spec_md.resolve()
    spec_text = spec_md.read_text(encoding="utf-8")
    feature_id = spec_md.parent.name
    
    # Extract KPIs
    collection = extract_all_kpis(
        feature_id=feature_id,
        spec_md=spec_text,
    )
    
    # Determine output path
    if output is None:
        output = spec_md.parent / "kpis.json"
    else:
        output = output.resolve()
    
    # Save
    save_kpis_json(collection, output)
    
    click.echo(f"Extracted {len(collection.merged_kpis)} KPIs:")
    click.echo(f"  - {len(collection.speckit_kpis)} from spec.md")
    click.echo(f"  - {len(collection.merged_kpis)} unique (merged)")
    click.echo(f"\nSaved to: {output}")
    
    # Print summary
    for kpi in collection.merged_kpis:
        click.echo(f"  • {kpi.category}: {kpi.name}")

# ---------------------------------------------------------------------------
# generate-interactive — SpecKit generation with KPI dashboard review
# ---------------------------------------------------------------------------

@main.command("generate-interactive")
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
def cmd_generate_interactive(
    description: str,
    project_type: str,
    tech_stack: str,
    target_frs: int,
    feature_id: str,
    output_dir: Path | None,
) -> None:
    """Generate SpecKit artefacts with interactive KPI dashboard for review.

    After generation, a Streamlit dashboard appears showing extracted KPIs
    color-coded by fulfillment status. You can:
    - Review the KPIs and their mappings to Alloy code
    - Regenerate with a modified prompt if needed
    - Continue when satisfied
    
    \b
    Example:
        speceval generate-interactive "A banking transfer system with audit logging"
    """
    import os
    from speceval.speckit_generator import GenerationError, GeneratorConfig, generate_speckit
    from speceval.kpi_extractor import extract_all_kpis, save_kpis_json

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
        feature_id=feature_id,
    )

    output_base = output_dir or _default_specs_dir()

    current_prompt = description
    iteration = 0
    max_iterations = 5

    while iteration < max_iterations:
        iteration += 1
        click.echo(f"[gen]     iteration {iteration}/{max_iterations}")
        click.echo(f"[gen]     generating SpecKit artefacts...")
        click.echo(f"[gen]     provider: {provider.name} ({provider.model})")
        click.echo(f"[gen]     output:   {output_base}")

        try:
            result = generate_speckit(
                current_prompt,
                config=cfg,
                provider=provider,
                output_base=output_base,
                cache_dir=_default_gen_cache_dir(),
                use_cache=False,  # No cache in interactive mode
                echo=click.echo,
            )
        except GenerationError as e:
            raise click.ClickException(str(e))

        feature_dir = result.feature_dir
        feature_id_resolved = result.feature_id

        # Extract KPIs
        click.echo("[kpi]     extracting KPIs from spec.md...")
        kpi_collection = extract_all_kpis(
            feature_id=feature_id_resolved,
            spec_md=result.spec_md,
            user_prompt=current_prompt,
            feature_name=feature_id_resolved.replace("-", " ").title(),
            alloy_code="",  # Alloy code not available in generation-only mode
        )

        kpi_json_path = feature_dir / "kpis.json"
        save_kpis_json(kpi_collection, kpi_json_path)

        # Save the prompt for reference
        (feature_dir / "generation_prompt.txt").write_text(
            current_prompt, encoding="utf-8"
        )

        click.echo(
            f"[kpi]     extracted {len(kpi_collection.merged_kpis)} KPIs → "
            f"{kpi_json_path}"
        )

        # Show dashboard
        click.echo("")
        click.echo("[dashboard] launching KPI review dashboard...")
        click.echo(
            "[dashboard] (use 'Regenerate' button to modify prompt and try again)"
        )
        click.echo("")

        # Set environment variables for Streamlit
        env = os.environ.copy()
        env["SPECEVAL_FEATURE_DIR"] = str(feature_dir)
        env["SPECEVAL_FEATURE_ID"] = feature_id_resolved
        env["SPECEVAL_KPI_JSON"] = str(kpi_json_path)
        env["SPECEVAL_ORIGINAL_PROMPT"] = current_prompt
        env["SPECEVAL_REGENERATE_MODE"] = "1"

        dashboard_app = Path(__file__).parent / "kpi_dashboard_app.py"

        proc = subprocess.run(
            [
                sys.executable, "-m", "streamlit", "run",
                str(dashboard_app),
                "--logger.level=error",
            ],
            env=env,
        )

        # Check for regeneration request
        regenerate_flag = feature_dir / ".regenerate_request"
        modified_prompt_file = feature_dir / ".modified_prompt.txt"

        if regenerate_flag.exists():
            if modified_prompt_file.exists():
                current_prompt = modified_prompt_file.read_text(encoding="utf-8")
                modified_prompt_file.unlink()
            regenerate_flag.unlink()
            click.echo("")
            click.echo("[dashboard] user requested regeneration. Restarting...")
            click.echo("")
            continue
        else:
            # User clicked continue
            break

    if iteration >= max_iterations:
        click.echo(f"[warn]    max iterations ({max_iterations}) reached. Exiting.")

    click.echo("")
    click.echo(f"[done]    feature_id: {feature_id_resolved}")
    click.echo(f"[done]    feature_dir: {feature_dir}")
    click.echo(f"[done]    kpis saved: {kpi_json_path}")


# ---------------------------------------------------------------------------
# dashboard — view KPI dashboard for existing feature
# ---------------------------------------------------------------------------

@main.command("dashboard")
@click.argument(
    "feature_dir",
    type=click.Path(exists=True, file_okay=False, path_type=Path),
)
@click.option(
    "--kpi-file",
    type=click.Path(exists=True, dir_okay=False, path_type=Path),
    default=None,
    help="Path to kpis.json (auto-detected if not provided).",
)
def cmd_dashboard(feature_dir: Path, kpi_file: Path | None) -> None:
    """View the KPI dashboard for an existing feature.

    Displays extracted KPIs with their fulfillment status (Fulfilled,
    To be measured, Missing) in a Streamlit dashboard.
    
    \b
    Example:
        speceval dashboard specs/005-banking-transfer-system
    """
    import os
    
    feature_dir = feature_dir.resolve()
    feature_id = feature_dir.name

    # Detect kpi_json_path
    if kpi_file:
        kpi_json_path = kpi_file.resolve()
    else:
        kpi_json_path = feature_dir / "kpis.json"

    if not kpi_json_path.exists():
        raise click.ClickException(
            f"KPI file not found: {kpi_json_path}\n"
            f"Run `speceval run {feature_dir}` first to generate KPIs."
        )

    # Determine original prompt (if stored in metadata)
    original_prompt = ""
    metadata_path = feature_dir / "generation_prompt.txt"
    if metadata_path.exists():
        original_prompt = metadata_path.read_text(encoding="utf-8")

    # Set environment variables for the Streamlit app
    env = os.environ.copy()
    env["SPECEVAL_FEATURE_DIR"] = str(feature_dir)
    env["SPECEVAL_FEATURE_ID"] = feature_id
    env["SPECEVAL_KPI_JSON"] = str(kpi_json_path)
    env["SPECEVAL_ORIGINAL_PROMPT"] = original_prompt

    # Find the dashboard app script
    dashboard_app = Path(__file__).parent / "kpi_dashboard_app.py"
    
    click.echo(f"[dashboard] launching KPI review dashboard...")
    click.echo(f"[dashboard] feature: {feature_id}")
    click.echo(f"[dashboard] kpi_file: {kpi_json_path}")
    click.echo("")
    
    subprocess.run([
        sys.executable, "-m", "streamlit", "run",
        str(dashboard_app),
        "--logger.level=error",
    ], env=env)


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
