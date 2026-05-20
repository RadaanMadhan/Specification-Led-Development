# Specification-Led Development

Unified MVP for specification-led software verification. Takes a feature
description (or a pre-existing SpecKit feature directory) and runs two
complementary analyses:

1. **Structural verification** — lifts SpecKit artefacts to Alloy, runs SAT
   checks, and optionally mutates the model to test robustness.
2. **Runtime KPI derivation** — maps functional requirements to WAF principles
   and derives GQM+KPI targets with measurable thresholds.

Both halves produce a single **unified report** (Markdown + plain text).

## Setup

```bash
cp .env.example .env
# Fill in ANTHROPIC_API_KEY and OPENAI_API_KEY

pip install -r requirements.txt

# Bootstrap Alloy JAR + install speceval package
cd src/speceval
bash bootstrap.sh
```

## Usage

### Generate SpecKit artefacts from a description

```bash
speceval generate "An e-commerce API for buying movie tickets"
```

### Run the full pipeline (generate + verify + KPI)

```bash
speceval unified-verify \
  --from-description "An e-commerce API for buying movie tickets"
```

### Run on an existing feature directory

```bash
speceval unified-verify specs/003-netflix-content-delivery/
```

### Structural verification only

```bash
speceval check specs/003-netflix-content-delivery/spec.md
```

## Project structure

```
src/
  speceval/                 # Alloy-based structural verification + SpecKit generator
    speceval/               # Python package (cli, generator, lifter, etc.)
      cli.py                # CLI entry points (generate, check, unified-verify, ...)
      speckit_generator.py  # Phase 0: LLM-based SpecKit artefact generation
      unified_run.py        # Orchestrator: chains generation → Alloy → KPI
      unified_reporter.py   # Emits unified_report.md and .txt
      parser.py             # SpecKit markdown parser
      lifter.py             # spec.md → Alloy model lifter
      runner.py             # Alloy SAT solver invocation
      providers/            # LLM provider abstraction (Anthropic)
    alloy/                  # Base Alloy domain + KPI library
    tools/                  # alloy.jar (downloaded via bootstrap.sh)
  kpi/                      # WAF-derived runtime KPI derivation
    kpi_agent.py            # FR → WAF embedding → GQM+KPI pipeline
    db/                     # WAF records + embedding scripts
specs/                      # Generated / existing SpecKit feature directories
```
