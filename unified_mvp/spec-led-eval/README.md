# spec-led-eval

A specification-led evaluation framework. It takes a SpecKit `spec.md`,
translates the natural-language acceptance scenarios into a formal
specification language (Alloy), and mathematically checks the spec
against a small library of generic Key Performance Indicators (KPIs).

This is the technical core of Microsoft Project 9 — *Specification-Led
Development: Bridging Technical Requirements and Business KPIs.*

---

## The problem this solves

Modern spec-driven development tools like SpecKit produce well-structured
documents (acceptance scenarios in Given/When/Then form, numbered
functional requirements, prioritised user stories), but those documents
have **no automated way to be checked for structural correctness**.
Two scenarios might silently contradict each other. A user story might
have its scenarios accidentally deleted. A copy-paste duplicate might
slip through review.

`spec-led-eval` automates that check by translating the spec into a
formal model and running mathematical verification against three
application-agnostic KPIs.

---

## What Alloy is, and how it does the checking

[Alloy](https://alloytools.org) is a formal modelling language and
analyser created by Daniel Jackson at MIT. It's the workhorse of
"lightweight formal methods" — using mathematical specification to
audit artefacts produced by other means, rather than to author whole
systems from scratch.

Three things to understand:

**1. Alloy describes structures.** You declare types of things (called
*signatures* or *sigs*), relationships between them (*fields*), and
rules that must hold (*facts*). Together these define a kind of
mathematical universe — every "world" Alloy considers is a graph of
atoms with tuples linking them.

**2. Alloy checks claims about those structures.** You write
*predicates* (named yes/no questions) and *assertions* (claims that a
predicate always holds). When you ask Alloy to check an assertion, it
tries to find a counterexample — a structure that satisfies your
declarations but violates the predicate.

**3. Alloy uses a SAT solver to do the checking, exhaustively but
within bounds.** Behind the scenes, Alloy translates your model plus
the assertion into a giant Boolean satisfiability problem and hands it
to a SAT solver (a battle-tested mathematical engine that's been
hardened over decades). The SAT solver explores every possible
structure within a finite scope (e.g. "up to 5 atoms of each sig") and
either:

- Finds a counterexample → reports `SAT` → the assertion is **violated**
  (in our terminology: the KPI **fails**).
- Proves no counterexample exists at that scope → reports `UNSAT` → the
  assertion **holds** (the KPI **passes**).

This isn't AI guessing. It's the same mathematical-logic technology
used to verify aerospace control systems, cryptographic protocols, and
distributed databases. When Alloy says PASS, it means *no
counterexample exists in the search space* — a strong, defensible claim.

---

## What we built — high-level architecture

```
   spec.md
       │
       ▼
   Python parser            ← regex over Given/When/Then markers
       │  (ParsedSpec)
       ▼
   LLM extraction (Claude Opus)
       │  (English prose → canonical Alloy atoms, JSON)
       ▼
   LLM validation (Claude Opus, fresh context)
       │  (issues with the previous extraction)
       ▼
   Optional human review
       │  (you eyeball the lifted atoms)
       ▼
   snapshot.als generated   ← Python templating, no LLM
       │
       ▼
   Alloy Analyzer SAT solver  ← pure mathematical reasoning, no LLM
       │
       ▼
   PASS / FAIL terminal report
```

Two separate LLM calls handle the *translation* step (English → Alloy
atoms), with the second LLM call reviewing the first's output. Once
the translation is done, the verdict comes from Alloy's SAT solver —
no further AI involvement.

---

## The three generic KPIs

These three KPIs are application-agnostic — they make sense for any
SpecKit specification, not just the Pomodoro one. They live in
`alloy/kpi_library.als` as Alloy predicates plus matching assertions,
and they're written entirely by hand (the LLM doesn't author KPIs;
it only translates the spec).

### KPI-G-001 — Scenario Determinism

**In plain English:** No two acceptance scenarios with the same
precondition (Given) and the same action (When) end in different
outcomes (Then).

