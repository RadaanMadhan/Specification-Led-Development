# KPI-Spec

Automated KPI derivation from natural-language software specifications, grounded in architectural quality frameworks (WAF, ISO 25010, NIST CSF, SRE). Part of the Specification-Led Development research project.

## What this does

Takes a `spec.md` file in SpecKit format, extracts functional requirements (FR-NNN lines), and derives measurable KPI targets for each one — grounded in framework principles via semantic embedding search. Outputs structured GQM chains and KPI records.

```
spec.md → kpi_agent.py → gqm_output_{framework}.json + kpi_output_{framework}.json
```

## Repository structure

```
.
├── kpi_agent.py                      # KPI derivation agent — main entry point
├── spec.md                           # Example spec in SpecKit format
├── requirements.txt                  # Python dependencies
│
├── db/
│   ├── schema/
│   │   ├── waf_index.json            # Azure AI Search index definition (WAF)
│   │   ├── gqm_index.json            # Azure AI Search index definition (GQM chains)
│   │   └── kpi_index.json            # Azure AI Search index definition (KPI targets)
│   ├── scripts/
│   │   ├── seed.py                   # Creates Azure indexes + uploads seed records
│   │   └── embed.py                  # Generates embeddings via Azure OpenAI
│   ├── waf_index_seed.json           # 59 canonical WAF records (RE:01–PE:12)
│   ├── all_frameworks_seed.json      # Combined seed: WAF + ISO 25010 + NIST CSF + SRE
│   ├── iso25010_seed.json
│   ├── nist_csf_seed.json
│   └── sre_golden_signals_seed.json
│
└── eval/
    ├── run_experiment.py             # Orchestrates all specs × frameworks × runs
    ├── scorer.py                     # KQS scoring logic (D1, D3, D4)
    ├── aggregate.py                  # D5 stability + CSV aggregation
    ├── visualise.py                  # Generates paper figures
    ├── significance_testing.py       # Kruskal-Wallis / Mann-Whitney tests
    ├── specs/                        # 9 evaluation specs (A-L1 … C-L3)
    ├── runs/                         # Experiment outputs (gitignored per run)
    └── results/
        ├── all_scores.csv
        ├── cell_summary.csv
        ├── significance_report.md
        └── figures/
```

## Setup

**Requirements:** Python 3.10+, an OpenAI API key.

```bash
pip install -r requirements.txt
```

```bash
# Mac/Linux
export OPENAI_API_KEY="sk-..."

# Windows PowerShell
$env:OPENAI_API_KEY="sk-..."
```

## Running the agent

```bash
# Run against any SpecKit spec (default framework: WAF)
python kpi_agent.py spec.md

# Choose a different knowledge base
python kpi_agent.py spec.md --framework iso25010
python kpi_agent.py spec.md --framework nist_csf
python kpi_agent.py spec.md --framework sre

# Available frameworks: waf, iso25010, nist_csf, sre, all
```

### What happens

1. Parses the spec — extracts all FR-NNN functional requirements
2. Loads framework seed records from `db/all_frameworks_seed.json`
3. First run per framework: generates embeddings via OpenAI, caches to `embeddings_cache_{framework}.json`
4. Subsequent runs: loads cache instantly — no extra API calls
5. For each FR: embeds the requirement, finds top 3 matching principles by cosine similarity, calls OpenAI (GPT-4o-mini) to derive a GQM chain and KPI targets
6. Saves all chains to `gqm_output_{framework}.json` and targets to `kpi_output_{framework}.json`
7. Writes a cost summary to `cost_log_{framework}.json`

### Output files

**`gqm_output_{framework}.json`** — one record per GQM chain:
```json
{
  "id": "uuid",
  "spec_id": "spec-20260511-120000",
  "source": "waf_derived",
  "waf_code_refs": ["SE:05", "SE:09"],
  "pillar_id": "security",
  "goal": "Ensure authentication is required on all API endpoints",
  "question": "What percentage of endpoints enforce authentication?",
  "metric_name": "auth_coverage_percentage",
  "metric_unit": "percentage"
}
```

