#!/usr/bin/env python3
"""Ingest pipeline run artifacts into a local SQLite database."""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


DEFAULT_DB_PATH = Path(__file__).resolve().parent / "visualization.db"
DEFAULT_RUNS_ROOT = Path(__file__).resolve().parents[1] / "pipeline_runs"


@dataclass(frozen=True)
class IngestedRun:
    run_id: str
    run_dir: Path
    metadata: dict[str, Any]
    scores: dict[str, Any]
    cost_breakdown: dict[str, Any]
    cost_summary_text: str
    kpis: dict[str, Any]
    comparison_report_text: str


def connect(db_path: Path) -> sqlite3.Connection:
    connection = sqlite3.connect(db_path)
    connection.row_factory = sqlite3.Row
    return connection


def ensure_schema(connection: sqlite3.Connection) -> None:
    connection.executescript(
        """
        PRAGMA journal_mode=WAL;

        CREATE TABLE IF NOT EXISTS runs_raw (
            run_id TEXT PRIMARY KEY,
            run_dir TEXT NOT NULL,
            timestamp TEXT,
            goal TEXT,
            pipeline_version TEXT,
            raw_metadata_json TEXT NOT NULL,
            raw_scores_json TEXT NOT NULL,
            raw_cost_json TEXT NOT NULL,
            raw_cost_summary_text TEXT,
            raw_kpis_json TEXT,
            raw_comparison_report_md TEXT,
            ingested_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS runs_metrics (
            run_id TEXT PRIMARY KEY,
            run_dir TEXT NOT NULL,
            timestamp TEXT,
            goal TEXT,
            pipeline_version TEXT,
            guided_total REAL,
            baseline_total REAL,
            verdict TEXT,
            structural_score REAL,
            fr_score REAL,
            invariant_score REAL,
            test_score REAL,
            kpi_score REAL,
            security_score REAL,
            patterns_expected INTEGER,
            frs_expected INTEGER,
            mutations_expected INTEGER,
            facts_expected INTEGER,
            kpi_metric_constants INTEGER,
            kpi_threshold_definitions INTEGER,
            kpi_comments INTEGER,
            total_test_functions INTEGER,
            assertion_tests INTEGER,
            mutation_tests INTEGER,
            kpi_tests INTEGER,
            fr_tests INTEGER,
            other_tests INTEGER,
            cache_hit_rate REAL,
            cache_savings REAL,
            total_cost REAL,
            guided_cost REAL,
            baseline_cost REAL,
            comparison_cost REAL,
            guided_cost_per_point REAL,
            baseline_cost_per_point REAL,
            test_total REAL,
            test_assertion REAL,
            test_mutation REAL,
            test_kpi REAL,
            test_fr REAL,
            test_other REAL,
            kpi_expected INTEGER,
            kpi_found INTEGER,
            created_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS test_breakdown (
            run_id TEXT NOT NULL,
            test_type TEXT NOT NULL,
            test_count INTEGER NOT NULL,
            PRIMARY KEY (run_id, test_type)
        );

        CREATE TABLE IF NOT EXISTS cost_breakdown (
            run_id TEXT NOT NULL,
            phase TEXT NOT NULL,
            input_tokens INTEGER,
            output_tokens INTEGER,
            cache_write_tokens INTEGER,
            cache_read_tokens INTEGER,
            cost REAL,
            PRIMARY KEY (run_id, phase)
        );
        """
    )
    # Ensure existing runs_raw table is updated with new columns
    cursor = connection.execute("PRAGMA table_info(runs_raw)")
    columns = [row[1] for row in cursor.fetchall()]
    if "raw_kpis_json" not in columns:
        connection.execute("ALTER TABLE runs_raw ADD COLUMN raw_kpis_json TEXT")
    if "raw_comparison_report_md" not in columns:
        connection.execute("ALTER TABLE runs_raw ADD COLUMN raw_comparison_report_md TEXT")


def _read_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise FileNotFoundError(path)
    return json.loads(path.read_text(encoding="utf-8"))


def _latest_pipeline_run(run_dir: Path) -> Path:
    run_dir = run_dir.resolve()
    if (run_dir / "scores.json").exists() and (run_dir / "metadata.json").exists():
        return run_dir
    candidates = [
        p
        for p in run_dir.iterdir()
        if p.is_dir() and (p / "scores.json").exists() and (p / "metadata.json").exists()
    ]
    if not candidates:
        raise FileNotFoundError(f"No pipeline run found under {run_dir}")
    return sorted(candidates)[-1]


