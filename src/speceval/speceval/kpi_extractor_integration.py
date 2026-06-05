"""Integration Guide: Using kpi_extractor in your speceval pipeline."""

# ============================================================================
# INTEGRATION POINT 1: After speckit_generator.generate_speckit()
# ============================================================================
# Location: In cli.py `generate` command or in your custom pipeline script

from pathlib import Path
from speceval.speckit_generator import generate_speckit, GeneratorConfig
from speceval.providers.anthropic import AnthropicProvider
from speceval.kpi_extractor import extract_all_kpis, save_kpis_json


def generate_with_kpis(
    description: str,
    feature_id: str,
    specs_dir: Path,
    cache_dir: Path,
    provider: AnthropicProvider,
):
    """Generate SpecKit artefacts + extract KPIs to JSON."""
    
    # Step 1: Generate SpecKit artefacts (spec.md, data-model.md, http-api.md)
    print(f"[gen]     generating SpecKit for {feature_id}...")
    result = generate_speckit(
        description=description,
        config=GeneratorConfig(
            feature_id=feature_id,
            project_type="web-api",
            target_fr_count=10,
        ),
        provider=provider,
        output_base=specs_dir,
        cache_dir=cache_dir,
        use_cache=True,
    )
    
    # Step 2: Extract KPIs from both spec.md and user prompt
    print(f"[kpi]     extracting KPIs...")
    kpi_collection = extract_all_kpis(
        feature_id=result.feature_id,
        spec_md=result.spec_md,
        user_prompt=description,
        feature_name=result.feature_id.replace("-", " ").title(),
    )
    
    # Step 3: Save KPIs to JSON
    kpi_output = result.feature_dir / "kpis.json"
    save_kpis_json(kpi_collection, kpi_output)
    
    print(f"[kpi]     saved {len(kpi_collection.merged_kpis)} KPIs → {kpi_output}")
    print(f"[kpi]     - {len(kpi_collection.speckit_kpis)} from spec.md")
    print(f"[kpi]     - {len(kpi_collection.user_prompt_kpis)} from user prompt")
    
    return result, kpi_collection


# ============================================================================
# INTEGRATION POINT 2: Add CLI command for KPI extraction standalone
# ============================================================================
# Add this to cli.py

import click
from speceval.kpi_extractor import extract_all_kpis, save_kpis_json


@click.command()
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
        user_prompt=user_prompt,
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
    click.echo(f"  - {len(collection.user_prompt_kpis)} from user prompt")
    click.echo(f"  - {len(collection.merged_kpis)} unique (merged)")
    click.echo(f"\nSaved to: {output}")
    
    # Print summary
    for kpi in collection.merged_kpis:
        click.echo(f"  • {kpi.category}: {kpi.name}")


# Add to the @click.group() in cli.py:
# @cli.add_command(extract_kpis)


# ============================================================================
# INTEGRATION POINT 3: In unified_run.py for full pipeline
# ============================================================================
# Add this function to unified_run.py

from speceval.kpi_extractor import extract_all_kpis, save_kpis_json


def extract_kpis_for_run(
    feature_dir: Path,
    user_prompt: str = "",
    *,
    echo: Callable[[str], Any] | None = None,
) -> dict:
    """Extract KPIs from a feature directory's spec.md."""
    if echo is None:
        def echo(_msg):  # noqa: ARG001
            return None
    
    spec_md_path = feature_dir / "spec.md"
    if not spec_md_path.exists():
        echo(f"[kpi-extract]     spec.md not found at {spec_md_path}")
        return {}
    
    spec_md = spec_md_path.read_text(encoding="utf-8")
    feature_id = feature_dir.name
    
    echo(f"[kpi-extract]     extracting KPIs from {feature_id}...")
    collection = extract_all_kpis(
        feature_id=feature_id,
        spec_md=spec_md,
        user_prompt=user_prompt,
    )
    
    # Save to JSON
    kpi_output = feature_dir / "kpis.json"
    save_kpis_json(collection, kpi_output)
    
    echo(
        f"[kpi-extract]     {len(collection.merged_kpis)} KPIs extracted "
        f"({len(collection.speckit_kpis)} from spec, "
        f"{len(collection.user_prompt_kpis)} from prompt)"
    )
    
    return collection.to_dict()


# ============================================================================
# INTEGRATION POINT 4: Example standalone script
# ============================================================================

if __name__ == "__main__":
    from pathlib import Path
    from speceval.kpi_extractor import extract_all_kpis, save_kpis_json
    
    # Example: extract KPIs from an existing feature directory
    feature_dir = Path("specs/005-banking-transfer-system")
    spec_md_path = feature_dir / "spec.md"
    
    if spec_md_path.exists():
        spec_md = spec_md_path.read_text(encoding="utf-8")
        
        # Optional: user prompt for keyword extraction
        user_prompt = """
        We need a system that handles bank transfers securely with complete
        audit logging. The system must ensure success rates are high and
        audit trails are immutable.
        """
        
        collection = extract_all_kpis(
            feature_id=feature_dir.name,
            spec_md=spec_md,
            user_prompt=user_prompt,
        )
        
        # Save results
        output_path = feature_dir / "kpis.json"
        save_kpis_json(collection, output_path)
        
        print(f"✓ Saved {len(collection.merged_kpis)} KPIs to {output_path}")
        print("\nMerged KPI list:")
        for kpi in collection.merged_kpis:
            print(f"  {kpi.category:20s} → {kpi.name}")
