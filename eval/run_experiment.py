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

# kpi_agent.py writes outputs relative to project root with framework suffix
KPI_AGENT    = PROJECT_ROOT / "kpi_agent.py"

ALL_SPEC_IDS       = ["A-L1", "A-L2", "A-L3", "B-L1", "B-L2", "B-L3", "C-L1", "C-L2", "C-L3"]
ALL_FRAMEWORKS     = ["waf", "iso25010", "nist_csf", "sre"]
DEFAULT_N_RUNS     = 10
VALID_MODES        = ["standard", "framework_comparison"]


def _agent_outputs(framework: str) -> tuple:
    """Return (gqm_out, kpi_out, cost_out) paths for a given framework."""
    return (
        PROJECT_ROOT / f"gqm_output_{framework}.json",
        PROJECT_ROOT / f"kpi_output_{framework}.json",
        PROJECT_ROOT / f"cost_log_{framework}.json",
    )

# ── Colours ────────────────────────────────────────────────────────────────────
G = "\033[92m"; R = "\033[91m"; Y = "\033[93m"; B = "\033[94m"; RESET = "\033[0m"
BOLD = "\033[1m"


def _clear_agent_outputs(framework: str) -> None:
    """Delete agent output files for the given framework so each run starts fresh."""
    for f in _agent_outputs(framework):
        if f.exists():
            f.unlink()


def _run_agent(spec_file: Path, run_id: str, framework: str) -> tuple[bool, str]:
    """
    Invoke kpi_agent.py as a subprocess.

    Args:
        spec_file: path to the spec .md file.
        run_id:    experiment run identifier embedded in cost_log.json.
        framework: framework identifier passed via --framework flag.

    Returns:
        (success: bool, error_message: str)
    """
    try:
        result = subprocess.run(
            [sys.executable, str(KPI_AGENT), str(spec_file), run_id,
             "--framework", framework],
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


def run_single(spec_id: str, run_n: int, framework: str = "waf",
               dry_run: bool = False) -> dict:
    """
    Execute one run of kpi_agent.py for a given spec and framework, then score it.

    Args:
        spec_id:   experiment spec ID, e.g. 'A-L1'.
        run_n:     run number (1-based).
        framework: framework identifier, e.g. 'waf', 'iso25010'.
        dry_run:   if True, print intent and return without calling API.

    Returns:
        Manifest entry dict with keys: spec_id, framework, run_n, run_id, status,
        run_dir, started_at, elapsed_seconds, error (on failure).
    """
    run_id  = f"{spec_id}_{framework}_run_{run_n:02d}"
    run_dir = RUNS_DIR / spec_id / framework / f"run_{run_n:02d}"
    spec_file = SPECS_DIR / f"{spec_id}.md"
    gqm_out, kpi_out, cost_out = _agent_outputs(framework)

    entry = {
        "spec_id":         spec_id,
        "framework":       framework,
        "run_n":           run_n,
        "run_id":          run_id,
        "status":          "pending",
        "run_dir":         str(run_dir),
        "started_at":      None,
        "elapsed_seconds": None,
    }

    if dry_run:
        print(f"  {B}[DRY]{RESET} {spec_id}/{framework} run {run_n:02d}  ->  {run_dir}")
        entry["status"] = "dry_run"
        return entry

    if not spec_file.exists():
        print(f"  {R}✗{RESET}  {spec_id} — spec file missing: {spec_file}")
        entry.update({"status": "failed", "error": "spec file not found"})
        return entry

    run_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy(spec_file, run_dir / "input_spec.md")

    _clear_agent_outputs(framework)
    t0 = time.time()
    entry["started_at"] = datetime.now().isoformat()

    ok, err_msg = _run_agent(spec_file, run_id, framework)

    if not ok:
        print(f"  {Y}!{RESET}  {spec_id}/{framework} run {run_n:02d} failed ({err_msg}) — retrying in 5s...")
        time.sleep(5)
        _clear_agent_outputs(framework)
        ok, err_msg = _run_agent(spec_file, run_id, framework)

    elapsed = round(time.time() - t0, 1)
    entry["elapsed_seconds"] = elapsed

    if not ok:
        print(f"  {R}✗{RESET}  {spec_id}/{framework} run {run_n:02d} permanently failed: {err_msg}")
        entry.update({"status": "failed", "error": err_msg})
        return entry

    # Verify expected outputs exist
    missing = [str(f) for f in (gqm_out, kpi_out) if not f.exists()]
    if missing:
        msg = f"expected output(s) not produced: {missing}"
        print(f"  {R}✗{RESET}  {spec_id}/{framework} run {run_n:02d}: {msg}")
        entry.update({"status": "failed", "error": msg})
        return entry

    # Copy outputs to run directory
    shutil.copy(gqm_out, run_dir / "gqm_output.json")
    shutil.copy(kpi_out, run_dir / "kpi_output.json")
    if cost_out.exists():
        shutil.copy(cost_out, run_dir / "cost_log.json")

    # Score this run inline and write scores.json
    try:
        from scorer import score_run as _score_run
        gqm_records = json.loads((run_dir / "gqm_output.json").read_text())
        kpi_records = json.loads((run_dir / "kpi_output.json").read_text())
        scores = _score_run(spec_id, run_n, gqm_records, kpi_records)
        (run_dir / "scores.json").write_text(json.dumps(scores, indent=2))
    except Exception as e:
        print(f"  {Y}!{RESET}  scoring failed for {run_id}: {e}")

    print(f"  {G}✓{RESET}  {spec_id}/{framework} run {run_n:02d}  ({elapsed}s)")
    entry["status"] = "success"
    return entry


def run_experiment(spec_ids: list, n_runs: int, framework: str,
                   dry_run: bool, start_run: int = 1) -> None:
    """
    Iterate over spec_ids × n_runs for a single framework.

    Args:
        spec_ids:   list of spec identifiers to process.
        n_runs:     number of repetitions per spec (upper bound, inclusive).
        framework:  framework identifier (e.g. 'waf').
        dry_run:    pass through to run_single.
        start_run:  first run number (default 1). Set > 1 to resume a partial run.
    """
    total = len(spec_ids) * (n_runs - start_run + 1)
    print(f"\n{BOLD}KPI-Spec Evaluation Experiment{RESET}")
    print(f"  Framework: {framework}")
    print(f"  Specs    : {len(spec_ids)} × runs {start_run}–{n_runs} = {total} total executions")
    if dry_run:
        print(f"  {Y}DRY RUN — no API calls will be made{RESET}")
    print()

    manifest = []
    done = 0

    for spec_id in spec_ids:
        print(f"{BOLD}[{spec_id}]{RESET}")
        for n in range(start_run, n_runs + 1):
            entry = run_single(spec_id, n, framework=framework, dry_run=dry_run)
            manifest.append(entry)
            done += 1

            if not dry_run:
                succeeded = sum(1 for e in manifest if e["status"] == "success")
                failed    = sum(1 for e in manifest if e["status"] == "failed")
                print(f"    progress: {done}/{total}  ({succeeded} ok, {failed} failed)")
        print()

    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2))
    succeeded = sum(1 for e in manifest if e["status"] == "success")
    failed    = sum(1 for e in manifest if e["status"] == "failed")
    print(f"{G}{BOLD}Done.{RESET}  {succeeded}/{total} successful, {failed} failed")
    print(f"  Manifest -> {MANIFEST_PATH}")