def _load_cost_summary_text(run_dir: Path) -> str:
    for filename in ("COST_SUMMARY.md", "cost_summary.md"):
        path = run_dir / filename
        if path.exists():
            return path.read_text(encoding="utf-8")
    return ""


def _parse_first_float(pattern: str, text: str) -> float | None:
    match = re.search(pattern, text, re.IGNORECASE | re.MULTILINE)
    if not match:
        return None
    try:
        return float(match.group(1).replace(",", ""))
    except ValueError:
        return None


def _parse_cost_summary(text: str) -> dict[str, float]:
    cleaned = text.replace("**", "")
    total_cost = _parse_first_float(r"Total Cost:\s*\$([\d.]+)", cleaned) or 0.0
    cost_without_caching = _parse_first_float(r"Cost without caching:\s*~?\$([\d.]+)", cleaned) or 0.0
    cache_savings = _parse_first_float(r"Cache savings:\s*~?\$([\d.]+)", cleaned) or 0.0
    if not cache_savings and total_cost and cost_without_caching:
        cache_savings = round(cost_without_caching - total_cost, 2)

    return {
        "cache_hit_rate": _parse_first_float(r"([\d.]+)%\s*cache hit rate", cleaned) or 0.0,
        "cache_savings": cache_savings,
        "guided_track_cost": _parse_first_float(r"Guided track.*?:\s*\$([\d.]+)", cleaned) or 0.0,
        "baseline_track_cost": _parse_first_float(r"Baseline track.*?:\s*\$([\d.]+)", cleaned) or 0.0,
    }


def _load_comparison_report(run_dir: Path) -> str:
    for filename in ("comparison_report.md", "detailed_comparison.md"):
        path = run_dir / filename
        if path.exists():
            return path.read_text(encoding="utf-8")
    return ""


def _load_kpis_json(run_dir: Path) -> dict[str, Any]:
    path = run_dir / "kpis.json"
    if path.exists():
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except Exception:
            return {}
    return {}


def load_run_artifacts(run_dir: Path) -> IngestedRun:
    metadata = _read_json(run_dir / "metadata.json")
    scores = _read_json(run_dir / "scores.json")

    cost_path = run_dir / "cost_breakdown.json"
    if cost_path.exists():
        cost_breakdown = _read_json(cost_path)
    else:
        cost_breakdown = {"phases": {}, "totals": {}}

    run_id = str(metadata.get("timestamp") or run_dir.name)
    return IngestedRun(
        run_id=run_id,
        run_dir=run_dir,
        metadata=metadata,
        scores=scores,
        cost_breakdown=cost_breakdown,
        cost_summary_text=_load_cost_summary_text(run_dir),
        kpis=_load_kpis_json(run_dir),
        comparison_report_text=_load_comparison_report(run_dir),
    )


def _dimension(scores: dict[str, Any], key: str) -> dict[str, Any]:
    for dim in scores.get("dimensions", []):
        if dim.get("key") == key:
            return dim
    return {}


