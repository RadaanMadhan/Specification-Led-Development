# KPI-Spec / Database & Agent Layer

Quantitative KPI derivation from natural language specifications, grounded in the Azure Well-Architected Framework (WAF). Part of the Specification-Led Development evaluation framework.

## What this does

Takes a `spec.md` file in SpecKit format, extracts functional requirements (FR-NNN lines), and derives measurable KPI targets for each one — grounded in WAF principles via semantic search. Outputs structured GQM chains and KPI records ready for validation and report generation.

```
spec.md → kpi_agent.py → gqm_output.json + kpi_output.json
```

## Structure

```
KPI_DB/
├── kpi_agent.py                  # Main agent — run this
├── spec.md                       # Example spec in SpecKit format
├── waf_embeddings_cache.json     # Auto-generated on first run, do not commit
├── gqm_output.json               # Auto-generated output, do not commit
├── kpi_output.json               # Auto-generated output, do not commit
├── db/
│   ├── schema/
│   │   ├── waf_index.json        # Azure AI Search index definition (WAF catalogue)
│   │   ├── gqm_index.json        # Azure AI Search index definition (GQM chains)
│   │   └── kpi_index.json        # Azure AI Search index definition (KPI targets)
│   ├── scripts/
│   │   ├── seed.py               # Creates Azure indexes + uploads WAF records
│   │   └── embed.py              # Generates embeddings via Azure OpenAI (Azure only)
│   ├── waf_index_seed.json       # 59 canonical WAF records (RE:01–PE:12)
│   └── README.md
└── docs/
    ├── WAF_Reference_Document.docx
    └── KPI_Spec_IA_Design.docx
```

## Running the agent

### Requirements
- Python 3.10+
- `requests` library (`pip install requests`)
- An OpenAI API key (get one at platform.openai.com)

### Setup

```bash
# Mac/Linux
export OPENAI_API_KEY="sk-..."

# Windows PowerShell
$env:OPENAI_API_KEY="sk-..."
```

### Run

```bash
# Run against any SpecKit spec
python kpi_agent.py spec.md

# Or point at a different spec file
python kpi_agent.py path/to/your/spec.md
```

### What happens

1. Parses the spec — extracts all FR-NNN functional requirements
2. Loads 59 WAF records from `db/waf_index_seed.json`
3. First run: generates embeddings for all 59 WAF records via OpenAI, caches to `waf_embeddings_cache.json`
4. Subsequent runs: loads cache instantly — no extra API calls
5. For each FR: embeds the requirement, finds top 3 matching WAF principles by cosine similarity, calls OpenAI to derive a GQM chain and KPI targets
6. Saves all chains to `gqm_output.json` and all KPI targets to `kpi_output.json`

### Output files

Both output files use the exact same schema as the Azure AI Search indexes — they can be bulk-uploaded directly when Azure credentials are available.

**gqm_output.json** — one record per GQM chain:
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

**kpi_output.json** — one record per measurable threshold:
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

## The three indexes (Azure — future)

The `db/schema/` folder defines the Azure AI Search index structure. Currently the agent runs fully locally using OpenAI for embeddings and local JSON files for storage. When Azure credits are available, `seed.py` and `embed.py` replace the local layer.

| Index | Records | Currently | Azure (future) |
|---|---|---|---|
| `waf-index` | 59 WAF principles | `waf_index_seed.json` (local) | Azure AI Search |
| `gqm-index` | One per FR per spec run | `gqm_output.json` (local) | Azure AI Search |
| `kpi-index` | One per KPI threshold | `kpi_output.json` (local) | Azure AI Search |

### Azure first-time setup (when credits available)

```bash
export AZURE_SEARCH_ENDPOINT="https://your-resource.search.windows.net"
export AZURE_SEARCH_ADMIN_KEY="your-admin-key"
export AZURE_OPENAI_ENDPOINT="https://your-resource.openai.azure.com"
export AZURE_OPENAI_API_KEY="your-openai-key"
export AZURE_OPENAI_EMBED_DEPLOY="text-embedding-3-small"

python db/scripts/seed.py    # creates indexes + uploads 59 WAF records
python db/scripts/embed.py   # generates and attaches embeddings
```

## Key design decisions

- **Real embeddings via OpenAI** — uses `text-embedding-3-small` (same model as Azure OpenAI) for WAF principle matching. Cached after first run so subsequent runs are free.
- **waf-index is immutable** — 59 WAF records are the ground truth. Never modified at runtime. Corrections require a new record version.
- **threshold_direction** — `gte` (higher is better, e.g. uptime, coverage) or `lte` (lower is better, e.g. latency, MTTR). Required for automated pass/fail logic.
- **Deduplication** — if the LLM returns two KPI targets with identical numeric threshold and direction for the same chain, the duplicate is silently dropped.
- **Output schema matches Azure** — `gqm_output.json` and `kpi_output.json` are structured identically to the Azure AI Search indexes, so switching from local to Azure requires no schema changes.

## .gitignore

Add these generated files — anyone running the agent regenerates them:

```
waf_embeddings_cache.json
gqm_output.json
kpi_output.json
.env
```