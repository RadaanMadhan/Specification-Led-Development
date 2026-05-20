"""speceval.prompts — system + user prompts for the LLM lifter.

Two passes:
  1. EXTRACTION  — read the parsed spec, output canonical Alloy atoms as JSON.
  2. VALIDATION  — fresh-context review of the extraction; flag issues.

Both prompts ask for STRICT JSON output. The lifter parses, validates the
schema, and (if review mode is on) shows a human-readable summary before
running Alloy.
"""

from __future__ import annotations

import json
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from speceval.parser import ParsedSpec


# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------

EXTRACTION_SYSTEM_PROMPT = """\
You are a formal-specification analyst. Your job is to lift natural-language
acceptance scenarios from a SpecKit spec.md into canonical atoms suitable
for Alloy formal verification.

You MUST follow these rules:

1. Identical or paraphrased prose MUST map to the same atom name. For
   example, "the user has no active session" and "no session is active"
   describe the same logical state and must use one canonical atom name.

2. Semantically distinct prose MUST get different atom names. Do not
   collapse states that are conceptually different (e.g. "timer running"
   vs "timer paused" are different states).

3. Atom identifiers MUST match the regex [A-Za-z][A-Za-z0-9_]+ — no spaces,
   no hyphens, no special characters. Use UpperCamelCase. Examples of
   valid names: NoActiveSession, RunPomoStart, Work25Countdown, FR_001.

4. Functional Requirement IDs MUST be in the form FR-NNN (e.g. FR-001),
   exactly matching the IDs as they appear in the spec.

5. Every Functional Requirement that any scenario plausibly exercises
   should appear in that scenario's "covers" list. Be liberal but not
   reckless — if a scenario tests behaviour described by an FR, include
   the FR.

6. The "initial_states" set should contain states that represent valid
   starting points before any scenario action occurs. Typically these
   include the precondition of the first Priority-1 scenario plus any
   "configuration-time" states (e.g. invocation flag combinations).

7. Each scenario must be assigned to its parent User Story using the
   form "Story_N" where N is the user-story number from the spec.

8. Every User Story declared in the spec must appear in the "stories"
   list, even if no scenario references it. (KPI-G-002 needs to detect
   stories with no scenarios.)

You MUST return ONLY a single JSON object matching this schema. No
prose, no markdown, no commentary outside the JSON:

{
  "states":         [string, ...],          // unique canonical state names
  "actions":        [string, ...],          // unique canonical action names
  "stories":        [string, ...],          // e.g. ["Story_1", "Story_2", ...]
  "initial_states": [string, ...],          // subset of "states"
  "scenarios": [
    {
      "label":  string,                     // e.g. "1.1", "2.3"
      "given":  string,                     // a name from "states"
      "action": string,                     // a name from "actions"
      "then":   string,                     // a name from "states"
      "covers": [string, ...],              // FR IDs in form "FR-NNN"
      "story":  string                      // a name from "stories"
    },
    ...
  ]
}
"""


EXTRACTION_USER_PROMPT_HEADER = """\
Lift the following SpecKit specification into canonical Alloy atoms.
Produce the JSON object now — no other output.
"""


def build_extraction_prompt(parsed: "ParsedSpec") -> str:
    """Render a `ParsedSpec` into the user-prompt body for extraction."""
    lines: list[str] = [EXTRACTION_USER_PROMPT_HEADER, ""]

    lines.append(f"# Feature\n{parsed.feature_name}\n")

    lines.append("# Functional Requirements")
    for fr in parsed.requirements:
        lines.append(f"- {fr.id}: {fr.text}")
    lines.append("")

    lines.append("# User Stories")
    for us in parsed.user_stories:
        lines.append(f"- Story_{us.number} ({us.priority}): {us.title}")
    lines.append("")

    lines.append("# Acceptance Scenarios")
    for sc in parsed.all_scenarios:
        lines.append(f"## Scenario {sc.label} (parent: Story_{sc.story_number})")
        lines.append(f"  Given: {sc.given}")
        lines.append(f"  When:  {sc.when}")
        lines.append(f"  Then:  {sc.then}")
    lines.append("")

    lines.append(
        "# Required output\nReturn the JSON object as specified by the system "
        "prompt. Output ONLY valid JSON; no prose, no code fences."
    )

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

