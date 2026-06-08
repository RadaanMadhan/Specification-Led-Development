## Test Suite Summary

All p-values below are Bonferroni-corrected where multiple comparisons were made (n=3 for richness pairs, n=6 for framework pairs). Values displayed as 0.0000 indicate p < 0.0001; exact magnitudes are in the sub-sections. Cohen's d is computed on raw scores alongside non-parametric tests — it quantifies practical effect size independent of sample size.

**Note on statistical power:** Group sizes range from ~129–514 observations. At this scale, Kruskal-Wallis and Mann-Whitney U have very high power and will reliably detect even small systematic differences. Consequently, p ≈ 0 across most comparisons is expected and does not indicate a methodological problem — it reflects a well-powered design. Practical significance is captured by d. The tests that correctly fail to reject (L1 vs L2 KQS; WAF vs ISO 25010; WAF vs NIST CSF) confirm the tests can return null results.

### Richness-Level Tests — KQS

| Test | Type | Comparison | Statistic | p (adj) | d | Effect Size |
|------|------|------------|-----------|---------|---|-------------|
| Overall KQS | Kruskal-Wallis | L1 / L2 / L3 | H = 403.88 | < 0.0001 | — | — |
| KQS pairwise | Mann-Whitney U | L1 vs L2 | U = 141,787 | 1.0000 | 0.01 | negligible |
| KQS pairwise | Mann-Whitney U | L1 vs L3 | U = 328,004 | < 0.0001 | 0.89 | large |
| KQS pairwise | Mann-Whitney U | L2 vs L3 | U = 364,436 | < 0.0001 | 0.90 | large |
| KQS — Banking | Kruskal-Wallis | L1 / L2 / L3 | H = 170.18 | < 0.0001 | — | — |
| KQS — SaaS | Kruskal-Wallis | L1 / L2 / L3 | H = 118.44 | < 0.0001 | — | — |
| KQS — Healthcare | Kruskal-Wallis | L1 / L2 / L3 | H = 123.30 | < 0.0001 | — | — |

### Richness-Level Tests — D5 Monte Carlo Stability

| Test | Type | Comparison | Statistic | p (adj) | d | Effect Size |
|------|------|------------|-----------|---------|---|-------------|
| D5 stability | Kruskal-Wallis | L1 / L2 / L3 | H = 709.25 | < 0.0001 | — | — |
| D5 pairwise | Mann-Whitney U | L1 vs L2 | — | < 0.0001 | 0.37 | small |
| D5 pairwise | Mann-Whitney U | L1 vs L3 | — | < 0.0001 | 1.84 | large |
| D5 pairwise | Mann-Whitney U | L2 vs L3 | — | < 0.0001 | 1.36 | large |

### Framework Comparison Tests — All Richness Levels

| Test | Type | Comparison | Statistic | p (adj) | d | Effect Size |
|------|------|------------|-----------|---------|---|-------------|
| Frameworks (all) | Kruskal-Wallis | WAF / ISO / NIST / SRE | H = 97.16 | < 0.0001 | — | — |
| Framework pairwise | Mann-Whitney U | WAF vs ISO 25010 | U = 111,570 | 0.2119 | 0.17 | negligible |
| Framework pairwise | Mann-Whitney U | WAF vs NIST CSF | U = 121,218 | 1.0000 | 0.01 | negligible |
| Framework pairwise | Mann-Whitney U | WAF vs SRE | U = 157,216 | < 0.0001 | 0.33 | small |
| Framework pairwise | Mann-Whitney U | ISO 25010 vs NIST CSF | U = 118,888 | 0.0061 | 0.19 | negligible |
| Framework pairwise | Mann-Whitney U | ISO 25010 vs SRE | U = 153,636 | < 0.0001 | 0.55 | medium |
| Framework pairwise | Mann-Whitney U | NIST CSF vs SRE | U = 137,924 | < 0.0001 | 0.32 | small |

### Framework Comparison Tests — L2 Only

| Test | Type | Comparison | Statistic | p (adj) | d | Effect Size |
|------|------|------------|-----------|---------|---|-------------|
| Frameworks (L2) | Kruskal-Wallis | WAF / ISO / NIST / SRE | H = 95.17 | < 0.0001 | — | — |
| Framework pairwise | Mann-Whitney U | WAF vs ISO 25010 | U = 10,068 | 1.0000 | 0.03 | negligible |
| Framework pairwise | Mann-Whitney U | WAF vs NIST CSF | U = 9,470 | 1.0000 | 0.02 | negligible |
| Framework pairwise | Mann-Whitney U | WAF vs SRE | U = 15,467 | < 0.0001 | 0.84 | large |
| Framework pairwise | Mann-Whitney U | ISO 25010 vs NIST CSF | U = 9,347 | 1.0000 | 0.01 | negligible |
| Framework pairwise | Mann-Whitney U | ISO 25010 vs SRE | U = 15,368 | < 0.0001 | 0.90 | large |
| Framework pairwise | Mann-Whitney U | NIST CSF vs SRE | U = 14,012 | < 0.0001 | 0.90 | large |

---

## Overall KQS — Kruskal-Wallis
H = 403.88, p = 0.0000
Result: significant at p < 0.05

