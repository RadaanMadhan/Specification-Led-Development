"""eval/run_experiment.py — Stage 1 AQS sweep harness (Phase E2).

Iterates over the 9 pinned Speckit cells × 1 model (M-best) × 10 replicates
= 90 runs, shelling out to ``speceval.cli verify-design`` per run. Output
artefacts (feature_model.als, manifest.json, alloy_verdicts.json,
mutation_outcomes.json, cost_log.json, report.txt) are moved from the
verify-design default location at ``<repo>/runs/<cell-id>/`` to the
final eval layout at ``<repo>/eval/runs/<cell-id>/<model-tag>/run_NN/``.

The harness is **resumable**: it writes ``eval/runs/_progress.json`` after
every run and, on startup, scans that file plus the on-disk run
directories to determine what has already completed. Re-running with the
same arguments will skip every (cell, model, rep) that has a complete
``run_NN/`` directory on disk.

Per-run errors (non-zero exit codes, PARSE_FAIL, timeouts) **do not abort
the harness** — they are logged and the next run continues. D1=0 outliers
are valid data for the AQS scorer in Phase E3.

Single-cell smoke-test path::

    python eval/run_experiment.py --cells A-L1 --reps 1

This issues exactly one ``verify-design`` invocation, populates
``eval/runs/A-L1/M-best/run_01/`` with the six expected artefacts, and
exits cleanly.

Stage 1 full sweep::

    python eval/run_experiment.py

defaults to ``--cells <all 9> --models M-best --reps 10`` = 90 runs.

Multi-model plumbing
--------------------

``--models`` accepts a comma-separated list (e.g. ``M-best,M-mid,M-small``).
Only ``M-best`` is empirically validated as of 2026-05-18 (see
``eval/MODEL_SELECTION.md`` §8); the multi-value support is retained for
future use but the default ``M-best`` is what Stage 1 actually runs.

This harness MUST be invoked on a host that can reach api.anthropic.com
— the Cowork sandbox proxy returns 401 for that endpoint as of
2026-05-18, so Stage 1 runs on Leon's Mac via
``run_stage1_sweep.command``.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

ALL_CELLS: tuple[str, ...] = (
    "A-L1", "A-L2", "A-L3",
    "B-L1", "B-L2", "B-L3",
    "C-L1", "C-L2", "C-L3",
)

VALIDATED_MODELS: tuple[str, ...] = ("M-best",)
# Models accepted by --models. M-mid/M-small are syntactically valid via
# the TIER_CONFIG dict but are not validated for Stage 1 use (see
# eval/EVALUATION_PLAN.md Appendix E.2).
ACCEPTED_MODELS: tuple[str, ...] = ("M-best", "M-mid", "M-small")


# Files that a complete run MUST contain. If any of these is missing
# the run is considered failed and is *not* skipped on resume.
COMPLETE_RUN_FILES: tuple[str, ...] = (
    "feature_model.als",
    "feature_model.manifest.json",
    "cost_log.json",
)
# Additional artefacts a healthy (Alloy-parsing) run produces. These are
# not required for "run is on disk and we shouldn't redo it" — a PARSE_FAIL
# run only has the three files above and that's still valid data — but
# the harness records their presence in progress.json so E3 can quickly
# tell PARSE_OK vs PARSE_FAIL runs apart without re-reading the .als.
HEALTHY_RUN_FILES: tuple[str, ...] = (
    "alloy_verdicts.json",
    "mutation_outcomes.json",
    "report.txt",
)


# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

def repo_root() -> Path:
    """`spec-led-eval/` — the parent of `eval/`."""
    return Path(__file__).resolve().parent.parent


def eval_root() -> Path:
    return Path(__file__).resolve().parent


def specs_root() -> Path:
    return eval_root() / "specs"


def runs_root() -> Path:
    return eval_root() / "runs"


def cell_spec_dir(cell: str) -> Path:
    return specs_root() / cell


def cell_run_dir(cell: str, model: str, rep: int) -> Path:
    """Final per-run output dir: eval/runs/<cell>/<model>/run_NN/."""
    return runs_root() / cell / model / f"run_{rep:02d}"


def progress_path() -> Path:
    return runs_root() / "_progress.json"


def verify_design_default_run_dir(cell: str) -> Path:
    """Where ``speceval.cli verify-design`` writes its run dir.

    `_design_run_dir(feature_id)` in `speceval/cli.py` resolves to
    ``<repo>/runs/<feature_id>/``, and `feature_id = feature_dir.name`
    where `feature_dir` is the positional argument to `verify-design`.
    Since we pass `eval/specs/<cell>/`, the feature_id is just `<cell>`.
    """
    return repo_root() / "runs" / cell


# ---------------------------------------------------------------------------
# Progress tracking
# ---------------------------------------------------------------------------

def _utcnow_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def is_run_complete(cell: str, model: str, rep: int) -> bool:
    """A run is 'complete' if all COMPLETE_RUN_FILES exist on disk.

    PARSE_FAIL runs (where Alloy didn't produce verdicts) still count as
    complete data — they have feature_model.als + manifest.json +
    cost_log.json, just no alloy_verdicts.json. We skip them on resume
    because re-running would burn another ~$1 of API for the same
    PARSE_FAIL outcome (cells are pinned, so the LLM input is identical
    across replicates modulo Monte Carlo).
    """
    rd = cell_run_dir(cell, model, rep)
    if not rd.is_dir():
        return False
    return all((rd / f).exists() for f in COMPLETE_RUN_FILES)


def load_progress() -> dict:
    p = progress_path()
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def save_progress(progress: dict) -> None:
    p = progress_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    # Atomic write — first to a sibling tmp file then rename.
    tmp = p.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(progress, indent=2), encoding="utf-8")
    tmp.replace(p)


def _empty_progress(
    *,
    plan_runs: list[tuple[str, str, int]],
    started_at: str,
) -> dict:
    return {
        "started_at": started_at,
        "last_completed": None,
        "total_planned": len(plan_runs),
        "runs_done": 0,
        "cells_done": 0,
        "total_cost_usd": 0.0,
        "total_elapsed_seconds": 0.0,
        "runs": {},  # f"{cell}/{model}/run_{rep:02d}" → per-run record
    }


# ---------------------------------------------------------------------------
# Single-run execution
# ---------------------------------------------------------------------------

def run_one(
    *,
    cell: str,
    model: str,
    rep: int,
    java_bin: str,
    python_bin: str,
    repo: Path,
) -> dict:
    """Invoke verify-design for one (cell, model, rep) and stage outputs.

    Returns a record dict suitable for stashing in `progress["runs"][...]`.

    Never raises on subprocess failure — failures are recorded and the
    caller continues to the next run.
    """
    record: dict = {
        "cell": cell,
        "model": model,
        "rep": rep,
        "started_at": _utcnow_iso(),
        "status": "started",
    }
    started_perf = time.perf_counter()

    spec_dir = cell_spec_dir(cell)
    if not spec_dir.is_dir():
        record.update(
            status="failed",
            error=f"spec dir not found: {spec_dir}",
            elapsed_seconds=0.0,
        )
        return record

    # Sanity: ensure the previous verify-design `runs/<cell>/` dir from
    # a prior aborted run isn't lurking. We move it aside (timestamped)
    # rather than deleting so any in-flight inspection still has the
    # artefacts.
    default_dir = verify_design_default_run_dir(cell)
    if default_dir.exists():
        stash = default_dir.with_name(
            f"{cell}.preempted-{int(time.time())}"
        )
        try:
            default_dir.rename(stash)
        except OSError as e:
            record.update(
                status="failed",
                error=f"couldn't stash stale {default_dir}: {e}",
                elapsed_seconds=time.perf_counter() - started_perf,
            )
            return record

    # ----------------------------------------------------------------
    # Shell out to verify-design.
    # ----------------------------------------------------------------
    cmd = [
        python_bin, "-m", "speceval.cli", "verify-design",
        "--no-cache",
        "--model", model,
        "--java-bin", java_bin,
        str(spec_dir),
    ]
    log_path = cell_run_dir(cell, model, rep).parent / f"run_{rep:02d}.log"
    log_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        with log_path.open("w", encoding="utf-8") as logf:
            logf.write(f"$ {' '.join(cmd)}\n\n")
            logf.flush()
            proc = subprocess.run(
                cmd,
                cwd=str(repo),
                stdout=logf,
                stderr=subprocess.STDOUT,
                check=False,
            )
        record["exit_code"] = proc.returncode
    except OSError as e:
        record.update(
            status="failed",
            error=f"subprocess invocation failed: {e}",
            elapsed_seconds=time.perf_counter() - started_perf,
        )
        return record

    # ----------------------------------------------------------------
    # Move the produced runs/<cell>/ to eval/runs/<cell>/<model>/run_NN/.
    # ----------------------------------------------------------------
    target = cell_run_dir(cell, model, rep)
    if target.exists():
        # Defensive — should not happen because is_run_complete() gates this.
        shutil.rmtree(target)
    target.parent.mkdir(parents=True, exist_ok=True)

    moved = False
    if default_dir.exists():
        try:
            shutil.move(str(default_dir), str(target))
            moved = True
        except OSError as e:
            record["move_error"] = str(e)
    else:
        record["move_error"] = (
            f"verify-design did not produce {default_dir}"
        )

    record["elapsed_seconds"] = round(time.perf_counter() - started_perf, 3)

    # ----------------------------------------------------------------
    # Classify outcome from the moved artefacts.
    # ----------------------------------------------------------------
    if not moved:
        record["status"] = "failed"
        return record

    # Pull cost (always present if cli.py reached the write_cost_log call —
    # which it does pre-Alloy, so even PARSE_FAIL runs have it).
    cost_log = target / "cost_log.json"
    if cost_log.exists():
        try:
            cd = json.loads(cost_log.read_text(encoding="utf-8"))
            record["cost_usd"] = cd.get("cost_usd")
            record["lift_elapsed_seconds"] = cd.get("elapsed_seconds")
        except json.JSONDecodeError:
            pass

    have_complete = all((target / f).exists() for f in COMPLETE_RUN_FILES)
    have_healthy = have_complete and all(
        (target / f).exists() for f in HEALTHY_RUN_FILES
    )

    if have_healthy:
        record["status"] = "ok"
    elif have_complete:
        record["status"] = "parse_fail"
    else:
        record["status"] = "incomplete"

    record["completed_at"] = _utcnow_iso()
    return record


# ---------------------------------------------------------------------------
# Sweep driver
# ---------------------------------------------------------------------------

def build_plan(
    cells: Iterable[str],
    models: Iterable[str],
    reps: int,
) -> list[tuple[str, str, int]]:
    """All (cell, model, rep) triples, ordered cell-major.

    Cell-major ordering means each cell's 10 replicates run consecutively,
    so a partial sweep still produces useful per-cell summaries.
    """
    plan: list[tuple[str, str, int]] = []
    for cell in cells:
        for model in models:
            for rep in range(1, reps + 1):
                plan.append((cell, model, rep))
    return plan


def plan_key(cell: str, model: str, rep: int) -> str:
    return f"{cell}/{model}/run_{rep:02d}"


def _cells_done_count(progress: dict, cells: Iterable[str], models: Iterable[str], reps: int) -> int:
    done = 0
    for cell in cells:
        per_cell_complete = True
        for model in models:
            for rep in range(1, reps + 1):
                key = plan_key(cell, model, rep)
                rec = progress.get("runs", {}).get(key)
                if not rec or rec.get("status") not in {"ok", "parse_fail"}:
                    per_cell_complete = False
                    break
            if not per_cell_complete:
                break
        if per_cell_complete:
            done += 1
    return done


def run_sweep(
    *,
    cells: list[str],
    models: list[str],
    reps: int,
    java_bin: str,
    python_bin: str,
    repo: Path,
) -> dict:
    """Run every planned (cell, model, rep) that isn't already on disk.

    Returns the final progress dict.
    """
    runs_root().mkdir(parents=True, exist_ok=True)
    plan = build_plan(cells, models, reps)
    progress = load_progress() or _empty_progress(
        plan_runs=plan,
        started_at=_utcnow_iso(),
    )
    # If the saved plan size doesn't match (we're running a subset/superset),
    # update the planned count but keep prior run records.
    progress["total_planned"] = len(plan)
    progress.setdefault("runs", {})
    progress.setdefault("total_cost_usd", 0.0)
    progress.setdefault("total_elapsed_seconds", 0.0)

    save_progress(progress)

    print(f"[harness] {len(plan)} planned runs over "
          f"{len(cells)} cells × {len(models)} models × {reps} reps")
    print(f"[harness] eval/runs/ root: {runs_root()}")

    for cell, model, rep in plan:
        key = plan_key(cell, model, rep)

        if is_run_complete(cell, model, rep):
            existing = progress["runs"].get(key)
            if existing and existing.get("status") in {"ok", "parse_fail"}:
                print(f"[skip]    {key} — already complete ({existing.get('status')})")
            else:
                # Reconstruct minimal record from disk so progress.json
                # reflects on-disk reality across resumes.
                rd = cell_run_dir(cell, model, rep)
                cost_log = rd / "cost_log.json"
                status = ("ok" if all((rd / f).exists() for f in HEALTHY_RUN_FILES)
                          else "parse_fail")
                rec = {
                    "cell": cell, "model": model, "rep": rep,
                    "status": status, "reconstructed_from_disk": True,
                }
                if cost_log.exists():
                    try:
                        cd = json.loads(cost_log.read_text(encoding="utf-8"))
                        rec["cost_usd"] = cd.get("cost_usd")
                        rec["lift_elapsed_seconds"] = cd.get("elapsed_seconds")
                    except json.JSONDecodeError:
                        pass
                progress["runs"][key] = rec
                progress["runs_done"] = sum(
                    1 for r in progress["runs"].values()
                    if r.get("status") in {"ok", "parse_fail"}
                )
                progress["cells_done"] = _cells_done_count(
                    progress, cells, models, reps
                )
                save_progress(progress)
                print(f"[skip]    {key} — already on disk ({status})")
            continue

        print(f"[run]     {key}")
        rec = run_one(
            cell=cell, model=model, rep=rep,
            java_bin=java_bin, python_bin=python_bin, repo=repo,
        )
        progress["runs"][key] = rec

        if rec.get("status") in {"ok", "parse_fail"}:
            progress["last_completed"] = key
            if rec.get("cost_usd") is not None:
                progress["total_cost_usd"] += float(rec["cost_usd"])
            if rec.get("elapsed_seconds") is not None:
                progress["total_elapsed_seconds"] += float(rec["elapsed_seconds"])

        progress["runs_done"] = sum(
            1 for r in progress["runs"].values()
            if r.get("status") in {"ok", "parse_fail"}
        )
        progress["cells_done"] = _cells_done_count(progress, cells, models, reps)
        save_progress(progress)

        status = rec.get("status", "?")
        cost = rec.get("cost_usd")
        elapsed = rec.get("elapsed_seconds")
        cost_s = f"${cost:.3f}" if isinstance(cost, (int, float)) else "?"
        elapsed_s = f"{elapsed:.0f}s" if isinstance(elapsed, (int, float)) else "?"
        print(f"          → {status}  cost={cost_s}  wall={elapsed_s}")

    return progress


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _parse_cell_list(arg: str) -> list[str]:
    items = [c.strip() for c in arg.split(",") if c.strip()]
    bad = [c for c in items if c not in ALL_CELLS]
    if bad:
        raise argparse.ArgumentTypeError(
            f"unknown cell(s): {', '.join(bad)}; "
            f"choose from {', '.join(ALL_CELLS)}"
        )
    return items


def _parse_model_list(arg: str) -> list[str]:
    items = [m.strip() for m in arg.split(",") if m.strip()]
    bad = [m for m in items if m not in ACCEPTED_MODELS]
    if bad:
        raise argparse.ArgumentTypeError(
            f"unknown model(s): {', '.join(bad)}; "
            f"choose from {', '.join(ACCEPTED_MODELS)}"
        )
    for m in items:
        if m not in VALIDATED_MODELS:
            print(
                f"[warning] model {m!r} is NOT validated for Stage 1 "
                f"(only {VALIDATED_MODELS} is). Proceeding anyway.",
                file=sys.stderr,
            )
    return items


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="run_experiment.py",
        description="Stage 1 AQS sweep harness (Phase E2).",
    )
    parser.add_argument(
        "--cells",
        type=_parse_cell_list,
        default=list(ALL_CELLS),
        help=(
            "Comma-separated list of cells to run (default: all 9). "
            f"Choices: {', '.join(ALL_CELLS)}."
        ),
    )
    parser.add_argument(
        "--models",
        type=_parse_model_list,
        default=list(VALIDATED_MODELS),
        help=(
            "Comma-separated list of model tiers (default: M-best). "
            "Only M-best is validated for Stage 1; M-mid/M-small are "
            "accepted syntactically but not validated."
        ),
    )
    parser.add_argument(
        "--reps",
        type=int,
        default=10,
        help="Replicates per (cell, model) (default: 10).",
    )
    parser.add_argument(
        "--java-bin",
        default=os.environ.get("JDK4PY_JAVA", "java"),
        help=(
            "Java executable to pass through to verify-design "
            "(default: $JDK4PY_JAVA or `java` on PATH)."
        ),
    )
    parser.add_argument(
        "--python-bin",
        default=sys.executable,
        help="Python interpreter to use for the speceval.cli subprocess.",
    )
    args = parser.parse_args(argv)

    repo = repo_root()
    print(f"[harness] repo:   {repo}")
    print(f"[harness] python: {args.python_bin}")
    print(f"[harness] java:   {args.java_bin}")
    print(f"[harness] cells:  {args.cells}")
    print(f"[harness] models: {args.models}")
    print(f"[harness] reps:   {args.reps}")

    progress = run_sweep(
        cells=args.cells,
        models=args.models,
        reps=args.reps,
        java_bin=args.java_bin,
        python_bin=args.python_bin,
        repo=repo,
    )

    # ----------------------------------------------------------------
    # Final summary
    # ----------------------------------------------------------------
    print()
    print("=" * 64)
    print("  Stage 1 sweep summary")
    print("=" * 64)
    print(f"  total planned     : {progress['total_planned']}")
    print(f"  runs done         : {progress['runs_done']}")
    print(f"  cells done        : {progress['cells_done']}")
    print(f"  last completed    : {progress.get('last_completed')}")
    print(f"  total cost (USD)  : ${progress['total_cost_usd']:.3f}")
    print(f"  total wall (sec)  : {progress['total_elapsed_seconds']:.0f}s")
    print()

    runs_done = progress["runs_done"]
    planned = progress["total_planned"]
    return 0 if runs_done == planned else 1


if __name__ == "__main__":
    sys.exit(main())