def run_framework_comparison(spec_ids: list, n_runs: int, dry_run: bool,
                              start_run: int = 1) -> None:
    """
    Run all spec_ids × all 4 frameworks × n_runs each.

    Total executions: len(spec_ids) × 4 × (n_runs - start_run + 1)
    Results stored under eval/runs/{spec_id}/{framework}/run_{nn}/

    Args:
        spec_ids:   list of spec identifiers (default: all 9).
        n_runs:     runs per (spec, framework) pair (upper bound, inclusive).
        dry_run:    pass through to run_single.
        start_run:  first run number (default 1). Set > 1 to resume a partial run.
    """
    total = len(spec_ids) * len(ALL_FRAMEWORKS) * (n_runs - start_run + 1)
    print(f"\n{BOLD}KPI-Spec Framework Comparison{RESET}")
    print(f"  Specs      : {len(spec_ids)}")
    print(f"  Frameworks : {ALL_FRAMEWORKS}")
    print(f"  Runs each  : {start_run}–{n_runs}")
    print(f"  Total      : {total} executions")
    if dry_run:
        print(f"  {Y}DRY RUN — no API calls will be made{RESET}")
    print()

    manifest = []
    done = 0

    for framework in ALL_FRAMEWORKS:
        print(f"\n{BOLD}=== Framework: {framework} ==={RESET}")
        for spec_id in spec_ids:
            print(f"{BOLD}[{spec_id}]{RESET}")
            for n in range(start_run, n_runs + 1):
                entry = run_single(spec_id, n, framework=framework, dry_run=dry_run)
                manifest.append(entry)
                done += 1

                if not dry_run:
                    succeeded = sum(1 for e in manifest if e["status"] == "success")
                    failed    = sum(1 for e in manifest if e["status"] == "failed")
                    print(f"    progress: {done}/{total}  ({succeeded} ok, {failed} failed)")
            print()

    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2))
    succeeded = sum(1 for e in manifest if e["status"] == "success")
    failed    = sum(1 for e in manifest if e["status"] == "failed")
    print(f"{G}{BOLD}Done.{RESET}  {succeeded}/{total} successful, {failed} failed")
    print(f"  Manifest -> {MANIFEST_PATH}")