VALIDATION_SYSTEM_PROMPT = """\
You are reviewing a lift from a SpecKit spec.md into canonical Alloy atoms.
Your job is to identify mistakes the extractor may have made.

Look for these specific failure modes:

A. UNDER-MERGING. Two scenario clauses describe the same logical state or
   action but were assigned different atom names. Example: scenario X has
   given="NoActiveSession" and scenario Y has given="SessionInactive" —
   these are the same condition and should share one atom.

B. OVER-MERGING. Two scenario clauses describe different logical states
   or actions but were collapsed into the same atom. Example: scenario X
   has then="SessionRunning" and scenario Y has then="SessionRunning",
   but X's prose was about a fresh session and Y's was about a paused
   session being resumed — these should be different atoms.

C. MISSING COVERAGE. A scenario clearly exercises a Functional
   Requirement, but the FR is missing from the scenario's "covers" list.
   Example: a scenario whose Then is "JsonStatusPrinted" should cover
   the FR that mandates JSON status output.

D. STORY MISASSIGNMENT. A scenario is assigned to the wrong Story_N.

E. INVALID IDENTIFIER. An atom name violates the [A-Za-z][A-Za-z0-9_]+
   regex (contains spaces, hyphens, etc.).

You MUST return ONLY a single JSON object:

{
  "issues": [
    {
      "kind":        "under_merging" | "over_merging" | "missing_coverage"
                   | "story_misassignment" | "invalid_identifier" | "other",
      "scenarios":   [string, ...],         // affected scenario labels
      "atoms":       [string, ...],         // affected atom names
      "description": string                 // one sentence explaining the issue
    },
    ...
  ]
}

If no issues, return {"issues": []}. No prose outside the JSON.
"""


def build_validation_prompt(parsed: "ParsedSpec", extracted: dict) -> str:
    """Render the validation user-prompt body.

    The validator gets the original prose plus the extractor's JSON, and
    is asked whether the mappings look right.
    """
    lines: list[str] = [
        "Review this lift for the failure modes described in the system prompt.",
        "",
        "## Original spec content",
        "",
    ]

    lines.append("### Functional Requirements")
    for fr in parsed.requirements:
        lines.append(f"- {fr.id}: {fr.text}")
    lines.append("")

    lines.append("### User Stories")
    for us in parsed.user_stories:
        lines.append(f"- Story_{us.number} ({us.priority}): {us.title}")
    lines.append("")

    lines.append("### Acceptance Scenarios")
    for sc in parsed.all_scenarios:
        lines.append(f"#### Scenario {sc.label}")
        lines.append(f"Given: {sc.given}")
        lines.append(f"When:  {sc.when}")
        lines.append(f"Then:  {sc.then}")
    lines.append("")

    lines.append("## Extracted atoms")
    lines.append("```json")
    lines.append(json.dumps(extracted, indent=2))
    lines.append("```")
    lines.append("")
    lines.append(
        "Return the issues JSON now. Output ONLY valid JSON; no prose, "
        "no code fences."
    )

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Design-mode lift (Phase 3)
#
# Reads patterns.md + spec.md + data-model.md + contracts/http-api.md and
# asks Claude Opus to author one self-contained Alloy `feature_model.als`:
#   * domain sigs, fields, named facts modelling the feature
#   * one named predicate per pattern from patterns.md that applies
#   * one named predicate per FR-NNN in spec.md
#   * any feature-specific predicates the LLM judges valuable
#   * one `assert` per predicate, plus matching `check` commands
#   * inline `// PATTERN: <name>  ANCHOR: <citation>` or
#     `// FEATURE-SPECIFIC  ANCHOR: <FR-NNN>` on every predicate
#
# A second JSON block, immediately after the .als block, lists the
# named facts that are "mutable" — facts the validator can blank to
# verify each assertion is non-vacuous.
# ---------------------------------------------------------------------------

