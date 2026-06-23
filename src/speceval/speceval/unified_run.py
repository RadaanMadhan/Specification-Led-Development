"""speceval.unified_run — orchestrator for the integrated MVP.

Runs both halves in-process:
  1. Structural verification via Alloy (run_verification)
  2. WAF-derived runtime KPI derivation (kpi_agent, imported dynamically)

Returns a combined result dict that unified_reporter formats into reports.
"""

from __future__ import annotations

import importlib
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

from speceval.verify import run_verification
from speceval.kpi_extractor import extract_all_kpis, save_kpis_json

def _project_root() -> Path:
    """The speceval project root, i.e. src/speceval/."""
    return Path(__file__).resolve().parent.parent


def _kpi_agent_dir() -> Path:
    """The sibling kpi folder, i.e. src/kpi/."""
    return _project_root().parent / "kpi"


def _load_kpi_agent_module():
    """Add kpi/ to sys.path and import the `kpi_agent` module."""
    kpi_dir = _kpi_agent_dir()
    if not kpi_dir.is_dir():
        raise FileNotFoundError(
            f"KPI-agent folder not found at {kpi_dir}. "
            "Was src/ set up correctly?"
        )
    kpi_dir_str = str(kpi_dir)
    if kpi_dir_str not in sys.path:
        sys.path.insert(0, kpi_dir_str)
    if "kpi_agent" in sys.modules:
        return importlib.reload(sys.modules["kpi_agent"])
    return importlib.import_module("kpi_agent")


def run_kpi_derivation(
    spec_md_path: Path,
    *,
    echo: Callable[[str], Any] | None = None,
) -> dict:
    """Drive the WAF-KPI derivation pipeline for one spec.md."""
    if echo is None:
        def echo(_msg):  # noqa: ARG001
            return None

    spec_md_path = Path(spec_md_path).resolve()
    if not spec_md_path.exists():
        raise FileNotFoundError(f"spec.md not found at {spec_md_path}")

    echo(f"[kpi]     importing kpi_agent from {_kpi_agent_dir()}")
    kpi_agent = _load_kpi_agent_module()

    echo(f"[kpi]     parsing spec at {spec_md_path}")
    spec = kpi_agent.parse_spec(spec_md_path)
    frs = spec.get("frs", []) or []
    if not frs:
        raise RuntimeError(
            f"No FR-NNN lines found in {spec_md_path}. "
            "Check the spec format."
        )
    echo(f"[kpi]     {len(frs)} FRs found in {spec.get('feature_name', '?')!r}")

    echo("[kpi]     loading WAF records + (cached) embeddings...")
    records = kpi_agent.load_waf_records()
    waf_embeddings = kpi_agent.load_waf_embeddings(records)

    spec_id = f"spec-{datetime.now().strftime('%Y%m%d-%H%M%S')}"

    gqm_records: list[dict] = []
    kpi_records: list[dict] = []
    fr_to_gqm: dict[str, str] = {}
    fr_to_kpis: dict[str, list[dict]] = {}

    for fr in frs:
        fr_id = fr["id"]
        requirement = f"{fr_id}: {fr['text']}"
        echo(f"[kpi]     deriving for {fr_id}...")
        matches = kpi_agent.search_waf(requirement, records, waf_embeddings)
        gqm_record, kpi_rows = kpi_agent.derive_gqm_and_kpi(
            requirement, matches, spec_id
        )
        gqm_records.append(gqm_record)
        kpi_records.extend(kpi_rows)
        fr_to_gqm[fr_id] = gqm_record["id"]
        fr_to_kpis[fr_id] = kpi_rows

    echo(
        f"[kpi]     done: {len(gqm_records)} GQM chains, "
        f"{len(kpi_records)} KPI rows"
    )

    return {
        "spec_id": spec_id,
        "feature_name": spec.get("feature_name"),
        "frs": frs,
        "gqm_records": gqm_records,
        "kpi_records": kpi_records,
        "fr_to_gqm": fr_to_gqm,
        "fr_to_kpis": fr_to_kpis,
    }