**Why it matters:** Catches contradictions in the spec. If Story 1
says "Given X, When Y, Then A" and Story 3 says "Given X, When Y,
Then B", the spec contradicts itself.

**In Alloy:**

```alloy
pred KPI_G_001_Determinism {
    no disj s1, s2: Scenario |
        s1.given  = s2.given  and
        s1.action = s2.action and
        s1.then  != s2.then
}
assert KPI_G_001 { KPI_G_001_Determinism }
```

Read aloud: *"There do not exist two distinct scenarios s1 and s2 such
that they share the same Given AND share the same Action AND have
different Thens."*

### KPI-G-002 — Story Coverage

**In plain English:** Every User Story declared in the spec has at
least one acceptance scenario.

**Why it matters:** The SpecKit template requires each user story to
have scenarios. A user story heading without scenarios under it is an
unambiguous defect — someone deleted scenarios but kept the heading,
or wrote a story they never specified.

**In Alloy:**

```alloy
pred KPI_G_002_StoryCoverage {
    all st: Story | some s: Scenario | s.story = st
}
assert KPI_G_002 { KPI_G_002_StoryCoverage }
```

Read aloud: *"For every story st, there exists at least one scenario s
whose `story` field equals st."*

### KPI-G-003 — Scenario Uniqueness

**In plain English:** No two acceptance scenarios share an identical
(Given, Action, Then) triple.

**Why it matters:** Catches copy-paste duplication — a scenario that
was cloned across stories but never edited to test something new.

**In Alloy:**

```alloy
pred KPI_G_003_ScenarioUniqueness {
    no disj s1, s2: Scenario |
        s1.given  = s2.given  and
        s1.action = s2.action and
        s1.then   = s2.then
}
assert KPI_G_003 { KPI_G_003_ScenarioUniqueness }
```

Read aloud: *"There do not exist two distinct scenarios s1 and s2
where the entire (Given, Action, Then) triple matches."*

---

## Worked example — the Pomodoro spec

The framework is generic, but to make this concrete, here's how it
processes the SpecKit-generated Pomodoro CLI spec at
`speckit-trial/specs/001-pomo-cli/spec.md`.

### One scenario, lifted

Original prose in `spec.md`:

```
**Acceptance Scenarios**:

1. **Given** the user has no active session, **When** they run `pomo start`,
   **Then** a 25-minute work countdown begins displaying in the terminal.
```

After Claude Opus reads the spec and extracts canonical atoms, the
generated `snapshot.als` contains:

```alloy
one sig NoActiveSession, Work25CountdownBegins, ... extends State {}
one sig RunPomoStart, ... extends Action {}
one sig FR_001, FR_002, FR_007, ... extends Requirement {}
one sig Story_1, Story_2, Story_3, Story_4 extends Story {}

one sig Scenario_1_1 extends Scenario {} {
    given  = NoActiveSession
    action = RunPomoStart
    then   = Work25CountdownBegins
    covers = FR_001 + FR_002 + FR_007
    story  = Story_1
}
```

Each of the 15 acceptance scenarios in the spec becomes one
`Scenario_X_Y` declaration of this shape. The LLM's job is just to
pick the canonical names and decide which scenarios refer to the same
underlying state.

### How Alloy verifies the KPIs against this lifted spec

When `speceval check` runs `java -jar alloy.jar`, three things happen,
once per KPI:

**For KPI-G-001 (Determinism):** The SAT solver examines all 15×14/2
= 105 unordered pairs of distinct Scenario atoms. For each pair it
asks: do they share both `given` and `action`, but differ on `then`?
If any pair does, the predicate is violated → output `SAT` → KPI fails.
On the Pomodoro spec, no such pair exists, so output is `UNSAT` →
KPI passes.

