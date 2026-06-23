# Specification-Led Development

A system that turns natural-language feature descriptions into formally verified specifications, then uses those verification artifacts to guide higher-quality code generation.

## What changed on this branch

# KPI Dashboard Feature

The KPI Dashboard provides an interactive Streamlit interface for reviewing extracted KPIs and their fulfillment status against the generated Alloy code.

## Features

✅ **Color-Coded KPI Status**
- 🟢 **Green (Fulfilled)**: KPI is directly addressed by an Alloy predicate or assertion
- 🟡 **Yellow (To be measured)**: KPI requires runtime measurement (success rates, throughput, etc.)
- 🔴 **Red (Missing)**: KPI is not addressed in the Alloy code

📊 **KPI Summary Statistics**
- Total KPIs extracted
- Breakdown by status (Fulfilled, To be measured, Missing)
- Source tracking (SpecKit vs user prompt)

🔄 **Interactive Regeneration**
- Modify your original prompt to improve KPI extraction
- Regenerate SpecKit artefacts with new description
- Loop until satisfied with KPI coverage

📥 **Export Functionality**
- Download KPIs as JSON for integration with other tools

## CLI Commands

### View Dashboard for Existing Feature

```bash
speceval dashboard specs/005-banking-transfer-system
```

This displays KPIs extracted from an existing feature directory's `kpis.json` file.

### Generate with Interactive Dashboard

```bash
speceval generate-interactive "A banking transfer system with audit logging"
```

This command:
1. Generates SpecKit artefacts (spec.md, data-model.md, http-api.md)
2. Extracts KPIs from the spec
3. Launches the dashboard for review
4. Allows you to:
   - Review KPI fulfillment status
   - Click "Regenerate" to modify your prompt and try again
   - Click "Continue" when satisfied
5. Repeats until you're happy or reach max iterations (5)

### Optional: Customize Generation

```bash
speceval generate-interactive \
  --project-type "web-api" \
  --tech-stack "Python, FastAPI, PostgreSQL" \
  --target-frs 12 \
  --feature-id "my-custom-feature" \
  "Your feature description"
```

## Dashboard Sections

### Header
- Feature name and ID
- Quick status summary (total KPIs, counts by status)

### KPI Details (Grouped by Status)
Each expandable section shows:
- KPI name and category
- Description
- Alloy match (if Fulfilled)
- Measurement strategy

### Action Buttons
- **🔄 Regenerate with Modified Prompt**: Opens a text area to edit your description and restart generation
- **✓ Continue / Close**: Accept current KPIs and proceed
- **📋 Export KPIs as JSON**: Download the full KPI dataset

## KPI Matching Algorithm

The dashboard uses a similarity-based algorithm to match KPIs against Alloy code:

1. **Extracts** all predicate, assertion, and fact names from the Alloy model
2. **Normalizes** names (lowercase, removes special characters)
3. **Computes similarity** using:
   - Exact match (score: 1.0)
   - Substring containment (score: 0.7)
   - Trigram overlap (score: 0.0-1.0)
4. **Tags** based on threshold:
   - ≥ 0.6: **Fulfilled** ✓
   - 0.3-0.6 or runtime metric: **To be measured** ○
   - < 0.3: **Missing** ✗

## JSON Output Format

The `kpis.json` file saved in your feature directory contains:

```json
{
  "feature_id": "005-banking-transfer-system",
  "feature_name": "Banking Transfer System",
  "metadata": {
    "total_speckit_kpis": 8,
    "total_user_prompt_kpis": 3,
    "total_unique_kpis": 10
  },
  "kpis": [
    {
      "name": "Audit Entry Immutability",
      "category": "Data Integrity",
      "description": "All audit entries must be append-only",
      "formal_constraint": "fact F_AppendOnly",
      "measurement_strategy": "Verify no audit record is ever modified",
      "source": "speckit",
      "source_location": "spec.md: Formal Requirements & Advanced KPI Mapping",
      "status": "Fulfilled",
      "matched_constraint": "F_AppendOnlyAuditEntries"
    },
    {
      "name": "Success Rate",
      "category": "Success Rate",
      "description": "Ratio of successful operations",
      "formal_constraint": null,
      "measurement_strategy": "Ratio of successful operations",
      "source": "user_prompt",
      "source_location": "User-provided description",
      "status": "To be measured",
      "matched_constraint": null
    }
  ]
}
```

## Example Workflow

```bash
# Step 1: Generate interactively
$ speceval generate-interactive "A banking system with transfers and audit logging"
[gen]     iteration 1/5
[gen]     generating SpecKit artefacts...
[gen]     provider: Anthropic (claude-3-5-sonnet-20241022)
[gen]     output:   /path/to/specs

[kpi]     extracting KPIs from spec.md...
[kpi]     extracted 8 KPIs

[dashboard] launching KPI review dashboard...
```

At this point, Streamlit opens in your browser showing:
- ✓ 5 Fulfilled KPIs (data integrity, access control, etc.)
- ○ 2 To be measured (success rate, transaction throughput)
- ✗ 1 Missing (cost tracking)

You can either:
- Click "Continue" to proceed with these KPIs
- Click "Regenerate" to modify your prompt and try again:
  - "A banking system with transfers, audit logging, and cost tracking per transaction"
  - Dashboard regenerates with the updated spec and KPIs
  - Now shows all 8 KPIs as Fulfilled

# Step 2: Verification
$ speceval run specs/005-banking-transfer-system
[parse]   feature '005-banking-transfer-system', 8 FRs, 3 user stories
[lift]    calling LLM...
[alloy]   running alloy.jar on feature_model.als...
[kpi]     extracted 8 KPIs (8 from spec.md)
```

The full verification runs and dashboard displays KPI-Alloy alignment.


##Previous changes on the radaan-code-generation branch:

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