def flatten_metrics(ingested: IngestedRun) -> dict[str, Any]:
    metadata = ingested.metadata
    scores = ingested.scores
    cost = ingested.cost_breakdown
    summary = _parse_cost_summary(ingested.cost_summary_text)

    structural = _dimension(scores, "structural_completeness")
    fr = _dimension(scores, "fr_coverage")
    invariant = _dimension(scores, "invariant_enforcement")
    test = _dimension(scores, "test_quality")
    kpi = _dimension(scores, "kpi_instrumentation")
    security = _dimension(scores, "security_posture")

    guided_detail = test.get("guided_detail", {})
    kpi_detail = kpi.get("guided_detail", {})

    total_tests = int(guided_detail.get("total_test_functions", 0) or 0)
    assertion = int(guided_detail.get("assertion_tests", 0) or 0)
    mutation = int(guided_detail.get("mutation_tests", 0) or 0)
    kpi_tests = int(guided_detail.get("kpi_tests", 0) or 0)
    fr_tests = int(guided_detail.get("fr_tests", 0) or 0)
    other_tests = max(0, total_tests - (assertion + mutation + kpi_tests + fr_tests))

    kpi_metric_constants = list(kpi_detail.get("metric_constants", []))
    kpi_found = len(kpi_metric_constants)

    guided_cost = float(cost.get("phases", {}).get("guided_codegen", {}).get("total_cost", 0.0) or 0.0)
    guided_cost += float(cost.get("phases", {}).get("guided_testgen", {}).get("total_cost", 0.0) or 0.0)
    baseline_cost = float(cost.get("phases", {}).get("baseline_codegen", {}).get("total_cost", 0.0) or 0.0)
    comparison_cost = float(cost.get("phases", {}).get("comparison", {}).get("total_cost", 0.0) or 0.0)
    total_cost = float(cost.get("totals", {}).get("total_cost", 0.0) or (guided_cost + baseline_cost + comparison_cost))

    cache_read = 0
    cache_write = 0
    for phase in cost.get("phases", {}).values():
        cache_read += int(phase.get("cache_read_tokens", 0) or 0)
        cache_write += int(phase.get("cache_creation_tokens", phase.get("cache_write_tokens", 0)) or 0)

    cache_hit_rate = summary["cache_hit_rate"]
    if not cache_hit_rate and (cache_read or cache_write):
        cache_hit_rate = round((cache_read / (cache_read + cache_write)) * 100, 1)

    cache_savings = summary["cache_savings"]
    guided_track_cost = summary["guided_track_cost"] or guided_cost
    baseline_track_cost = summary["baseline_track_cost"] or baseline_cost

    guided_total = float(scores.get("guided_total", 0.0) or 0.0)
    baseline_total = float(scores.get("baseline_total", 0.0) or 0.0)
    guided_cost_per_point = round(guided_track_cost / guided_total, 2) if guided_total else 0.0
    baseline_cost_per_point = round(baseline_track_cost / baseline_total, 2) if baseline_total else 0.0

    return {
        "run_id": ingested.run_id,
        "run_dir": str(ingested.run_dir),
        "timestamp": metadata.get("timestamp"),
        "goal": metadata.get("goal"),
        "pipeline_version": metadata.get("pipeline_version"),
        "guided_total": guided_total,
        "baseline_total": baseline_total,
        "verdict": scores.get("verdict"),
        "structural_score": float(structural.get("guided_score", 0.0) or 0.0),
        "fr_score": float(fr.get("guided_score", 0.0) or 0.0),
        "invariant_score": float(invariant.get("guided_score", 0.0) or 0.0),
        "test_score": float(test.get("guided_score", 0.0) or 0.0),
        "kpi_score": float(kpi.get("guided_score", 0.0) or 0.0),
        "security_score": float(security.get("guided_score", 0.0) or 0.0),
        "patterns_expected": int(scores.get("context_summary", {}).get("patterns_expected", 0) or 0),
        "frs_expected": int(scores.get("context_summary", {}).get("frs_expected", 0) or 0),
        "mutations_expected": int(scores.get("context_summary", {}).get("mutations_expected", 0) or 0),
        "facts_expected": int(scores.get("context_summary", {}).get("facts_expected", 0) or 0),
        "kpi_metric_constants": kpi_found,
        "kpi_threshold_definitions": int(kpi_detail.get("threshold_definitions", 0) or 0),
        "kpi_comments": int(kpi_detail.get("kpi_comments", 0) or 0),
        "total_test_functions": total_tests,
        "assertion_tests": assertion,
        "mutation_tests": mutation,
        "kpi_tests": kpi_tests,
        "fr_tests": fr_tests,
        "other_tests": other_tests,
        "cache_hit_rate": cache_hit_rate,
        "cache_savings": cache_savings,
        "total_cost": total_cost,
        "guided_cost": round(guided_cost, 2),
        "baseline_cost": round(baseline_cost, 2),
        "comparison_cost": round(comparison_cost, 2),
        "guided_cost_per_point": guided_cost_per_point,
        "baseline_cost_per_point": baseline_cost_per_point,
        "test_total": total_tests,
        "test_assertion": assertion,
        "test_mutation": mutation,
        "test_kpi": kpi_tests,
        "test_fr": fr_tests,
        "test_other": other_tests,
        "kpi_expected": int(scores.get("context_summary", {}).get("facts_expected", 0) or 0),
        "kpi_found": kpi_found,
    }