**For KPI-G-002 (Story Coverage):** The SAT solver enumerates the
4 Story atoms (Story_1 through Story_4) and for each one asks: does
some Scenario atom point to it via the `story` field? If any Story
has zero pointing scenarios, the predicate is violated. On the
Pomodoro spec, every Story has at least one scenario, so output is
`UNSAT` → KPI passes.

**For KPI-G-003 (Uniqueness):** Same enumeration as KPI-G-001 but
checking for full triple equality. No two scenarios in the Pomodoro
spec are duplicates, so `UNSAT` → KPI passes.

The output you see in your terminal:

```
KPI         Name                    Verdict
KPI_G_001   Scenario Determinism    ✓ PASS
KPI_G_002   Story Coverage          ✓ PASS
KPI_G_003   Scenario Uniqueness     ✓ PASS

Summary: 3 of 3 KPIs passed.
```

is a direct rendering of those three Alloy verdicts.

### Demoing a failure

If you delete the acceptance-scenarios block under one user story
(say Story 3) and re-run `speceval check`, the LLM will lift the
spec normally, but the snapshot will contain `Story_3` declared with
no scenarios pointing to it. Alloy's SAT solver will find a
counterexample for KPI-G-002 — namely Story_3 with no `s: Scenario |
s.story = Story_3` — and report `SAT`. The KPI fails, the report
shows the offending story, and the regression is caught
mathematically.

Same idea for the other KPIs:

- **Add a scenario that contradicts an existing one** (same Given+Action,
  different Then) → KPI-G-001 fails, Alloy names the conflicting pair.
- **Copy-paste a scenario verbatim** under a different user story →
  KPI-G-003 fails, Alloy names the duplicate triple.

---

## What the LLM does, what Alloy does

It's worth being precise about this division because it's the central
point of the architecture.

| Step | Done by | Notes |
|------|---------|-------|
| Parse spec.md into Given/When/Then | Python regex | Deterministic, anchored on the SpecKit template's bold markers |
| Translate English prose into canonical atoms | Claude Opus (extraction) | The LLM picks names like "NoActiveSession", decides which prose phrases refer to the same logical state |
| Review the previous translation for mistakes | Claude Opus (validation, fresh context) | A second LLM call critiques the first's output |
| Generate snapshot.als | Python templating | Mechanical formatting |
| Verify the KPIs against the snapshot | Alloy SAT solver | Mathematical, exhaustive within scope, no AI involved |
| Render the report | Python | Format the SAT/UNSAT verdicts as a table |

The LLM's involvement ends with the snapshot. The verdicts come from
the same kind of formal reasoning used to verify cryptographic
protocols — no AI guessing about whether your spec is good.

---

## Installation

Requires:
- **Python 3.10 or later**
- **Java 11 or later** (for Alloy)
- An **Anthropic API key** (for the LLM-driven lifter; not needed for
  the offline `--hardcoded` Pomodoro demo)

One-time setup, from the `spec-led-eval` directory:

```bash
bash bootstrap.sh
```

This downloads `tools/alloy.jar`, installs the Python package, runs
the smoke tests, and runs the offline Pomodoro demo to verify the
toolchain.

For the LLM-driven path, copy `.env.example` to `.env` and set
`ANTHROPIC_API_KEY`. The `.env` file is `.gitignore`d so your key
never accidentally commits.

---

## Usage

```bash
# Full pipeline on any SpecKit spec — lifts via Claude Opus,
# pauses for human review of the lift before running Alloy:
speceval check ../speckit-trial/specs/001-pomo-cli/spec.md

# Same but autonomous — skip the human review prompt:
speceval check --no-review ../speckit-trial/specs/001-pomo-cli/spec.md

# Force a fresh LLM lift even if a cached result is available:
speceval check --no-cache ../speckit-trial/specs/001-pomo-cli/spec.md

# Offline demo — uses the hardcoded Pomodoro mapping, no API call:
speceval check --hardcoded ../speckit-trial/specs/001-pomo-cli/spec.md

# Print the lifted Alloy snapshot without running Alloy:
speceval lift  ../speckit-trial/specs/001-pomo-cli/spec.md

# Sanity-check Alloy with the bundled tiny snapshots:
speceval verify-alloy
```