**`kpi_output_{framework}.json`** — one record per measurable threshold:
```json
{
  "id": "uuid",
  "gqm_id": "uuid-of-chain",
  "pillar_id": "security",
  "environment": "production",
  "threshold_value": ">= 100%",
  "threshold_numeric": 100.0,
  "threshold_direction": "gte",
  "measurement_method": "API gateway audit logs",
  "status": "pending",
  "measured_value": null,
  "validated_at": null
}
```

## Evaluation pipeline

The `eval/` directory contains the full experimental evaluation. Nine specifications (3 application contexts × 3 richness levels) are each processed 10 times per framework (360 total runs) to measure output quality and Monte Carlo stability.

```bash
# Run the full framework comparison (9 specs × 4 frameworks × 10 runs)
python eval/run_experiment.py --mode framework_comparison

# Run a single spec × all frameworks (e.g. for validation)
python eval/run_experiment.py --mode framework_comparison --spec A-L2

# Resume after interruption — only run runs 6–10 (skips already-completed 1–5)
python eval/run_experiment.py --mode framework_comparison --runs 10 --start-run 6

# Re-score all saved run outputs after changing scoring logic (no API calls)
python eval/run_experiment.py --rescore

# Aggregate results
python eval/aggregate.py

# Run significance tests
python eval/significance_testing.py

# Generate paper figures
python eval/visualise.py
```

### Scoring dimensions

Each derived KPI is scored across four dimensions (KQS = KPI Quality Score):

| Dim | Name | Measures |
|-----|------|----------|
| D1 | Threshold specificity | Numeric threshold present and non-trivial |
| D3 | Directionality coherence | `gte`/`lte` direction matches metric semantics |
| D4 | GQM chain coherence | Metric name is snake_case, unit is from valid set |
| D5 | Monte Carlo stability | CV of threshold_numeric across repeated runs |

`kqs_partial` = mean(D1, D3, D4). `kqs_full` = mean(D1, D3, D4, D5), computed at aggregation time.

### Spec naming convention

| ID | Context | Richness |
|----|---------|----------|
| A-L1 | Banking | Sparse (1 FR) |
| A-L2 | Banking | Standard (3 FRs) |
| A-L3 | Banking | Rich (5 FRs + scenarios) |
| B-Lx | SaaS | as above |
| C-Lx | Healthcare | as above |

## Key design decisions

- **LLM as translator, not oracle** — GPT-4o-mini derives structured GQM/KPI records from requirements; it does not make pass/fail judgements. Scoring is deterministic and rule-based.
- **Real embeddings via OpenAI** — uses `text-embedding-3-small` for framework principle matching. Cached after first run per framework.
- **Seed data is immutable** — framework records are the ground truth; never modified at runtime.
- **`threshold_direction`** — `gte` (higher is better: uptime, coverage) or `lte` (lower is better: latency, MTTR). Required for automated pass/fail logic.
- **Output schema matches Azure AI Search** — `gqm_output_*.json` and `kpi_output_*.json` are structured identically to the Azure indexes for zero-friction cloud migration.

## Azure deployment (optional)

The agent runs fully locally by default. To use Azure AI Search instead:

```bash
export AZURE_SEARCH_ENDPOINT="https://your-resource.search.windows.net"
export AZURE_SEARCH_ADMIN_KEY="your-admin-key"
export AZURE_OPENAI_ENDPOINT="https://your-resource.openai.azure.com"
export AZURE_OPENAI_API_KEY="your-openai-key"
export AZURE_OPENAI_EMBED_DEPLOY="text-embedding-3-small"

python db/scripts/seed.py    # creates indexes + uploads seed records
python db/scripts/embed.py   # generates and attaches embeddings
```

## Running tests

```bash
pytest eval/tests/ -v
```
