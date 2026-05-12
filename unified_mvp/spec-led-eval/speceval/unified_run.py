"""speceval.unified_run — orchestrator for the integrated MVP.

Runs both halves of Microsoft Project 9 in-process:

  1. Structural verification via Alloy
     (this package's `run_verification(feature_dir)` → dict)
  2. WAF-derived runtime KPI derivation
     (the `kpi_agent` module in sibling folder `kpi-agent/`,
      imported via sys.path injection)

Returns a single combined result dict that `unified_reporter` formats into
unified_report.md (and .txt). Both halves keep their own caches; no
intermediate disk round-trip between halves.

Note: this orchestrator MUST be run from a machine that can reach
api.anthropic.com (Alloy half) and api.openai.com (KPI half). Cached
LLM results in the copied folders make repeat runs fast and offline.
"""

from __future__ import annotations

import importlib
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Callable


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

def _project_root() -> Path:
    """The copied spec-led-eval root, i.e. unified_mvp/spec-led-eval/."""
    return Path(__file__).resolve().parent.parent


def _kpi_agent_dir() -> Path:
    """The sibling kpi-agent folder, i.e. unified_mvp/kpi-agent/."""
    return _project_root().parent / "kpi-agent"


# ---------------------------------------------------------------------------
# KPI half (in-process)
# ---------------------------------------------------------------------------

def _load_kpi_agent_module():
    """Add kpi-agent/ to sys.path and import the `kpi_agent` module."""
    kpi_dir = _kpi_agent_dir()
    if not kpi_dir.is_dir():
        raise FileNotFoundError(
            f"KPI-agent folder not found at {kpi_dir}. "
            "Was unified_mvp set up correctly?"
        )
    kpi_dir_str = str(kpi_dir)
    if kpi_dir_str not in sys.path:
        sys.path.insert(0, kpi_dir_str)
    # Force fresh import in case a previous run shadowed it.
    if "kpi_agent" in sys.modules:
        return importlib.reload(sys.modules["kpi_agent"])
    return importlib.import_module("kpi_agent")


def run_kpi_derivation(
    spec_md_path: Path,
    *,
    echo: Callable[[str], Any] | None = None,
) -> dict:
    """Drive the WAF-KPI derivation pipeline in-process for one Speckit spec.md.

    Iterates every FR-NNN in the spec, embeds it, retrieves the top-3 WAF
    principles, calls gpt-4o-mini, and collects the GQM+KPI records that the
    standalone kpi_agent would otherwise write to disk.

    Returns:
        {
          "spec_id": "spec-YYYYMMDD-HHMMSS",
          "feature_name": "...",
          "frs": [{"id": "FR-001", "text": "..."}, ...],
          "gqm_records": [<as written to gqm_output.json>, ...],
          "kpi_records": [<as written to kpi_output.json>, ...],
          "fr_to_gqm":   {"FR-001": <gqm_id>, ...},
          "fr_to_kpis":  {"FR-001": [<kpi_record>, ...], ...},
        }
    """
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


# ---------------------------------------------------------------------------
# Top-level orchestrator
# ---------------------------------------------------------------------------

def run_unified(
    feature_dir: Path,
    *,
    alloy_jar: Path | None = None,
    java_bin: str = "java",
    no_cache: bool = False,
    no_mutate: bool = False,
    skip_alloy: bool = False,
    skip_kpi: bool = False,
    echo: Callable[[str], Any] | None = None,
) -> dict:
    """Run both halves on one Speckit feature folder and combine the results.

    `feature_dir` is the Speckit feature folder, e.g.
        speckit-trial/specs/002-bank-transfer-audit/
    It must contain spec.md, data-model.md, and contracts/http-api.md.

    Returns a dict with two top-level keys, `alloy` and `kpi`, each of which
    holds the structured output of the corresponding half. Either can be None
    if the matching `skip_*` flag was passed.
    """
    if echo is None:
        def echo(_msg):  # noqa: ARG001
            return None

    feature_dir = Path(feature_dir).resolve()
    if not feature_dir.is_dir():
        raise FileNotFoundError(f"feature folder not found: {feature_dir}")

    # Import here (not at module top) to keep the dependency contained.
    from speceval.cli import run_verification

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

    return {
        "feature_id": feature_dir.name,
        "feature_dir": feature_dir,
        "alloy": alloy_result,
        "kpi": kpi_result,
    }