For the simplest demo from Finder, double-click `run_llm_demo.command`
or `bootstrap.command`.

---

## Project structure

```
spec-led-eval/
├── alloy/
│   ├── domain.als           # Generic Sigs (State, Action, Scenario, Story, Requirement)
│   └── kpi_library.als      # The three KPI predicates and assertions
├── speceval/
│   ├── parser.py            # spec.md → ParsedSpec (regex on bold markers)
│   ├── prompts.py           # LLM extraction + validation prompt templates
│   ├── lifter.py            # Cache + extract + validate + review orchestration
│   ├── providers/
│   │   └── anthropic.py     # Claude API client (raw HTTPS, no SDK)
│   ├── snapshot.py          # LiftResult → snapshot.als (with hardcoded fallback)
│   ├── runner.py            # Subprocess to alloy.jar, parse Alloy 6 output
│   ├── reporter.py          # Coloured terminal table
│   └── cli.py               # `speceval check / lift / verify-alloy` commands
├── examples/
│   ├── tiny_passing_snapshot.als   # Hand-crafted, designed to pass all KPIs
│   ├── tiny_failing_snapshot.als   # Hand-crafted, designed to fail each KPI
│   └── sample_run.txt              # Captured demo output
├── tools/
│   └── alloy.jar            # Alloy Analyzer 6.2.0
├── tests/
│   ├── fixtures/tiny_spec.md
│   └── test_parser.py
├── cache/
│   ├── lifts/<sha256>.json  # Cached LLM lifts, keyed by spec content
│   └── last_snapshot.als    # Most recent generated snapshot
├── bootstrap.sh / .command  # One-shot setup + offline demo
├── run_llm_demo.command     # Double-click LLM demo
├── .env.example             # Template for API key
└── pyproject.toml
```

---

## How to extend

**Add a new KPI:**
Write a new `pred KPI_G_NNN_Name {...}` plus matching `assert KPI_G_NNN`
in `alloy/kpi_library.als`. Add an entry to `KPI_META` in
`speceval/reporter.py` so the report renders its name and description.
The runner picks it up automatically because it parses every `check`
verdict Alloy emits.

**Run on a different SpecKit project:**
Just point `speceval check` at any other `spec.md`. The LLM lifter is
generic; the only requirement is that the spec uses SpecKit's standard
template (Given/When/Then bold markers, FR-NNN numbered requirements,
User Story headings).

**Swap LLM provider:**
The `Provider` interface in `speceval/providers/__init__.py` is one
method (`complete(system, user)`). Add an Azure OpenAI adapter
alongside `anthropic.py` and switch via the `SPECEVAL_LLM_PROVIDER`
environment variable.

---

## Phase status

- **Phase 0 ✅** — Generic Alloy world (domain + KPI library) and
  hand-crafted ground-truth snapshots
- **Phase 1 ✅** — Mechanical pipeline (parser → snapshot → runner → reporter),
  with hardcoded Pomodoro lifter for offline demo
- **Phase 2 ✅** — LLM-driven lifter (Claude Opus extraction + validation,
  human review, content-addressed caching). Framework now genuinely
  generic across SpecKit projects.
- **Phase 3** — Run on a second, different SpecKit project to prove
  genericity beyond Pomodoro
- **Phase 4** — Dashboard / leaflet / poster / blog post

---

## Citation context for the report

This work follows Daniel Jackson and Jeannette Wing's "Lightweight
Formal Methods" thesis (1996) and the methodology in Jackson's
*Software Abstractions* (MIT Press, 2012). The framework treats the
LLM as a translator and Alloy as the independent oracle — formal
methods are used as a *sanity check* on artefacts produced by other
means (here, an LLM), not as the primary author. This division is
deliberate: LLMs synthesise plausible structure from natural language
but are weak at adversarially checking their own work; SAT solvers are
the opposite.