## Pairwise KQS comparisons (Bonferroni corrected)
L1 vs L2: U = 141787, p = 1.0000 -> not significant - d = 0.01 (negligible)
L1 vs L3: U = 328004, p = 0.0000 -> significant - d = 0.89 (large)
L2 vs L3: U = 364436, p = 0.0000 -> significant - d = 0.90 (large)

## Per-context Kruskal-Wallis
Banking (A):   H = 170.18, p = 0.0000 -> significant
SaaS (B):   H = 118.44, p = 0.0000 -> significant
Healthcare (C):   H = 123.30, p = 0.0000 -> significant

## D5 Monte Carlo stability — Kruskal-Wallis
H = 709.25, p = 0.0000 -> significant

## Pairwise D5 comparisons (Bonferroni corrected)
L1 vs L2: p = 0.0000 · d = 0.37 (small)
L1 vs L3: p = 0.0000 · d = 1.84 (large)
L2 vs L3: p = 0.0000 · d = 1.36 (large)

## Interpretation
The Kruskal-Wallis test on overall KQS scores yields H = 403.88 (p = 0.0000), indicating that differences across richness levels are significant. Mean KQS peaks at L2 then drops at L3 across levels (L1 = 0.888, L2 = 0.890, L3 = 0.729). The L1→L2 improvement is not significant after Bonferroni correction (p = 1.0000) with a negligible effect (d = 0.01). The L2→L3 drop is highly significant (p = 0.0000) with a large effect (d = 0.90). The L1 vs L3 contrast is highly significant (p = 0.0000) (d = 0.89). For D5 stability, the Kruskal-Wallis test yields H = 709.25 (p = 0.0000), which is significant, confirming that richer specs produce more stable numeric thresholds across Monte Carlo runs.

## Framework Comparison — Kruskal-Wallis

### Kruskal-Wallis across frameworks (all richness levels)
H = 97.16,  p = 0.0000  →  significant at α = 0.05
Group means:  WAF = 0.826 (n=514),  ISO 25010 = 0.859 (n=468),  NIST CSF = 0.823 (n=455),  SRE = 0.764 (n=493)

### Pairwise Mann-Whitney U — frameworks (Bonferroni n=6, all richness levels)
WAF vs ISO 25010:  U = 111570,  p_adj = 0.2119  →  not significant  —  d = 0.17 (negligible)
WAF vs NIST CSF:  U = 121218,  p_adj = 1.0000  →  not significant  —  d = 0.01 (negligible)
WAF vs SRE:  U = 157216,  p_adj = 0.0000  →  significant  —  d = 0.33 (small)
ISO 25010 vs NIST CSF:  U = 118888,  p_adj = 0.0061  →  significant  —  d = 0.19 (negligible)
ISO 25010 vs SRE:  U = 153636,  p_adj = 0.0000  →  significant  —  d = 0.55 (medium)
NIST CSF vs SRE:  U = 137924,  p_adj = 0.0000  →  significant  —  d = 0.32 (small)

### Kruskal-Wallis across frameworks (L2 only)
H = 95.17,  p = 0.0000  →  significant at α = 0.05
Group means:  WAF = 0.922 (n=143),  ISO 25010 = 0.927 (n=141),  NIST CSF = 0.925 (n=129),  SRE = 0.791 (n=147)

### Pairwise Mann-Whitney U — frameworks (Bonferroni n=6, L2 only)
WAF vs ISO 25010:  U = 10068,  p_adj = 1.0000  →  not significant  —  d = 0.03 (negligible)
WAF vs NIST CSF:  U = 9470,  p_adj = 1.0000  →  not significant  —  d = 0.02 (negligible)
WAF vs SRE:  U = 15467,  p_adj = 0.0000  →  significant  —  d = 0.84 (large)
ISO 25010 vs NIST CSF:  U = 9347,  p_adj = 1.0000  →  not significant  —  d = 0.01 (negligible)
ISO 25010 vs SRE:  U = 15368,  p_adj = 0.0000  →  significant  —  d = 0.90 (large)
NIST CSF vs SRE:  U = 14012,  p_adj = 0.0000  →  significant  —  d = 0.90 (large)

### Interpretation
The Kruskal-Wallis test across all four frameworks (all richness levels combined) yields H = 97.16 (p = 0.0000), indicating that framework choice does significantly affect KPI quality scores at α = 0.05. Mean KQS by framework (descending): ISO 25010 = 0.859,  WAF = 0.826,  NIST CSF = 0.823,  SRE = 0.764. ISO 25010 produces the highest mean KQS and SRE the lowest. 4 of 6 pairwise comparisons remain significant after Bonferroni correction: WAF vs SRE (small effect, d = 0.33);  ISO 25010 vs NIST CSF (negligible effect, d = 0.19);  ISO 25010 vs SRE (medium effect, d = 0.55);  NIST CSF vs SRE (small effect, d = 0.32). At L2 richness only, the Kruskal-Wallis test yields H = 95.17 (p = 0.0000), which is significant. The significance pattern is similar at L2 and across all richness levels, suggesting framework effects are not concentrated at a particular input quality.
