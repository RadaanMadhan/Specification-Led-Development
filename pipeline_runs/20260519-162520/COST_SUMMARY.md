# Cost Summary: Banking Transfer System Pipeline Run

**Run ID:** 20260519-162520
**Feature:** Banking transfer system with audit logging
**Date:** 2026-05-19

## Total Cost: $3.32

### Breakdown by Phase

| Phase | Input Tokens | Output Tokens | Cache Write | Cache Read | Cost |
|---|---|---|---|---|---|
| **Guided Code Generation** | 32 | 33,712 | 63,781 | 1,692,143 | $1.20 |
| **Guided Test Generation** | 13,905 | 25,844 | 72,759 | 1,368,723 | $1.06 |
| **Baseline Code Generation** | 32 | 22,134 | 37,864 | 1,128,330 | $0.78 |
| **LLM Comparison Judge** | 2 | 4,095 | 67,865 | 18,196 | $0.27 |
| **TOTAL** | **13,971** | **85,785** | **242,269** | **4,207,392** | **$3.32** |

## Analysis

### Cache Efficiency

The pipeline made heavy use of prompt caching:
- **Cache write:** 242,269 tokens (~243K) across all phases
- **Cache read:** 4,207,392 tokens (~4.2M) — **94.5% cache hit rate**
- **Cache savings:** ~$11.15 (cache read at 10% of normal price)
- **Effective cost with caching:** $3.32
- **Cost without caching:** ~$14.47 (4.4x more expensive)

### Cost per Track

- **Guided track** (code + tests): $2.26
  - More expensive due to longer verification context (25KB markdown)
  - Generated 25 files, 4,700 lines, 184 tests

- **Baseline track** (code only): $0.78
  - Simpler prompt (description only)
  - Generated 22 files, 1,530 lines, 40 tests

- **Comparison**: $0.27
  - One-shot analysis of both implementations

### Output Quality vs Cost

- **Guided:** $2.26 → 8.88/10 score (39% per point)
- **Baseline:** $0.78 → 1.19/10 score (66% per point)

The guided track is **2.9x more expensive** but produces **7.5x higher score** (8.88 vs 1.19).

**Cost per quality point:** Guided is actually **more efficient** at $0.25/point vs baseline $0.66/point.

### Token Distribution

| Metric | Value | % of Total |
|---|---|---|
| Input tokens (fresh) | 13,971 | 0.3% |
| Output tokens | 85,785 | 2.0% |
| Cache creation | 242,269 | 5.6% |
| Cache reads | 4,207,392 | 92.1% |

The vast majority of tokens (92%) came from cached reads, demonstrating the efficiency of the prompt caching strategy.

## Pricing Model

Based on Claude Sonnet 4 pricing:
- **Input:** $3.00 per million tokens
- **Output:** $15.00 per million tokens
- **Cache write:** $3.00 per million tokens (same as input)
- **Cache read:** $0.30 per million tokens (10% of input)

## Recommendations

1. **Cache is critical** — Without caching, this run would cost $14.47 (4.4x more)
2. **Guided track ROI** — Despite being 2.9x more expensive, it produces 7.5x better results
3. **Baseline track use case** — Good for quick prototypes where formal verification isn't needed
4. **Comparison cost** — At $0.27, the LLM judge is cheap relative to the value (qualitative analysis)

## Files Generated

**Guided track:**
- 25 Python files
- 3 test files with 184 test functions
- Full FastAPI app with JWT auth, Prometheus metrics, async database

**Baseline track:**
- 22 Python files
- 4 test files with 40 test functions
- Basic FastAPI app with in-memory storage

## Next Steps

To reproduce this run or run on a different spec:

```bash
bash pipeline/run_pipeline.sh <run_dir> "goal description"
```

Cost calculation runs automatically at the end and produces `cost_breakdown.json`.
