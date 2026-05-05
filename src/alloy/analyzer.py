import subprocess
import tempfile
import shutil
import json
import os
from dataclasses import dataclass, field


@dataclass
class CommandResult:
    """Result of a single Alloy run/check command."""
    command: str
    is_check: bool
    satisfiable: bool

    @property
    def passed(self) -> bool:
        """For checks: passes when no counterexample found (assertion holds).
        For runs: passes when an instance is found (predicate is consistent)."""
        if self.is_check:
            return not self.satisfiable
        return self.satisfiable


@dataclass
class AnalysisResult:
    """Result of running the Alloy Analyzer on a model."""
    raw_output: str
    commands: list[CommandResult] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    @property
    def all_passed(self) -> bool:
        return len(self.errors) == 0 and all(c.passed for c in self.commands)


_DEFAULT_JAR = os.path.join(
    os.path.dirname(__file__), "..", "..", "lib", "org.alloytools.alloy.dist.jar"
)


class AlloyAnalyzer:
    def __init__(self, jar_path: str | None = None):
        self.jar_path = jar_path or os.getenv("ALLOY_JAR_PATH", _DEFAULT_JAR)

    def analyze(self, alloy_source: str, timeout: int = 60) -> AnalysisResult:
        jar = os.path.abspath(self.jar_path)
        if not os.path.isfile(jar):
            raise FileNotFoundError(
                f"Alloy JAR not found at {jar}. Download org.alloytools.alloy.dist.jar "
                f"and place it in lib/ or set ALLOY_JAR_PATH."
            )

        tmp_dir = tempfile.mkdtemp()
        als_path = os.path.join(tmp_dir, "model.als")
        out_dir = os.path.join(tmp_dir, "output")

        with open(als_path, "w") as f:
            f.write(alloy_source)

        try:
            proc = subprocess.run(
                [
                    "java",
                    "-jar", jar,
                    "exec",
                    "-c", "*",
                    "-o", out_dir,
                    als_path,
                ],
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            return AnalysisResult(
                raw_output="",
                errors=[f"Alloy Analyzer timed out after {timeout}s"],
            )
        finally:
            raw_output = ""

        raw_output = proc.stdout + proc.stderr

        if proc.returncode != 0:
            return AnalysisResult(
                raw_output=raw_output,
                errors=[raw_output.strip()],
            )

        receipt_path = os.path.join(out_dir, "receipt.json")
        try:
            with open(receipt_path) as f:
                receipt = json.load(f)
            return self._parse_receipt(receipt, raw_output)
        except (FileNotFoundError, json.JSONDecodeError) as e:
            return AnalysisResult(
                raw_output=raw_output,
                errors=[f"Failed to read Alloy receipt: {e}"],
            )
        finally:
            shutil.rmtree(tmp_dir, ignore_errors=True)

    def _parse_receipt(self, receipt: dict, raw_output: str) -> AnalysisResult:
        result = AnalysisResult(raw_output=raw_output)

        for name, cmd in receipt.get("commands", {}).items():
            cmd_type = cmd.get("type", "").lower()
            is_check = cmd_type == "check"
            # A command is satisfiable if it has solutions
            satisfiable = "solution" in cmd and len(cmd["solution"]) > 0

            result.commands.append(
                CommandResult(
                    command=f"{cmd_type} {name}",
                    is_check=is_check,
                    satisfiable=satisfiable,
                )
            )

        return result
