#!/usr/bin/env python3
"""Driver for the visualization pipeline."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

try:
    from .ingest import DEFAULT_DB_PATH, DEFAULT_RUNS_ROOT, ingest_run
except ImportError:  # pragma: no cover - supports direct execution
    from ingest import DEFAULT_DB_PATH, DEFAULT_RUNS_ROOT, ingest_run


def find_latest_run(runs_root: Path) -> Path:
    runs_root = runs_root.resolve()
    candidates = [
        p
        for p in runs_root.iterdir()
        if p.is_dir() and (p / "metadata.json").exists() and (p / "scores.json").exists()
    ]
    if not candidates:
        raise FileNotFoundError(f"No pipeline runs found under {runs_root}")
    return sorted(candidates)[-1]


def main() -> None:
    parser = argparse.ArgumentParser(description="Ingest latest run and launch dashboard")
    parser.add_argument("--runs-root", type=Path, default=DEFAULT_RUNS_ROOT)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB_PATH)
    parser.add_argument("--no-launch", action="store_true")
    args = parser.parse_args()

    latest_run = find_latest_run(args.runs_root)
    metrics = ingest_run(latest_run, args.db)
    print(f"Ingested run {metrics['run_id']} into {args.db}")

    if args.no_launch:
        return

    dashboard_path = Path(__file__).resolve().parent / "dashboard.py"
    cmd = [sys.executable, "-m", "streamlit", "run", str(dashboard_path)]
    subprocess.run(cmd, check=False)


if __name__ == "__main__":
    main()
