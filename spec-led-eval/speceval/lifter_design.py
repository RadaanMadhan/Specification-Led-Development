"""speceval.lifter_design — Phase-3 design-mode lifter.

Reads patterns.md plus a Speckit feature folder (spec.md, data-model.md,
contracts/http-api.md), asks Claude Opus to author one self-contained
`feature_model.als`, and returns:

    DesignLiftPackage(
        feature_id              = "002-bank-transfer-audit",
        feature_model_als       = "<alloy source>",
        manifest                = {patterns_applied, fr_assertion_map,
                                   mutation_targets, ...},
        cache_hit               = bool,
        sha                     = "<input sha256>",
        model                   = "claude-opus-4-6",
    )

The output `feature_model.als` is intended to run STANDALONE under
`alloy.jar exec` — it does not depend on `domain.als` or `kpi_library.als`.

Caching is content-addressed by sha256 over the four input artefacts plus
the prompt text, so the lift is idempotent across re-runs. The cache layout
mirrors `lifter.py`:

    cache/lifts_design/<sha256>.json   { "als": "...", "manifest": {...},
                                          "model": "...", "sha": "..." }

Once a fresh lift has been done, the produced .als is also written to
`runs/<feature-id>/feature_model.als` (the canonical inspection location).
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from pathlib import Path

from speceval.prompts import (
    DESIGN_LIFT_SYSTEM_PROMPT,
    build_design_lift_prompt,
)
from speceval.providers import Provider


# ---------------------------------------------------------------------------
# Result types
# ---------------------------------------------------------------------------

@dataclass
class DesignInputs:
    """The raw artefacts the lifter consumes for one feature."""
    feature_id: str
    patterns_md: str
    spec_md: str
    data_model_md: str
    http_api_md: str


@dataclass
class DesignLiftPackage:
    """Everything the CLI needs to drive Alloy + render the report."""
    feature_id: str
    feature_model_als: str
    manifest: dict
    cache_hit: bool
    sha: str
    model: str


class DesignLiftError(RuntimeError):
    pass


# ---------------------------------------------------------------------------
# Public entry points
# ---------------------------------------------------------------------------

def load_design_inputs(feature_dir: Path, *, patterns_md_path: Path) -> DesignInputs:
    """Read the four Speckit artefacts plus patterns.md from disk.

    `feature_dir` is the Speckit feature folder, e.g.
        speckit-trial/specs/002-bank-transfer-audit/

    Required files inside `feature_dir`:
        spec.md
        data-model.md
        contracts/http-api.md

    `patterns_md_path` is typically `spec-led-eval/patterns.md`.
    """
    feature_dir = feature_dir.resolve()
    if not feature_dir.is_dir():
        raise DesignLiftError(f"feature folder not found: {feature_dir}")

    spec_path = feature_dir / "spec.md"
    data_model_path = feature_dir / "data-model.md"
    http_api_path = feature_dir / "contracts" / "http-api.md"

    missing = [
        str(p) for p in (spec_path, data_model_path, http_api_path)
        if not p.exists()
    ]
    if missing:
        raise DesignLiftError(
            "feature folder is missing required artefacts:\n  - "
            + "\n  - ".join(missing)
        )
    if not patterns_md_path.exists():
        raise DesignLiftError(f"patterns.md not found at {patterns_md_path}")

    return DesignInputs(
        feature_id=feature_dir.name,
        patterns_md=patterns_md_path.read_text(encoding="utf-8"),
        spec_md=spec_path.read_text(encoding="utf-8"),
        data_model_md=data_model_path.read_text(encoding="utf-8"),
        http_api_md=http_api_path.read_text(encoding="utf-8"),
    )


def lift_design(
    inputs: DesignInputs,
    *,
    provider: Provider,
    cache_dir: Path,
    use_cache: bool = True,
) -> DesignLiftPackage:
    """Lift a feature folder into a feature_model.als via one LLM call.

    Caches by SHA-256 over the four artefacts plus the model name plus the
    system-prompt text, so a change to patterns.md or the prompt forces a
    fresh lift.
    """
    sha = _design_sha(inputs, model=provider.model)
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_path = cache_dir / f"{sha}.json"

    if use_cache and cache_path.exists():
        cached = json.loads(cache_path.read_text(encoding="utf-8"))
        return DesignLiftPackage(
            feature_id=inputs.feature_id,
            feature_model_als=cached["als"],
            manifest=cached.get("manifest", {}) or {},
            cache_hit=True,
            sha=sha,
            model=cached.get("model", provider.model),
        )

    user_prompt = build_design_lift_prompt(
        feature_id=inputs.feature_id,
        patterns_md=inputs.patterns_md,
        spec_md=inputs.spec_md,
        data_model_md=inputs.data_model_md,
        http_api_md=inputs.http_api_md,
    )

    raw = provider.complete(
        system=DESIGN_LIFT_SYSTEM_PROMPT,
        user=user_prompt,
        # The Alloy model + manifest can be sizeable; give the model room.
        max_tokens=16000,
    )

    als_text, manifest = _parse_response(raw)

    cache_payload = {
        "als": als_text,
        "manifest": manifest,
        "model": provider.model,
        "sha": sha,
        "feature_id": inputs.feature_id,
    }
    cache_path.write_text(json.dumps(cache_payload, indent=2), encoding="utf-8")

    return DesignLiftPackage(
        feature_id=inputs.feature_id,
        feature_model_als=als_text,
        manifest=manifest,
        cache_hit=False,
        sha=sha,
        model=provider.model,
    )


def write_feature_model(pkg: DesignLiftPackage, run_dir: Path) -> Path:
    """Write the lifted feature_model.als + manifest into `runs/<feature-id>/`.

    Returns the path of the written .als file.
    """
    run_dir.mkdir(parents=True, exist_ok=True)
    als_path = run_dir / "feature_model.als"
    als_path.write_text(pkg.feature_model_als, encoding="utf-8")
    manifest_path = run_dir / "feature_model.manifest.json"
    manifest_path.write_text(
        json.dumps(pkg.manifest, indent=2), encoding="utf-8"
    )
    return als_path


# ---------------------------------------------------------------------------
# Mutation testing
# ---------------------------------------------------------------------------

@dataclass
class MutationSpec:
    fact_name: str
    asserts_violated: list[str]
    rationale: str
    inject_violation: str = ""    # optional Alloy fact-body snippet


def parse_mutation_targets(manifest: dict) -> list[MutationSpec]:
    """Pull the mutation_targets list out of a manifest into typed specs."""
    out: list[MutationSpec] = []
    for raw in manifest.get("mutation_targets", []) or []:
        if not isinstance(raw, dict):
            continue
        fact_name = str(raw.get("fact_name", "")).strip()
        asserts = [str(a) for a in (raw.get("asserts_violated") or [])]
        rationale = str(raw.get("rationale", "")).strip()
        inject = str(raw.get("inject_violation", "")).strip()
        if fact_name and asserts:
            out.append(
                MutationSpec(
                    fact_name=fact_name,
                    asserts_violated=asserts,
                    rationale=rationale,
                    inject_violation=inject,
                )
            )
    return out


# Capture the body of `fact F_Name { ... }`, allowing nested braces inside the
# body. Alloy facts don't typically nest braces deeply, but quantifier
# bodies can — the regex therefore uses a balanced-up-to-1-level handler.
_RE_NAMED_FACT = re.compile(
    r"(fact\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*)"
    r"\{(?P<body>(?:[^{}]|\{[^{}]*\})*)\}",
    re.DOTALL,
)


def emit_mutated_als(
    feature_model_als: str,
    *,
    fact_name: str,
    inject_violation: str = "",
) -> str:
    """Return a copy of the model with `fact F_<fact_name>` blanked.

    Two-step mutation:

    1. Clear the body of the named fact (replace with `{}`). This removes
       the most direct enforcement of whatever invariant the fact was
       guarding. Other named facts are untouched.

    2. If `inject_violation` is provided, append it verbatim at the end of
       the file as a fresh fact. The injection is an Alloy fact-body
       snippet (e.g.,
           `fact MUTATE_X { some disj a, b: AuditEntry | a.transaction = b.transaction }`)
       that forces a counterexample-to-the-targeted-assertion to exist
       within the Alloy scope.

    With clear-and-inject, the targeted assertion FAILs iff:
      - the cleared fact was load-bearing
      - AND no other fact independently re-enforces the constraint
      - AND the predicate is non-vacuous

    A still-PASSing mutated assertion therefore signals over-constraint
    (the property is enforced by multiple facts) or vacuity (the predicate
    doesn't bite on the injected counterexample).

    Raises DesignLiftError if `fact_name` isn't found.
    """
    target = fact_name.strip()
    if not target:
        raise DesignLiftError("emit_mutated_als: empty fact_name")

    found = {"hit": False}

    def _replace(m: re.Match) -> str:
        if m.group("name") == target:
            found["hit"] = True
            return f"fact {target} {{ /* MUTATED — body cleared by validator */ }}"
        return m.group(0)

    mutated = _RE_NAMED_FACT.sub(_replace, feature_model_als)
    if not found["hit"]:
        raise DesignLiftError(
            f"mutation target fact `{target}` not found in feature_model.als"
        )

    if inject_violation:
        # Append the violation injection at the end so it sits after every
        # existing constraint. The validator passes whatever the LLM gave
        # us — the LLM has full context to write a syntactically valid,
        # semantically meaningful counterexample-forcing fact.
        mutated = (
            mutated.rstrip()
            + "\n\n"
            + "// === MUTATION INJECTION (validator-appended) ===\n"
            + inject_violation.strip()
            + "\n"
        )
    return mutated


# ---------------------------------------------------------------------------
# Coverage analysis
# ---------------------------------------------------------------------------

# Match `assert <Name> { ... }` to enumerate every assertion present.
_RE_ASSERTION = re.compile(
    r"\bassert\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)\b\s*\{",
    re.MULTILINE,
)


def list_assertions(als_text: str) -> list[str]:
    """Return the names of every `assert` in `als_text`, in source order."""
    seen: list[str] = []
    seen_set: set[str] = set()
    for m in _RE_ASSERTION.finditer(als_text):
        name = m.group("name")
        if name not in seen_set:
            seen.append(name)
            seen_set.add(name)
    return seen


_RE_ANCHOR_LINE = re.compile(
    r"//\s*(?:PATTERN:\s*(?P<pat>[A-Za-z_][A-Za-z0-9_]*)|FEATURE-SPECIFIC)"
    r"\s*ANCHOR:\s*(?P<anchor>.+?)\s*$",
    re.MULTILINE,
)


def extract_anchors(als_text: str) -> dict[str, str]:
    """Return a {predicate-name: anchor-comment} mapping.

    Walks each `// PATTERN: X ANCHOR: Y` (or `// FEATURE-SPECIFIC ANCHOR: Y`)
    comment, then attaches it to the next `pred Name { ... }` declaration.
    """
    anchors: dict[str, str] = {}
    # Build a list of (line_index, anchor_text) and (line_index, pred_name)
    # then walk in source order, attaching each anchor to the first pred
    # that follows it.
    lines = als_text.splitlines()
    i = 0
    while i < len(lines):
        m = _RE_ANCHOR_LINE.search(lines[i])
        if not m:
            i += 1
            continue
        anchor_text = (
            f"PATTERN {m.group('pat')}"
            if m.group("pat")
            else "FEATURE-SPECIFIC"
        ) + f": {m.group('anchor').strip()}"
        # Look ahead for the next `pred X` or `assert X`
        j = i + 1
        while j < len(lines):
            mp = re.search(
                r"\b(?:pred|assert)\s+([A-Za-z_][A-Za-z0-9_]*)\b", lines[j]
            )
            if mp:
                anchors[mp.group(1)] = anchor_text
                break
            j += 1
        i += 1
    return anchors


def fr_coverage(
    fr_ids: list[str], manifest: dict, assertions: list[str]
) -> dict[str, list[str]]:
    """Map each FR-NNN to the assertion names that claim to cover it.

    First trusts manifest.fr_assertion_map (LLM-declared coverage); then
    augments with any assertion whose name follows the `FR_NNN_*` convention.
    """
    declared = manifest.get("fr_assertion_map") or {}
    coverage: dict[str, list[str]] = {fr: [] for fr in fr_ids}

    for fr in fr_ids:
        # 1. LLM-declared
        for a in declared.get(fr, []) or []:
            if a in assertions and a not in coverage[fr]:
                coverage[fr].append(a)
        # 2. Naming convention FR_NNN_* (allow either "FR-001" or "FR_001"
        #    in the assertion name).
        norm = fr.replace("-", "_")
        for a in assertions:
            if a.startswith(norm + "_") or a == norm:
                if a not in coverage[fr]:
                    coverage[fr].append(a)
    return coverage


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

def _design_sha(inputs: DesignInputs, *, model: str) -> str:
    """SHA-256 over the four artefacts + model + system-prompt text.

    We include the system prompt so a change to the prompt invalidates
    the cache automatically — otherwise the cached lift would be a stale
    artefact of an older prompt design.
    """
    h = hashlib.sha256()
    h.update(("model=" + model + "\n").encode("utf-8"))
    h.update(b"system_prompt=")
    h.update(DESIGN_LIFT_SYSTEM_PROMPT.encode("utf-8"))
    h.update(b"\nfeature_id=")
    h.update(inputs.feature_id.encode("utf-8"))
    for tag, body in (
        ("patterns", inputs.patterns_md),
        ("spec", inputs.spec_md),
        ("data_model", inputs.data_model_md),
        ("http_api", inputs.http_api_md),
    ):
        h.update(("\n[" + tag + "]\n").encode("utf-8"))
        h.update(body.encode("utf-8"))
    return h.hexdigest()


_RE_CODE_BLOCK = re.compile(
    r"```(?P<lang>[A-Za-z0-9_+-]*)\s*\n(?P<body>.*?)\n```",
    re.DOTALL,
)


def _parse_response(raw: str) -> tuple[str, dict]:
    """Pull the alloy and json fenced blocks out of the LLM response.

    Tolerates additional whitespace and an optional language tag. Falls
    back to the first two fenced blocks of any kind, in order, if the
    explicit `alloy` and `json` tags aren't used.
    """
    blocks = list(_RE_CODE_BLOCK.finditer(raw))
    if not blocks:
        raise DesignLiftError(
            "LLM response contained no fenced code blocks. "
            f"Raw start: {raw[:300]!r}"
        )

    als_text: str | None = None
    manifest_text: str | None = None
    for m in blocks:
        lang = (m.group("lang") or "").lower()
        body = m.group("body").strip()
        if als_text is None and lang in ("alloy", "als", ""):
            # Heuristic: the first block that "looks like" Alloy goes first.
            # Alloy bodies typically contain `sig`, `pred`, or `fact`.
            if any(tok in body for tok in ("sig ", "pred ", "fact ", "assert ")):
                als_text = body
                continue
        if manifest_text is None and lang == "json":
            manifest_text = body
            continue

    # Final fallbacks: if we got an alloy block but no json block tagged,
    # try to pick the last block as the manifest.
    if als_text is None:
        # Take the first block that looks like Alloy
        for m in blocks:
            body = m.group("body").strip()
            if any(tok in body for tok in ("sig ", "pred ", "fact ", "assert ")):
                als_text = body
                break
    if als_text is None:
        raise DesignLiftError(
            "LLM response did not contain an Alloy code block. "
            f"Found {len(blocks)} fenced block(s) but none looked like Alloy."
        )

    if manifest_text is None:
        # Take the last block that parses as JSON
        for m in reversed(blocks):
            body = m.group("body").strip()
            if body.startswith("{"):
                manifest_text = body
                break

    manifest: dict = {}
    if manifest_text is not None:
        try:
            manifest = json.loads(manifest_text)
        except json.JSONDecodeError as e:
            raise DesignLiftError(
                "LLM response contained a JSON block that did not parse: "
                f"{e}\nRaw start: {manifest_text[:300]!r}"
            )
        if not isinstance(manifest, dict):
            raise DesignLiftError(
                "LLM JSON manifest must be an object, got "
                f"{type(manifest).__name__}"
            )
    # No manifest is non-fatal — coverage analysis falls back on naming
    # conventions and assertions are still runnable. We just lose mutation
    # testing.
    return als_text, manifest
