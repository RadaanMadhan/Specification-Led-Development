"""runner.py — invoke the Alloy Analyzer CLI and parse results.

Concatenates the three Alloy files (domain + KPI library + snapshot) into
a single temporary file, runs `java -jar alloy.jar exec <file>`, captures
stdout, and parses out a per-`check` PASS/FAIL verdict.

For the PoC we use Alloy's text output. A future iteration could instead
write XML instances via the Alloy Java API and surface counterexample
atoms in the report.
"""

from __future__ import annotations

import re
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path


# ---------------------------------------------------------------------------
# Result types
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# CLI invocation
# ---------------------------------------------------------------------------

# Alloy 6.x prints one line per command in the form:
#   "00. check KPI_G_001                0       UNSAT"
#   "01. check KPI_G_002                0    1/1     SAT"
# UNSAT lines have one number column; SAT lines have an extra `<n>/<m>`
# instance counter. Both end in the verdict word.
# We accept any whitespace-separated tokens between the name and the verdict.
RE_CHECK_RESULT = re.compile(
    r"^\s*\d+\.\s+check\s+(?P<name>\w+)\b.*?\b(?P<verdict>UNSAT|SAT)\s*$"
)
# Older Alloy versions used multi-line text output ("No counterexample found").
# Keep these as a fallback so the runner works against either format.
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
    """Run Alloy on the assembled model and parse per-check results.

    `keep_assembled_path` (optional) writes a copy of the concatenated
    Alloy file to that path for debugging. Useful when an Alloy syntax
    error needs human inspection.
    """
    body = assemble(domain_als, kpi_library_als, snapshot_als)

    if keep_assembled_path:
        keep_assembled_path.write_text(body, encoding="utf-8")

    # Run inside a fresh tempdir so Alloy's per-model output directory
    # (which it creates next to the input file in cwd) is auto-cleaned.
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

    # Alloy 6.x writes the per-check verdict lines to STDERR, not stdout.
    # Parse both streams to be tolerant of either.
    combined = (proc.stdout or "") + "\n" + (proc.stderr or "")
    results = parse_alloy_output(combined)
    return RunOutcome(
        results=results,
        stdout=proc.stdout,
        stderr=proc.stderr,
        returncode=proc.returncode,
    )


def parse_alloy_output(stdout: str) -> list[CheckResult]:
    """Walk the Alloy stdout and extract one CheckResult per `check` command.

    Tries the Alloy 6.x single-line format first, then falls back to the
    older multi-line "Executing... / No counterexample found" format if
    nothing matched.
    """
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


# ---------------------------------------------------------------------------
# Resolve `tools/alloy.jar` relative to the package
# ---------------------------------------------------------------------------

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
