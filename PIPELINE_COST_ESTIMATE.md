# Complete Pipeline Cost Estimate

## Per-Run Cost Breakdown

**Based on:** Medium-complexity feature specification (8-12 functional requirements)

| Phase | Description | Cost |
|---|---|---|
| **Speceval - Alloy Lift** | Lift SpecKit artefacts to Alloy model (patterns.md + spec.md + data-model.md + http-api.md → feature_model.als) | $0.10 |
| **Speceval - KPI Derivation** | Map FRs to WAF principles, derive GQM chains + KPI thresholds (OpenAI embeddings + derivation) | $0.30 |
| **Guided Code Generation** | Generate implementation with verification context (domain models, services, API, infrastructure) | $1.20 |
| **Guided Test Generation** | Generate comprehensive tests based on verification artifacts (assertion/mutation/KPI/FR categories) | $1.06 |
| **Baseline Code Generation** | Generate implementation without verification context (code + tests) | $0.78 |
| **LLM Comparison Judge** | Qualitative analysis comparing both implementations across 6 dimensions | $0.27 |
| **Subtotal** | | **$3.71** |
| **Buffer (20%)** | Contingency for variable token counts, retries, or larger specs | **$0.74** |
| **Total per run** | | **$4.45** |

---

## Cost Factors

- **Cache efficiency:** ~94% cache hit rate reduces costs by ~4x
- **Models:** Claude Code uses multi-model routing (primarily Opus 4.6 for generation + Haiku 4.5 for tool use)
- **Spec size:** Based on 8-12 FR medium-complexity feature; larger specs (15-20 FRs) may cost 30-50% more, smaller specs (3-5 FRs) may cost 30-40% less
- **Guided track premium:** 2-3x more expensive than baseline but produces 6-8x higher quality scores

---

## What You Get

### Speceval Output
- Formally verified Alloy model with self-contained constraints
- Structural compliance report with assertion verdicts
- FR coverage matrix mapping requirements to formal assertions
- Mutation test results validating assertion strength
- WAF-derived KPI targets with measurable thresholds
- Unified verification report (Markdown + plain text)

### Code Generation Output
- **Guided implementation:** Production-ready code with formal invariant enforcement, comprehensive tests, KPI instrumentation, security controls (auth, RBAC, input validation)
- **Baseline implementation:** Standard implementation without verification context
- **Automated scoring:** 6-dimensional artifact comparison across structural completeness, FR coverage, invariant enforcement, test quality, KPI instrumentation, and security
- **LLM analysis:** Detailed qualitative comparison report
- **Cost tracking:** Complete token usage and cost breakdown

---

## Estimated Annual Costs

| Scenario | Runs per year | Cost |
|---|---|---|
| **Occasional use** | 10 runs | $44.50 |
| **Regular development** | 50 runs | $222.50 |
| **Continuous verification** | 200 runs | $890.00 |

*Assumes medium-complexity features (8-12 FRs). Costs scale proportionally with spec size and complexity.*
