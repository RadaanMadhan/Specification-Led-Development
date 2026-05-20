"""speceval.runner — invoke the Alloy Analyzer CLI and parse results."""

from __future__ import annotations

import re
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path


@dataclass
class CheckResult:
    """The outcome of one Alloy `check` command."""
    name: str                       # e.g. "KPI_G_001"
    passed: bool                    # True if no counterexample
    raw_line: str                   # the raw Alloy verdict line, for debugging


@dataclass
class RunOutcome:
    """The full transcript and per-check results from one Alloy run."""
    results: list[CheckResult]
    stdout: str
    stderr: str
    returncode: int

    def by_name(self) -> dict[str, CheckResult]:
        return {r.name: r for r in self.results}


# Alloy 6.x: "00. check KPI_G_001  0  UNSAT" or "01. check KPI_G_002  0  1/1  SAT"
RE_CHECK_RESULT = re.compile(
    r"^\s*\d+\.\s+check\s+(?P<name>\w+)\b.*?\b(?P<verdict>UNSAT|SAT)\s*$"
)
# Legacy multi-line format fallback.
RE_EXECUTING_LEGACY = re.compile(r'Executing\s+"Check\s+(?P<name>\w+)\s+')
RE_VERDICT_PASS_LEGACY = re.compile(r"No counterexample found", re.IGNORECASE)
RE_VERDICT_FAIL_LEGACY = re.compile(r"Counterexample found", re.IGNORECASE)


def assemble(domain_als: Path, kpi_library_als: Path, snapshot_als: Path) -> str:
    """Concatenate the three files into one Alloy module body."""
    parts = [
        "// === auto-assembled by speceval.runner ===",
        f"// from: {domain_als}",
        domain_als.read_text(encoding="utf-8"),
        f"// from: {kpi_library_als}",
        kpi_library_als.read_text(encoding="utf-8"),
        f"// from: {snapshot_als}",
        snapshot_als.read_text(encoding="utf-8"),
    ]
    return "\n".join(parts)


def run_alloy_file(
    als_path: Path,
    *,
    alloy_jar: Path,
    java_bin: str = "java",
    timeout_seconds: int = 120,
) -> RunOutcome:
    """Run Alloy on a self-contained .als file."""
    with tempfile.TemporaryDirectory(prefix="speceval_") as workdir:
        workdir_p = Path(workdir)
        local_als = workdir_p / "model.als"
        local_als.write_text(als_path.read_text(encoding="utf-8"), encoding="utf-8")

        try:
            proc = subprocess.run(
                [java_bin, "-jar", str(alloy_jar.resolve()), "exec", str(local_als)],
                capture_output=True,
                text=True,
                timeout=timeout_seconds,
                cwd=workdir,
            )
        except FileNotFoundError as e:
            raise RuntimeError(
                f"Could not invoke Java. Make sure `java` is on PATH or pass java_bin. "
                f"Original error: {e}"
            )
        except subprocess.TimeoutExpired as e:
            raise RuntimeError(
                f"Alloy run timed out after {timeout_seconds}s. "
                f"Partial stdout:\n{e.stdout!r}"
            )

    combined = (proc.stdout or "") + "\n" + (proc.stderr or "")
    return RunOutcome(
        results=parse_alloy_output(combined),
        stdout=proc.stdout,
        stderr=proc.stderr,
        returncode=proc.returncode,
    )


def run_alloy(
    *,
    domain_als: Path,
    kpi_library_als: Path,
    snapshot_als: Path,
    alloy_jar: Path,
    java_bin: str = "java",
    timeout_seconds: int = 60,
    keep_assembled_path: Path | None = None,
) -> RunOutcome:
    """Run Alloy on the assembled (concatenated) model."""
    body = assemble(domain_als, kpi_library_als, snapshot_als)

    if keep_assembled_path:
        keep_assembled_path.write_text(body, encoding="utf-8")

    with tempfile.TemporaryDirectory(prefix="speceval_") as workdir:
        workdir_p = Path(workdir)
        als_path = workdir_p / "model.als"
        als_path.write_text(body, encoding="utf-8")

        try:
            proc = subprocess.run(
                [java_bin, "-jar", str(alloy_jar.resolve()), "exec", str(als_path)],
                capture_output=True,
                text=True,
                timeout=timeout_seconds,
                cwd=workdir,
            )
        except FileNotFoundError as e:
            raise RuntimeError(
                f"Could not invoke Java. Make sure `java` is on PATH or pass java_bin. "
                f"Original error: {e}"
            )
        except subprocess.TimeoutExpired as e:
            raise RuntimeError(
                f"Alloy run timed out after {timeout_seconds}s. "
                f"Partial stdout:\n{e.stdout!r}"
            )

    combined = (proc.stdout or "") + "\n" + (proc.stderr or "")
    results = parse_alloy_output(combined)
    return RunOutcome(
        results=results,
        stdout=proc.stdout,
        stderr=proc.stderr,
        returncode=proc.returncode,
    )


def parse_alloy_output(stdout: str) -> list[CheckResult]:
    """Extract per-check PASS/FAIL verdicts from Alloy output."""
    results: list[CheckResult] = []

    # --- Alloy 6.x format: one line per check ---
    for raw_line in stdout.splitlines():
        m = RE_CHECK_RESULT.match(raw_line)
        if m:
            verdict = m.group("verdict").upper()
            results.append(
                CheckResult(
                    name=m.group("name"),
                    passed=(verdict == "UNSAT"),
                    raw_line=raw_line.strip(),
                )
            )
    if results:
        return results

    # --- Legacy multi-line fallback ---
    pending_name: str | None = None
    for raw_line in stdout.splitlines():
        line = raw_line.strip()
        m = RE_EXECUTING_LEGACY.search(line)
        if m:
            pending_name = m.group("name")
            continue
        if pending_name is None:
            continue
        if RE_VERDICT_PASS_LEGACY.search(line):
            results.append(CheckResult(name=pending_name, passed=True, raw_line=line))
            pending_name = None
        elif RE_VERDICT_FAIL_LEGACY.search(line):
            results.append(CheckResult(name=pending_name, passed=False, raw_line=line))
            pending_name = None

    return results


def default_alloy_jar() -> Path:
    """Return the bundled tools/alloy.jar path relative to the project root."""
    here = Path(__file__).resolve()
    return here.parent.parent / "tools" / "alloy.jar"


def default_alloy_dir() -> Path:
    """Return the bundled alloy/ directory (domain.als and kpi_library.als)."""
    here = Path(__file__).resolve()
    return here.parent.parent / "alloy"


if __name__ == "__main__":  # quick manual test against an existing snapshot
    import sys
    out = run_alloy(
        domain_als=default_alloy_dir() / "domain.als",
        kpi_library_als=default_alloy_dir() / "kpi_library.als",
        snapshot_als=Path(sys.argv[1]),
        alloy_jar=default_alloy_jar(),
    )
    for r in out.results:
        verdict = "PASS" if r.passed else "FAIL"
        print(f"  {r.name:12s}  {verdict}    [{r.raw_line}]")
    if out.returncode != 0:
        print(f"\n(alloy exited with code {out.returncode})", file=sys.stderr)
