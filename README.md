# Specification-Led Development

A system that turns natural language feature descriptions into formally verified specifications, then uses those verification artifacts to guide higher-quality code generation.

## Overview

This project implements a multi-phase pipeline to bridge the gap between feature descriptions and secure, verified code:

1. **Phase 1 (SpecKit Generation):** Takes a free-text description and produces three SpecKit artefacts (spec.md, data-model.md, contracts/http-api.md) via three sequential LLM passes. Each output is validated against regex anchors to enforce the SpecKit template format. 

In parallel:  
2. **Phase 2.1 (Structural Verification):** Reads the SpecKit artefacts and produces a self-contained Alloy 6 model (`feature_model.als`). Runs structural verification and mutation testing.  
3. **Phase 2.2 (KPI Derivation):** Derives runtime KPIs from Functional Requirements (FRs) by matching them against Well-Architected Framework (WAF) principles.  
4. **Phase 3 (Code Generation & Evaluation):** Uses the formally verified outputs to guide agentic code generation via Claude Code (`claude -p`), comparing the result against a baseline generated without verification context.

## Setup

```bash
cp .env.example .env
# Fill in ANTHROPIC_API_KEY and OPENAI_API_KEY

pip install -r requirements.txt

cd src/speceval
bash bootstrap.sh
```

## CLI Commands

The CLI provides several commands to interact with the pipeline.

### Core Workflow

**1. Generate SpecKit Artefacts (Phase 1)**
```bash
speceval generate "A banking transfer system with audit logging"
```
Produces `spec.md`, `data-model.md`, and `contracts/http-api.md` inside `specs/<feature-id>/` using three sequential LLM passes. Each output is validated against regex anchors to enforce the SpecKit template format. Results are content-addressed cached by SHA-256 over (description + config + prompts).
  1. spec.md — functional requirements, user stories with Given/When/Then scenarios, success criteria
  2. data-model.md — entities, fields, validation rules, relationships, indexes
  3. contracts/http-api.md — authentication, authorization matrix, endpoint definitions with FR traceability

**2. Run Verification & KPI Derivation (Phases 2.1 and 2.2)**
```bash
speceval run specs/<feature-id>/
```
Runs structural verification (Alloy) and runtime KPI derivation (WAF) on an existing feature directory. Produces a `unified_report.md` inside `runs/<feature-id>/`.
*Options:* `--from-description` to chain Phase 0 automatically, `--skip-alloy` / `--skip-kpi` to run one half, and `--no-mutate` to skip mutation testing.

A design-mode lifter (lifter_design.py, verify.py, prompts.py) reads all three SpecKit artefacts plus the `patterns.md` catalogue and produces a self-contained `feature_model.als` with a structured manifest containing FR-to-assertion maps and mutation targets.

**3. Health Checks**
```bash
speceval doctor
```
Checks Java 11+, Alloy JAR, and runs bundled test snapshots.

### Interactive Workflow (Pre-Code-Generation Dashboard)

The KPI Dashboard provides an interactive Streamlit interface for reviewing extracted KPIs before any code or Alloy models are generated. It helps ensure that your initial prompt produces observable and structurally sound requirements.

**Generate with Interactive Dashboard**
```bash
speceval generate-interactive "A banking transfer system with audit logging"
```
This command generates the SpecKit artefacts, extracts KPIs, runs Alloy structural verification, and launches an interactive dashboard. The dashboard categorizes KPIs into **Technical** and **Business** types, and evaluates them on two dimensions:
- 🛡️ **Logically Guaranteed:** Whether the KPI can be mapped to a formal structural constraint in the generated Alloy code.
- 📊 **Operationally Observable:** Whether there is a clear runtime metric or telemetry strategy.

You can review these metrics, modify your prompt to regenerate the artefacts if there are missing constraints or telemetry strategies, and proceed only when satisfied with the specifications.

**View Dashboard for Existing Feature**
```bash
speceval dashboard specs/<feature-id>
```
Displays the KPI dashboard for an already generated feature.

## Code Generation Pipeline (Phase 3)