DESIGN_LIFT_SYSTEM_PROMPT = """\
You are a formal-methods engineer. Your job is to take a SpecKit feature
folder (spec.md + data-model.md + contracts/http-api.md) plus a curated
catalogue of structural correctness patterns and produce ONE self-contained
Alloy 6 model file that mathematically encodes the feature's invariants.

Your output is consumed by an automated pipeline that runs `java -jar
alloy.jar exec feature_model.als` and parses per-`check` PASS/FAIL verdicts.
Every assertion you write must be `check`able and meaningful — it must fail
when the underlying invariant is violated, not pass vacuously.

# Hard rules

1. STANDALONE FILE. Output a single self-contained Alloy module. Do NOT
   import or reference `domain.als`, `kpi_library.als`, or any external
   model. The previous Phase-1/2 pipeline used those; the design-mode
   pipeline does not. Define every sig you need locally.

2. NO `module` LINE. Begin with comments and sig declarations.

3. ALLOY 6 SYNTAX ONLY. In particular:
   - `abstract sig Foo {}` for hierarchies.
   - `sig Foo extends Bar {}` for disjoint subtypes.
   - `sig Foo in Bar {}` for non-disjoint subsets.
   - Field types may be `one`, `lone`, `set`, e.g. `sig X { f: one Y }`.
   - Operations like dot-join `x.f`, transitive closure `^r`, set
     comprehension `{ x: T | P[x] }`.
   - Use `pred Name { body }` and `pred Name[args] { body }`.
   - Use `assert Name { body }` and `check Name for <scope>`.
   - Default scope `for 5` is fine for most assertions; bump to `for 6`
     or `for 8` if a pattern needs more atoms (e.g., a permission matrix
     with 3 roles × 3 endpoints needs at least 9 OperationKind atoms).
   - Quantify with `all`, `some`, `no`, `lone`, `one`. Use `disj`
     for distinctness: `all disj a, b: T | ...`.
   - Comments are `//` line comments and `/* ... */` block comments.

4. NAMED, MUTATION-TESTABLE FACTS. Every constraint that encodes a
   structural rule MUST live inside a NAMED `fact F_<Name> { ... }`
   block, never an anonymous `fact { ... }`. The validator removes a
   fact's body to check that the matching assertion is non-vacuous;
   anonymous facts cannot be removed by name.

5. ONE PREDICATE/ASSERTION PER STRUCTURAL CLAIM. For each pattern that
   applies (decided by reading the artefacts) and for each FR-NNN in
   spec.md, generate ONE `pred` and ONE `assert` with the same name.
   Naming convention:
       pred PatternName { ... }                  // for catalogue patterns
       assert PatternName { PatternName }
       check PatternName for <scope>

       pred FR_NNN_ShortLabel { ... }             // one per FR-NNN
       assert FR_NNN_ShortLabel { FR_NNN_ShortLabel }
       check FR_NNN_ShortLabel for <scope>

   The label after `FR_NNN_` is a short snake-or-camel hint at what the
   FR is about, e.g. `FR_001_AuthRequired`, `FR_009_OneAuditPerTransfer`.

6. ANCHOR EVERY PREDICATE. The line immediately above each `pred ...`
   MUST be a comment in one of these two forms:
       // PATTERN: <PatternName>  ANCHOR: <citation>
       // FEATURE-SPECIFIC  ANCHOR: <FR-NNN or short text>
   The <citation> is a short pointer back to the artefact that justifies
   the pattern (e.g., "spec.md FR-009; data-model.md UNIQUE(transaction_id)").

7. STRUCTURE THE MODEL THE WAY THE FEATURE READS. Treat
   data-model.md's entities as concrete sigs; treat contracts/http-api.md's
   permission matrix as a relation between Role and OperationKind sigs.
   Model the (Role × OperationKind) "allowed" relation as a FIELD on a
   singleton sig — NOT as `sig Allowed in Role -> OperationKind {}`,
   which is invalid Alloy 6 syntax (the `in` keyword on a sig declaration
   takes a sig, not a relation). The canonical pattern:

       abstract sig Role {}
       one sig AccountHolder, Auditor, Admin extends Role {}
       abstract sig OperationKind {}
       one sig PostTransfers, GetTransferById, GetAudit extends OperationKind {}

       // Permission matrix as a singleton-sig field. Reference cells with
       // `Role -> OperationKind in PermMatrix.Allowed`.
       one sig PermMatrix { Allowed: set Role -> OperationKind }

   Then encode the matrix from contracts/http-api.md as named facts, e.g.:

       fact F_PermissionMatrix {
         AccountHolder -> PostTransfers in PermMatrix.Allowed
         Admin -> PostTransfers in PermMatrix.Allowed
         // ...one line per allowed cell...
         // Closed-world: list all allowed cells explicitly:
         PermMatrix.Allowed = (AccountHolder -> PostTransfers) +
                              (Admin -> PostTransfers) +
                              // ... + all other cells
       }

8. ASSERTION STRENGTH. Each assertion must be such that REMOVING the
   key fact body it depends on would cause Alloy to find a counterexample
   (verdict SAT). If you are unsure how to make an assertion bite, pick a
   stronger encoding. Prefer constructive-but-checkable forms over
   tautologies.

9. NON-EMPTY UNIVERSE — declare ONE fact, never inline witnesses.
   Alloy's default `check ... for 5` scope ALLOWS empty universes, which
   makes any `all x: T | P[x]` predicate vacuously true and any `some
   x: T | Q[x]` predicate vacuously false. To make assertions bite
   meaningfully, the model needs at least one atom of each *dynamic*
   sig the predicates quantify over.

   DO declare exactly ONE fact at the top of the model, named
   `F_NonEmptyUniverse`, that asserts `some <Sig>` for every dynamic
   sig (i.e., every `sig X { ... }` declaration — NOT `one sig`,
   `abstract sig`, or `lone sig`, which are not dynamic). Example:

       fact F_NonEmptyUniverse {
         some User
         some Account
         some Transaction
         some AuditEntry
         some Operation
       }

   DO NOT put `some <Sig>` witness clauses inside `pred` bodies. This
   is an anti-pattern: it causes the predicate to FAIL whenever Alloy
   explores empty-universe worlds (which it will, under `for 5`), and
   the failure is an artifact of where the witness lives, not a real
   counterexample to the invariant. Keep `pred` bodies focused on the
   structural invariant the assertion is checking.

10. QUANTIFIED IMPLIES — parenthesize the consequent. When an
    `implies` is followed by another quantifier (`one`, `some`,
    `all`, `lone`, `no`), Alloy's parser binds the quantifier tighter
    than the bar `|` and rejects the un-parenthesized form. ALWAYS
    parenthesize:

        // WRONG — Alloy throws a type/syntax error:
        all op: Operation |
          op.outcome = Success implies one log: Log | log.op = op

        // RIGHT:
        all op: Operation |
          op.outcome = Success implies (one log: Log | log.op = op)

    Same rule for `some log: Log | …` and `lone log: Log | …` after
    `implies`. The parenthesis is mandatory.

11. CHECK SCOPE. After every `assert`, emit a `check Name for <scope>`
    line. Use `for 5` unless the model has more than 5 distinct concrete
    atoms in any one sig family — in that case bump to `for 8` or `for 12`.
    For permission-matrix patterns with 3 roles and 3 endpoints, use
    `for 8 but exactly 3 Role, exactly 3 OperationKind`.

12. NO `run` BLOCKS, NO `pred Show` BLOCKS. Only `check` commands run in
    the pipeline.

# Output protocol

Return EXACTLY two fenced code blocks, in this order, and NOTHING ELSE
(no prose before, between, or after):

```alloy
// === feature_model.als — Alloy model for <feature name> ===
// (your full self-contained Alloy 6 source here)
```

```json
{
  "feature_id": "<feature folder name, e.g. 002-bank-transfer-audit>",
  "patterns_applied": ["LeastPrivilege", "AppendOnly", ...],
  "feature_specific_predicates": ["FeatureSpecificPredName1", ...],
  "fr_assertion_map": {
    "FR-001": ["FR_001_AuthRequired"],
    "FR-002": ["FR_002_OneRolePerUser"],
    ...
  },
  "mutation_targets": [
    {
      "fact_name": "F_AppendOnlyAuditEntries",
      "asserts_violated": ["AppendOnly", "FR_010_AuditAppendOnly"],
      "rationale": "removing this fact lets the model invent a state in which an AuditEntry is mutated, which is exactly what the AppendOnly assertion is supposed to catch.",
      "inject_violation": "fact MUTATE_AppendOnlyViolation { some disj ae1, ae2: AuditEntry | ae1.transaction = ae2.transaction }"
    },
    ...
  ]
}
```

The validator does TWO things per mutation target, in order:

  1. CLEAR the named `fact_name` body (replace with `{}`).
  2. APPEND `inject_violation` as a fresh fact at the end of the file.

Together this tests assertion bite: clearing the fact removes the
constraint, and the injection FORCES a violating instance to exist within
the Alloy scope. If the targeted assertion still PASSes, then either
(a) another fact in the model independently enforces the same property
(over-constraint), or (b) the predicate body is a tautology that doesn't
actually constrain anything.

Pick the 3–6 most important assertions to mutation-test (LeastPrivilege,
AppendOnly, AuditCompleteness, OwnershipBasedAccess, NoSelfMutation,
NoInformationLeakage are typical candidates). For each, supply BOTH
`fact_name` (the most direct load-bearing fact) AND `inject_violation`
(an Alloy fact-body snippet, ready to drop in, that says "a counterexample
to the assertion exists"). The injection MUST use only sigs/fields already
declared in your model — do not invent new ones.

CRITICAL — write predicates that look at OUTCOMES, not the fact body
verbatim. If `F_NoSelfTransfer` says `all t: Transaction | t.source != t.destination`,
do NOT make the matching predicate identical. Phrase the assertion in
terms of what the property means (e.g., "no Transaction has identical
endpoints, and at least one Transaction exists when the predicate is
exercised"). When in doubt, include `some <relevant sig>` inside the
predicate body so it isn't vacuously satisfied by an empty universe.
Note that `check ... for 5` lets Alloy pick the empty universe; if the
predicate body doesn't force existence, the assertion may pass vacuously.

Output exactly the two code blocks. No commentary outside them.
"""


def build_design_lift_prompt(
    *,
    feature_id: str,
    patterns_md: str,
    spec_md: str,
    data_model_md: str,
    http_api_md: str,
) -> str:
    """Render the user prompt for design-mode lifting.

    Inlines the four input artefacts so a single Messages API call has
    everything it needs. The system prompt declares the output protocol;
    this user prompt only supplies the materials.
    """
    return f"""\
Generate a single self-contained Alloy 6 model `feature_model.als` plus the
mutation-targets JSON, following the protocol in the system prompt.

The feature folder identifier is: {feature_id}

# patterns.md (catalogue of structural correctness patterns)

{patterns_md}

# spec.md

{spec_md}

# data-model.md

{data_model_md}

# contracts/http-api.md

{http_api_md}

# Required output

Return EXACTLY two fenced code blocks: an ```alloy block with the full
feature_model.als, then a ```json block with the mutation-targets manifest,
matching the schema in the system prompt. Nothing else.
"""