def _default_gen_cache_dir() -> Path:
    p = _project_root() / "cache" / "speckit_gen"
    p.mkdir(parents=True, exist_ok=True)
    return p


def _default_specs_dir() -> Path:
    return _project_root().parent.parent / "specs"


def run_unified(
    feature_dir: Path | None,
    *,
    alloy_jar: Path | None = None,
    java_bin: str = "java",
    no_cache: bool = False,
    no_mutate: bool = False,
    skip_alloy: bool = False,
    skip_kpi: bool = False,
    description: str | None = None,
    gen_config: Any | None = None,
    echo: Callable[[str], Any] | None = None,
) -> dict:
    """Run both halves on one Speckit feature folder and combine results.

    If `description` is provided and `feature_dir` is None, Phase 0 runs
    first to generate the artefacts via LLM.
    """
    if echo is None:
        def echo(_msg):  # noqa: ARG001
            return None

    generation_result = None

    # --- Phase 0: generate artefacts if description is provided ---
    if description is not None and feature_dir is None:
        from speceval.providers.anthropic import AnthropicProvider
        from speceval.speckit_generator import generate_speckit

        echo("=" * 60)
        echo("  [unified] phase 0 — SpecKit artefact generation")
        echo("=" * 60)

        provider = AnthropicProvider.from_env()
        gen_result = generate_speckit(
            description,
            config=gen_config,
            provider=provider,
            output_base=_default_specs_dir(),
            cache_dir=_default_gen_cache_dir(),
            use_cache=(not no_cache),
            echo=echo,
        )
        feature_dir = gen_result.feature_dir
        from dataclasses import asdict
        generation_result = {
            "feature_id": gen_result.feature_id,
            "description": description,
            "config": {
                "project_type": gen_result.config.project_type,
                "tech_stack": gen_result.config.tech_stack,
                "target_fr_count": gen_result.config.target_fr_count,
            },
            "cache_hit": gen_result.cache_hit,
            "sha": gen_result.sha,
            "model": gen_result.model,
            "feature_dir": str(gen_result.feature_dir),
            "artefacts": ["spec.md", "data-model.md", "contracts/http-api.md"],
            "usage": [asdict(p) for p in gen_result.usage],
        }

    if feature_dir is None:
        raise FileNotFoundError(
            "No feature directory provided and no description for generation."
        )

    feature_dir = Path(feature_dir).resolve()
    if not feature_dir.is_dir():
        raise FileNotFoundError(f"feature folder not found: {feature_dir}")

    alloy_result: dict | None = None
    if not skip_alloy:
        echo("=" * 60)
        echo("  [unified] half 1 — structural verification via Alloy")
        echo("=" * 60)
        alloy_result = run_verification(
            feature_dir,
            alloy_jar=alloy_jar,
            no_cache=no_cache,
            no_mutate=no_mutate,
            java_bin=java_bin,
            echo=echo,
        )

    kpi_result: dict | None = None
    if not skip_kpi:
        echo("=" * 60)
        echo("  [unified] half 2 — WAF-derived runtime KPI targets")
        echo("=" * 60)
        kpi_result = run_kpi_derivation(
            feature_dir / "spec.md",
            echo=echo,
        )

    result = {
        "feature_id": feature_dir.name,
        "feature_dir": feature_dir,
        "alloy": alloy_result,
        "kpi": kpi_result,
    }
    if generation_result is not None:
        result["generation"] = generation_result

    return result


def extract_kpis_for_run(
    feature_dir: Path,
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
    )
    
    # Save to JSON
    kpi_output = feature_dir / "kpis.json"
    save_kpis_json(collection, kpi_output)
    
    echo(
        f"[kpi-extract]     {len(collection.merged_kpis)} KPIs extracted "
        f"({len(collection.speckit_kpis)} from spec)"
    )
    
    return collection.to_dict()