def rescore_all_runs() -> None:
    """
    Re-score every run directory from its saved gqm_output.json + kpi_output.json.

    Use this after changing the scoring logic (e.g. D2a/D2b redesign) to
    regenerate all scores.json files without re-running the LLM pipeline.

    Covers both new-layout (spec/framework/run_NN) and old-layout (spec/run_NN)
    directories. After running this, re-run aggregate.py to rebuild the CSVs.
    """
    sys.path.insert(0, str(EVAL_DIR))
    from scorer import score_run as _score_run

    updated = 0
    failed  = 0

    # New layout: spec / framework / run_NN
    run_dirs = sorted(RUNS_DIR.glob("*/*/run_*"))
    # Old layout: spec / run_NN
    run_dirs += sorted(RUNS_DIR.glob("*/run_*"))

    for run_dir in run_dirs:
        if not run_dir.is_dir():
            continue
        gqm_file = run_dir / "gqm_output.json"
        kpi_file = run_dir / "kpi_output.json"
        if not gqm_file.exists() or not kpi_file.exists():
            continue

        run_name = run_dir.name                          # e.g. "run_01"
        parent   = run_dir.parent
        # New layout: parent is framework dir; grandparent is spec dir
        # Old layout: parent is spec dir directly
        if parent.parent.name in ALL_SPEC_IDS:
            spec_id = parent.parent.name
        else:
            spec_id = parent.name

        try:
            run_n = int(run_name.split("_")[1])
        except (IndexError, ValueError):
            run_n = 0

        try:
            gqm_records = json.loads(gqm_file.read_text())
            kpi_records = json.loads(kpi_file.read_text())
            scores = _score_run(spec_id, run_n, gqm_records, kpi_records)
            (run_dir / "scores.json").write_text(json.dumps(scores, indent=2))
            updated += 1
        except Exception as e:
            print(f"  {Y}!{RESET}  Failed to rescore {run_dir.relative_to(PROJECT_ROOT)}: {e}")
            failed += 1

    print(f"\n{G}{BOLD}Rescore complete.{RESET}  "
          f"{updated} run(s) updated, {failed} failed.")
    print("  Run aggregate.py next to rebuild all_scores.csv and cell_summary.csv.")


# ── Entry point ────────────────────────────────────────────────────────────────
def main() -> None:
    """Parse CLI args and dispatch to run_experiment, run_framework_comparison, or rescore."""
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
    parser.add_argument(
        "--framework",
        choices=["waf", "iso25010", "nist_csf", "sre"],
        default="waf",
        metavar="FRAMEWORK",
        help="Framework to use (default: waf). Ignored when --mode framework_comparison.",
    )
    parser.add_argument(
        "--mode",
        choices=VALID_MODES,
        default="standard",
        metavar="MODE",
        help=(
            "standard (default): run one framework against spec_ids. "
            "framework_comparison: run all 9 specs × 4 frameworks × --runs each."
        ),
    )
    parser.add_argument(
        "--start-run",
        type=int,
        default=1,
        metavar="N",
        help="First run number to execute (default 1). Use to resume after interruption.",
    )
    parser.add_argument(
        "--rescore",
        action="store_true",
        help=(
            "Re-score all existing run directories from saved outputs "
            "without re-running the LLM pipeline. Use after changing scoring logic."
        ),
    )
    args = parser.parse_args()

    if args.rescore:
        rescore_all_runs()
        return

    if args.spec:
        if args.spec not in ALL_SPEC_IDS:
            print(f"Unknown spec '{args.spec}'. Valid: {ALL_SPEC_IDS}")
            sys.exit(1)
        spec_ids = [args.spec]
    else:
        spec_ids = ALL_SPEC_IDS

    if args.mode == "framework_comparison":
        run_framework_comparison(spec_ids, n_runs=args.runs, dry_run=args.dry_run,
                                 start_run=args.start_run)
    else:
        run_experiment(spec_ids, n_runs=args.runs, framework=args.framework,
                       dry_run=args.dry_run, start_run=args.start_run)


if __name__ == "__main__":
    main()