def upsert_run(connection: sqlite3.Connection, ingested: IngestedRun) -> dict[str, Any]:
    metrics = flatten_metrics(ingested)
    now = datetime.now(timezone.utc).isoformat()

    connection.execute(
        """
        INSERT OR REPLACE INTO runs_raw
        (run_id, run_dir, timestamp, goal, pipeline_version,
         raw_metadata_json, raw_scores_json, raw_cost_json, raw_cost_summary_text,
         raw_kpis_json, raw_comparison_report_md, ingested_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            metrics["run_id"],
            metrics["run_dir"],
            metrics["timestamp"],
            metrics["goal"],
            metrics["pipeline_version"],
            json.dumps(ingested.metadata, indent=2),
            json.dumps(ingested.scores, indent=2),
            json.dumps(ingested.cost_breakdown, indent=2),
            ingested.cost_summary_text,
            json.dumps(ingested.kpis, indent=2) if ingested.kpis else None,
            ingested.comparison_report_text or None,
            now,
        ),
    )

    connection.execute(
        """
        INSERT OR REPLACE INTO runs_metrics
        (run_id, run_dir, timestamp, goal, pipeline_version,
         guided_total, baseline_total, verdict,
         structural_score, fr_score, invariant_score, test_score, kpi_score, security_score,
         patterns_expected, frs_expected, mutations_expected, facts_expected,
         kpi_metric_constants, kpi_threshold_definitions, kpi_comments,
         total_test_functions, assertion_tests, mutation_tests, kpi_tests, fr_tests, other_tests,
         cache_hit_rate, cache_savings, total_cost, guided_cost, baseline_cost, comparison_cost,
         guided_cost_per_point, baseline_cost_per_point,
         test_total, test_assertion, test_mutation, test_kpi, test_fr, test_other,
         kpi_expected, kpi_found, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            metrics["run_id"],
            metrics["run_dir"],
            metrics["timestamp"],
            metrics["goal"],
            metrics["pipeline_version"],
            metrics["guided_total"],
            metrics["baseline_total"],
            metrics["verdict"],
            metrics["structural_score"],
            metrics["fr_score"],
            metrics["invariant_score"],
            metrics["test_score"],
            metrics["kpi_score"],
            metrics["security_score"],
            metrics["patterns_expected"],
            metrics["frs_expected"],
            metrics["mutations_expected"],
            metrics["facts_expected"],
            metrics["kpi_metric_constants"],
            metrics["kpi_threshold_definitions"],
            metrics["kpi_comments"],
            metrics["total_test_functions"],
            metrics["assertion_tests"],
            metrics["mutation_tests"],
            metrics["kpi_tests"],
            metrics["fr_tests"],
            metrics["other_tests"],
            metrics["cache_hit_rate"],
            metrics["cache_savings"],
            metrics["total_cost"],
            metrics["guided_cost"],
            metrics["baseline_cost"],
            metrics["comparison_cost"],
            metrics["guided_cost_per_point"],
            metrics["baseline_cost_per_point"],
            metrics["test_total"],
            metrics["test_assertion"],
            metrics["test_mutation"],
            metrics["test_kpi"],
            metrics["test_fr"],
            metrics["test_other"],
            metrics["kpi_expected"],
            metrics["kpi_found"],
            now,
        ),
    )

    connection.execute("DELETE FROM test_breakdown WHERE run_id = ?", (metrics["run_id"],))
    for test_type, count in [
        ("assertion", metrics["assertion_tests"]),
        ("mutation", metrics["mutation_tests"]),
        ("kpi", metrics["kpi_tests"]),
        ("fr", metrics["fr_tests"]),
        ("other", metrics["other_tests"]),
    ]:
        connection.execute(
            "INSERT INTO test_breakdown (run_id, test_type, test_count) VALUES (?, ?, ?)",
            (metrics["run_id"], test_type, count),
        )

    connection.execute("DELETE FROM cost_breakdown WHERE run_id = ?", (metrics["run_id"],))
    for phase_name, phase_data in ingested.cost_breakdown.get("phases", {}).items():
        connection.execute(
            """
            INSERT INTO cost_breakdown
            (run_id, phase, input_tokens, output_tokens, cache_write_tokens, cache_read_tokens, cost)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                metrics["run_id"],
                phase_name,
                int(phase_data.get("input_tokens", 0) or 0),
                int(phase_data.get("output_tokens", 0) or 0),
                int(phase_data.get("cache_creation_tokens", phase_data.get("cache_write_tokens", 0)) or 0),
                int(phase_data.get("cache_read_tokens", 0) or 0),
                float(phase_data.get("total_cost", phase_data.get("cost", 0.0)) or 0.0),
            ),
        )

    connection.commit()
    return metrics


def ingest_run(run_dir: Path, db_path: Path = DEFAULT_DB_PATH) -> dict[str, Any]:
    run_dir = _latest_pipeline_run(run_dir)
    ingested = load_run_artifacts(run_dir)
    connection = connect(db_path)
    try:
        ensure_schema(connection)
        return upsert_run(connection, ingested)
    finally:
        connection.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Ingest a pipeline run into SQLite")
    parser.add_argument(
        "run_dir",
        nargs="?",
        type=Path,
        default=DEFAULT_RUNS_ROOT,
        help="Path to a pipeline run directory or the runs root",
    )
    parser.add_argument(
        "--db",
        type=Path,
        default=DEFAULT_DB_PATH,
        help="SQLite database path",
    )
    args = parser.parse_args()

    result = ingest_run(args.run_dir, args.db)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
