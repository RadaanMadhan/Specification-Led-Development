# KPI-Spec / Database Layer

Azure AI Search — three-index architecture for WAF KPI derivation and validation.

## Structure

```
db/
├── schema/
│   ├── waf_index.json      # Index definition: WAF reference catalogue (immutable)
│   ├── gqm_index.json      # Index definition: GQM chains (runtime, versioned)
│   └── kpi_index.json      # Index definition: KPI targets + validation results
├── scripts/
│   ├── seed.py             # Create indexes + upload waf-index seed data
│   └── embed.py            # Generate embeddings for waf-index via Azure OpenAI
├── waf_index_seed.json     # 47 canonical WAF records (RE:01–PE:12)
└── README.md
```

## Indexes

| Index | Records | Populated by | Mutable? |
|---|---|---|---|
| `waf-index` | ~47 (one per WAF checklist code) | `seed.py` + `embed.py`, run once | No — immutable |
| `gqm-index` | Generated at runtime | `/kpi-derive` pipeline command | Yes — versioned |
| `kpi-index` | Generated at runtime | `/kpi-derive`, written by `/validate-kpi` | Yes — targets + results |

## First-time setup

```bash
# 1. Set required environment variables
export AZURE_SEARCH_ENDPOINT="https://your-resource.search.windows.net"
export AZURE_SEARCH_ADMIN_KEY="your-admin-key"
export AZURE_OPENAI_ENDPOINT="https://your-resource.openai.azure.com"
export AZURE_OPENAI_API_KEY="your-openai-key"
export AZURE_OPENAI_EMBED_DEPLOY="text-embedding-3-small"

# 2. Create all three indexes and upload seed data (no embeddings yet)
python db/scripts/seed.py

# 3. Generate embeddings for waf-index and upload
python db/scripts/embed.py
```

## Key design decisions

- **waf-index is immutable** — never update records after initial seed. Corrections require a new record version + migration.
- **gqm-index source field** — `waf_derived` for LLM-generated chains, `user_defined` for manually added KPIs. Both are treated identically by validation and reporting.
- **kpi-index threshold_direction** — `gte` (higher is better, e.g. uptime) or `lte` (lower is better, e.g. latency). Required for automated pass/fail logic in `/validate-kpi`.
- **environment field on kpi-index** — same GQM chain can have different thresholds for `production`, `staging`, `development`.

See `docs/IA_Design.docx` for the full information architecture design document.
