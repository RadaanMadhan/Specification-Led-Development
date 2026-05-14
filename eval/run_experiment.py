"""
run_experiment.py
-----------------
Main orchestrator for the KPI-spec evaluation experiment.

Runs kpi_agent.py against 9 pre-written specifications, 10 times each
(90 total executions), captures outputs, scores each run, and writes a
run_manifest.json on completion.

Usage:
    python eval/run_experiment.py                  # all 9 specs x 10 runs
    python eval/run_experiment.py --spec A-L1      # one spec x 10 runs
    python eval/run_experiment.py --dry-run        # print plan, no API calls
    python eval/run_experiment.py --runs 2         # override runs per spec (for validation)

Run from project root (parent of eval/).
"""

import argparse
import json
import shutil
import subprocess
import os
import sys
import time
from datetime import datetime
from pathlib import Path

# Force UTF-8 output so Unicode status chars (✓ ✗ ─) work on Windows cp1252 consoles
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")

# ── Paths ──────────────────────────────────────────────────────────────────────
PROJECT_ROOT = Path(__file__).parent.parent
EVAL_DIR     = Path(__file__).parent
SPECS_DIR    = EVAL_DIR / "specs"
RUNS_DIR     = EVAL_DIR / "runs"
MANIFEST_PATH = EVAL_DIR / "run_manifest.json"

# kpi_agent.py writes these relative to its own directory (project root)
KPI_AGENT   = PROJECT_ROOT / "kpi_agent.py"
GQM_OUT      = PROJECT_ROOT / "gqm_output.json"
KPI_OUT      = PROJECT_ROOT / "kpi_output.json"
COST_LOG_OUT = PROJECT_ROOT / "cost_log.json"

ALL_SPEC_IDS = ["A-L1", "A-L2", "A-L3", "B-L1", "B-L2", "B-L3", "C-L1", "C-L2", "C-L3"]
DEFAULT_N_RUNS = 10

# ── Colours ────────────────────────────────────────────────────────────────────
G = "\033[92m"; R = "\033[91m"; Y = "\033[93m"; B = "\033[94m"; RESET = "\033[0m"
BOLD = "\033[1m"


def _clear_agent_outputs() -> None:
    """Delete agent output files so each run starts fresh."""
    for f in (GQM_OUT, KPI_OUT, COST_LOG_OUT):
        if f.exists():
            f.unlink()


def _run_agent(spec_file: Path, run_id: str) -> tuple[bool, str]:
    """
    Invoke kpi_agent.py as a subprocess, passing run_id as argv[2].

    Args:
        spec_file: path to the spec .md file to pass as argv[1].
        run_id:    experiment run identifier (e.g. 'A-L1_run_03') passed as
                   argv[2] so kpi_agent.py embeds it in cost_log.json.

    Returns:
        (success: bool, error_message: str)

    Edge cases:
        - Non-zero exit code → failure with stderr excerpt
        - Timeout (180s) → failure with timeout message
    """
    try:
        result = subprocess.run(
            [sys.executable, str(KPI_AGENT), str(spec_file), run_id],
            capture_output=True,
            text=True,
            timeout=180,
            cwd=str(PROJECT_ROOT),
            env={**os.environ, "PYTHONIOENCODING": "utf-8"},
        )
        if result.returncode != 0:
            return False, f"exit {result.returncode}: {result.stderr[:300]}"
        return True, ""
    except subprocess.TimeoutExpired:
        return False, "subprocess timed out after 180s"
    except Exception as e:
        return False, str(e)


