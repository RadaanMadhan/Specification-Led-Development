"""Smoke tests for the parser. Runs without pytest if needed."""

from __future__ import annotations

from pathlib import Path

from speceval.parser import parse_spec


HERE = Path(__file__).resolve().parent
TINY = HERE / "fixtures" / "tiny_spec.md"


def test_tiny_spec() -> None:
    p = parse_spec(TINY)
    assert p.feature_name == "Hello World CLI"
    assert len(p.user_stories) == 1
    assert len(p.user_stories[0].scenarios) == 2
    assert len(p.requirements) == 2
    assert p.requirements[0].id == "FR-001"
    s1 = p.user_stories[0].scenarios[0]
    assert "shell prompt" in s1.given
    assert "run `hello`" in s1.when
    assert "Hello, world" in s1.then


def test_pomodoro_spec_present() -> None:
    """If the speckit-trial spec is reachable, basic counts should match."""
    pomodoro = (
        HERE.parent.parent.parent
        / "speckit-trial" / "specs" / "001-pomo-cli" / "spec.md"
    )
    if not pomodoro.exists():
        return
    p = parse_spec(pomodoro)
    assert len(p.user_stories) == 4
    assert len(p.all_scenarios) == 15
    assert len(p.requirements) == 14


if __name__ == "__main__":
    test_tiny_spec()
    test_pomodoro_spec_present()
    print("OK — parser smoke tests passed.")