The pipeline uses speceval's formally verified output to guide agentic code generation via `claude -p` (Claude Code CLI in headless mode), then compares the result against a baseline prompt-to-code-generation framework.

```bash
bash pipeline/run_pipeline.sh \
  runs/<feature-id>/ \
  "A banking transfer system with audit logging"
```
  1. `extract_verification_context.py` reads the speceval run directory (manifest JSON, `.als` model, unified report) and produces a `verification_context.md` with six sections: structural patterns, FR-to-assertion map, mutation results, invariant semantics, feature-specific predicates, and the full unified report.

  2. Two tracks run in parallel via background processes:  
    - **Guided track**: `claude -p` receives the verification context + guided system prompt. Instructed to add `// PATTERN:` comments, `Implements FR-NNN` docstrings, translate each Alloy fact into runtime checks, define `METRIC_*` threshold constants, and add `// HARDENED:` comments for mutation targets. A second `claude -p` pass generates tests following assertion/mutation/KPI/FR naming conventions.  
    - **Baseline track**: `claude -p` receives only the goal description + a minimal system prompt. No verification context.

  3. `score.py` counts concrete artifacts across six weighted dimensions:
    - Structural Completeness (25%) — `// PATTERN:` comments vs expected patterns  
    - FR Coverage (25%) — `Implements FR-NNN` docstrings vs FR list  
    - Invariant Enforcement (20%) — runtime checks matching named Alloy facts  
    - Test Quality (15%) — test function counts by category (assertion, mutation, KPI, FR)  
    - KPI Instrumentation (10%) — `METRIC_*` constants and threshold definitions  
    - Security Posture (5%) — auth middleware, input validation, ownership checks, rate limiting  

  4. An LLM comparison judge reads both implementations and produces a qualitative report with per-dimension scores and a verdict.


### Evaluation Visualization Dashboard

After the code generation pipeline finishes, you can visualize the comparison results using the post-code-generation dashboard located in the `visualization/` folder:

```bash
python -m visualization.visualize
```

This interactive Streamlit dashboard provides:
1. **Business Overview**: A side-by-side comparison of execution costs (API calls), cache savings, and business KPI fulfillment. It also includes the full LLM qualitative comparison report and an overall "Verdict" (e.g., GUIDED WINS).
2. **Technical Details**: Detailed metrics for the 6 verification quality scores, along with pie charts illustrating test suite composition and a deep dive into KPI alignment and formal constraint mappings.

*Example Comparison Results (Guided vs Baseline):*  
In initial runs, the **Guided** track substantially outperformed the Baseline, yielding 3x more code with comprehensive invariant enforcement, complete test suites, WAF-derived KPIs, and full feature coverage, scoring an overall 8.88/10 vs the Baseline's 1.19/10.

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


## Project Structure

```text
src/
  speceval/                   # Structural verification + SpecKit generator
    speceval/
      cli.py                  # CLI commands
      speckit_generator.py    # Phase 1
      verify.py               # Phase 2.1: Alloy verification
      unified_run.py          # Unified orchestrator
      unified_reporter.py     # Report rendering
      lifter_design.py        # LLM-driven Alloy model generation
      runner.py               # Alloy JAR invocation
    alloy/                    # Base Alloy domain + KPI library
    tools/                    # alloy.jar
    patterns.md               # Structural correctness patterns
  kpi/                        # WAF-derived runtime KPI derivation
    kpi_agent.py              # FR → WAF embedding → GQM+KPI
specs/                        # SpecKit feature directories
runs/                         # Verification run outputs
pipeline/                     # Code-generation evaluation pipeline
  run_pipeline.sh             # Orchestrator
  score.py                    # 6-dimensional artifact scorer
pipeline_runs/                # Timestamped pipeline execution results
visualization/                # Post-code-generation evaluation dashboard
  visualize.py                # Dashboard launch entry point
  dashboard.py                # Streamlit UI
  ingest.py                   # Data ingestion from pipeline runs
  transform.py                # Data transformations and charting
  visualization.db            # SQLite database for pipeline metrics
```