def run_single(spec_id: str, run_n: int, dry_run: bool = False) -> dict:
    """
    Execute one run of kpi_agent.py for a given spec, then score it.

    Args:
        spec_id:  experiment spec ID, e.g. 'A-L1'.
        run_n:    run number (1-based).
        dry_run:  if True, print intent and return without calling API.

    Returns:
        Manifest entry dict with keys: spec_id, run_n, run_id, status,
        run_dir, started_at, elapsed_seconds, error (on failure).

    Edge cases:
        - Missing spec file → immediate failure (no retry).
        - First API call fails → wait 5s, retry once → mark failed if still failing.
        - gqm_output.json or kpi_output.json not produced → failure.
    """
    run_id  = f"{spec_id}_run_{run_n:02d}"
    run_dir = RUNS_DIR / spec_id / f"run_{run_n:02d}"
    spec_file = SPECS_DIR / f"{spec_id}.md"

    entry = {
        "spec_id":         spec_id,
        "run_n":           run_n,
        "run_id":          run_id,
        "status":          "pending",
        "run_dir":         str(run_dir),
        "started_at":      None,
        "elapsed_seconds": None,
    }

    if dry_run:
        print(f"  {B}[DRY]{RESET} {spec_id} run {run_n:02d}  ->  {run_dir}")
        entry["status"] = "dry_run"
        return entry

    if not spec_file.exists():
        print(f"  {R}✗{RESET}  {spec_id} — spec file missing: {spec_file}")
        entry.update({"status": "failed", "error": "spec file not found"})
        return entry

    run_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy(spec_file, run_dir / "input_spec.md")

    _clear_agent_outputs()
    t0 = time.time()
    entry["started_at"] = datetime.now().isoformat()

    ok, err_msg = _run_agent(spec_file, run_id)

    if not ok:
        print(f"  {Y}!{RESET}  {spec_id} run {run_n:02d} failed ({err_msg}) — retrying in 5s...")
        time.sleep(5)
        _clear_agent_outputs()
        ok, err_msg = _run_agent(spec_file, run_id)

    elapsed = round(time.time() - t0, 1)
    entry["elapsed_seconds"] = elapsed

    if not ok:
        print(f"  {R}✗{RESET}  {spec_id} run {run_n:02d} permanently failed: {err_msg}")
        entry.update({"status": "failed", "error": err_msg})
        return entry

    # Verify expected outputs exist
    missing = [str(f) for f in (GQM_OUT, KPI_OUT) if not f.exists()]
    if missing:
        msg = f"expected output(s) not produced: {missing}"
        print(f"  {R}✗{RESET}  {spec_id} run {run_n:02d}: {msg}")
        entry.update({"status": "failed", "error": msg})
        return entry

    # Copy outputs to run directory
    shutil.copy(GQM_OUT, run_dir / "gqm_output.json")
    shutil.copy(KPI_OUT, run_dir / "kpi_output.json")
    if COST_LOG_OUT.exists():
        shutil.copy(COST_LOG_OUT, run_dir / "cost_log.json")

    # Score this run inline and write scores.json
    try:
        from scorer import score_run as _score_run
        gqm_records = json.loads((run_dir / "gqm_output.json").read_text())
        kpi_records = json.loads((run_dir / "kpi_output.json").read_text())
        scores = _score_run(spec_id, run_n, gqm_records, kpi_records)
        (run_dir / "scores.json").write_text(json.dumps(scores, indent=2))
    except Exception as e:
        print(f"  {Y}!{RESET}  scoring failed for {run_id}: {e}")

    print(f"  {G}✓{RESET}  {spec_id} run {run_n:02d}  ({elapsed}s)")
    entry["status"] = "success"
    return entry


def run_experiment(spec_ids: list, n_runs: int, dry_run: bool) -> None:
    """
    Iterate over all spec_ids × n_runs, collect manifest entries, save manifest.

    Args:
        spec_ids: list of spec identifiers to process.
        n_runs:   number of repetitions per spec.
        dry_run:  pass through to run_single.
    """
    total = len(spec_ids) * n_runs
    print(f"\n{BOLD}KPI-Spec Evaluation Experiment{RESET}")
    print(f"  Specs  : {len(spec_ids)} × {n_runs} runs = {total} total executions")
    if dry_run:
        print(f"  {Y}DRY RUN — no API calls will be made{RESET}")
    print()

    manifest = []
    done = 0

    for spec_id in spec_ids:
        print(f"{BOLD}[{spec_id}]{RESET}")
        for n in range(1, n_runs + 1):
            entry = run_single(spec_id, n, dry_run=dry_run)
            manifest.append(entry)
            done += 1

            if not dry_run:
                succeeded = sum(1 for e in manifest if e["status"] == "success")
                failed    = sum(1 for e in manifest if e["status"] == "failed")
                print(f"    progress: {done}/{total}  ({succeeded} ok, {failed} failed)")
        print()

    # Write manifest
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2))
    succeeded = sum(1 for e in manifest if e["status"] == "success")
    failed    = sum(1 for e in manifest if e["status"] == "failed")
    print(f"{G}{BOLD}Done.{RESET}  {succeeded}/{total} successful, {failed} failed")
    print(f"  Manifest -> {MANIFEST_PATH}")


# ── Entry point ────────────────────────────────────────────────────────────────
def main() -> None:
    """Parse CLI args and dispatch to run_experiment."""
    parser = argparse.ArgumentParser(
        description="KPI-spec evaluation experiment orchestrator"
    )
    parser.add_argument(
        "--spec",
        metavar="SPEC_ID",
        help="Run a single spec only (e.g. A-L1). Omit to run all 9.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would run without calling the API.",
    )
    parser.add_argument(
        "--runs",
        type=int,
        default=DEFAULT_N_RUNS,
        metavar="N",
        help=f"Runs per spec (default {DEFAULT_N_RUNS}). Use 2 for validation.",
    )
    args = parser.parse_args()

    if args.spec:
        if args.spec not in ALL_SPEC_IDS:
            print(f"Unknown spec '{args.spec}'. Valid: {ALL_SPEC_IDS}")
            sys.exit(1)
        spec_ids = [args.spec]
    else:
        spec_ids = ALL_SPEC_IDS

    run_experiment(spec_ids, n_runs=args.runs, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
