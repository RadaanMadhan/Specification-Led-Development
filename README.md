# Specification-Led Development

A system that turns natural-language feature descriptions into formally verified specifications, then uses those verification artifacts to guide higher-quality code generation.

## What changed on this branch

### 1. CLI redesign

The CLI was rewritten from scratch with three clean commands:

```bash
speceval generate "A banking transfer system with audit logging"
speceval run specs/005-a-banking-transfer-system-with-audit-logging/
speceval doctor
```

**`speceval generate`** — Phase 0. Takes a free-text description and produces three SpecKit artefacts (`spec.md`, `data-model.md`, `contracts/http-api.md`) via three sequential LLM passes. Each output is validated against regex anchors to enforce the SpecKit template format. Results are content-addressed cached by SHA-256 over (description + config + prompts).

**`speceval run`** — Phases 1 + 2. Runs structural verification (Alloy) and runtime KPI derivation (WAF) on an existing feature directory. Supports `--from-description` to chain Phase 0 automatically, `--skip-alloy` / `--skip-kpi` to run one half, and `--no-mutate` to skip mutation testing. Produces `runs/<feature-id>/unified_report.md`.

**`speceval doctor`** — Checks Java 11+, Alloy JAR, and runs bundled test snapshots.

The old commands (`check`, `unified-verify`) are replaced.

### 2. Integrated SpecKit generator

New file: `src/speceval/speceval/speckit_generator.py`.

Three-phase generation pipeline:
1. **spec.md** — functional requirements, user stories with Given/When/Then scenarios, success criteria
2. **data-model.md** — entities, fields, validation rules, relationships, indexes
3. **contracts/http-api.md** — authentication, authorization matrix, endpoint definitions with FR traceability

Each phase has a dedicated system prompt enforcing exact template structure. The generator auto-numbers feature IDs by scanning existing `specs/` directories and validates every output before writing.

A new design-mode lifter (`lifter_design.py`, `verify.py`, `prompts.py`) replaces the old `lifter.py`. It reads all three SpecKit artefacts plus the `patterns.md` catalogue and produces a self-contained `feature_model.als` with a structured manifest containing FR-to-assertion maps and mutation targets.

### 3. Claude Code integration for code generation

New directory: `pipeline/`.

A pipeline that uses speceval's formally verified output to guide agentic code generation via `claude -p` (Claude Code CLI in headless mode), then compares the result against a baseline generated without verification context.

**How it works:**

```bash
bash pipeline/run_pipeline.sh \
  runs/005-a-banking-transfer-system-with-audit-logging/ \
  "A banking transfer system with audit logging"
```

1. `extract_verification_context.py` reads the speceval run directory (manifest JSON, `.als` model, unified report) and produces a `verification_context.md` with six sections: structural patterns, FR-to-assertion map, mutation results, invariant semantics, feature-specific predicates, and the full unified report.

2. Two tracks run in parallel via background processes:
   - **Guided track** — `claude -p` receives the verification context + guided system prompt. Instructed to add `// PATTERN:` comments, `Implements FR-NNN` docstrings, translate each Alloy fact into a runtime check, define `METRIC_*` threshold constants, and add `// HARDENED:` comments for mutation targets. A second `claude -p` pass generates tests following assertion/mutation/KPI/FR naming conventions.
   - **Baseline track** — `claude -p` receives only the goal description + a minimal system prompt. No verification context.

3. `score.py` counts concrete artifacts across six weighted dimensions:
   - Structural Completeness (25%) — `// PATTERN:` comments vs expected patterns
   - FR Coverage (25%) — `Implements FR-NNN` docstrings vs FR list
   - Invariant Enforcement (20%) — runtime checks matching named Alloy facts
   - Test Quality (15%) — test function counts by category (assertion, mutation, KPI, FR)
   - KPI Instrumentation (10%) — `METRIC_*` constants and threshold definitions
   - Security Posture (5%) — auth middleware, input validation, ownership checks, rate limiting

4. An LLM comparison judge reads both implementations and produces a qualitative report with per-dimension scores and a verdict.

### 4. Comparison results: guided vs baseline

First run on the banking transfer spec (`pipeline_runs/20260519-162520/`):

**Automated scorer:**

| Dimension | Weight | Guided | Baseline |
|---|---|---|---|
| Structural Completeness | 25% | 6.4 | 0.0 |
| FR Coverage | 25% | 10.0 | 0.0 |
| Invariant Enforcement | 20% | 8.9 | 0.5 |
| Test Quality | 15% | 10.0 | 5.0 |
| KPI Instrumentation | 10% | 10.0 | 0.0 |
| Security Posture | 5% | 10.0 | 6.7 |
| **Weighted Total** | | **8.88** | **1.19** |

**Verdict: GUIDED_WINS**

Key differences:
- **Feature completeness** — guided implemented all 10 FRs; baseline covered 4 partially (FR-001 through FR-004). Missing entirely from baseline: hash chain audit, daily limits, fraud detection, dual-balance model, reversals, fail-closed behavior.
- **Invariant enforcement** — guided has a dedicated `invariants.py` with 15 validators named after Alloy facts, each raising `InvariantViolation("F_<Name>", ...)`, plus 7 database CHECK constraints. Baseline has 4 basic validations.
- **Security** — guided has JWT auth + 12-pair RBAC permission matrix + ownership enforcement + information leakage prevention (404 for unauthorized). Baseline has a non-empty string check and no authorization.
- **Tests** — 184 categorized test functions (69 assertion, 12 mutation, 35 KPI, 56 FR acceptance) vs 40 generic tests.
- **Observability** — 12 WAF-derived KPI threshold constants + 16 Prometheus metrics vs none.
- **Tradeoff** — guided is 3x larger (4,700 lines vs 1,530 lines).

The full detailed comparison is at `pipeline_runs/20260519-162520/detailed_comparison.md`.

## Project structure

```
src/
  speceval/                   # Structural verification + SpecKit generator
    speceval/
      cli.py                  # CLI: generate, run, doctor
      speckit_generator.py    # Phase 0: free-text → SpecKit artefacts
      verify.py               # Phase 1: Alloy verification orchestrator
      unified_run.py          # Unified orchestrator (phases 0+1+2)
      unified_reporter.py     # Report rendering (MD + TXT)
      prompts.py              # Design-mode LLM prompts
      lifter_design.py        # LLM-driven Alloy model generation
      parser.py               # SpecKit markdown parser
      runner.py               # Alloy JAR invocation
      providers/              # LLM provider abstraction (Anthropic)
    alloy/                    # Base Alloy domain + KPI library
    tools/                    # alloy.jar (downloaded via bootstrap.sh)
    patterns.md               # 16 structural correctness patterns
  kpi/                        # WAF-derived runtime KPI derivation
    kpi_agent.py              # FR → WAF embedding → GQM+KPI pipeline
    db/                       # WAF records + embedding cache
specs/                        # SpecKit feature directories
runs/                         # Verification run outputs
pipeline/                     # Code-generation evaluation pipeline
  run_pipeline.sh             # Orchestrator (guided + baseline tracks)
  extract_verification_context.py  # Turns run output → verification_context.md
  score.py                    # 6-dimensional artifact scorer
  prompts/                    # System prompts for codegen/testgen/comparison
pipeline_runs/                # Timestamped pipeline execution results
```

## Setup

```bash
cp .env.example .env
# Fill in ANTHROPIC_API_KEY and OPENAI_API_KEY

pip install -r requirements.txt

cd src/speceval
bash bootstrap.sh
```
