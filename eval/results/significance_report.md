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
The Kruskal-Wallis test on overall KQS scores yields H = 403.88 
(p = 0.0000), indicating that differences across richness levels 
are significant. Mean KQS is statistically equivalent at L1 (0.888) 
and L2 (0.890), with a negligible and non-significant difference 
between them (p = 1.000, d = 0.01). The L2→L3 drop is highly 
significant (p = 0.0000) with a large effect (d = 0.90), and the 
L1 vs L3 contrast is equally large (d = 0.89). The dominant effect 
in the experiment is therefore not an improvement from sparse to 
standard richness but a sharp degradation at over-specified inputs. 
For D5 stability, the Kruskal-Wallis test yields H = 709.25 
(p = 0.0000), which is significant. L1 and L2 differ by a small 
but significant margin (d = 0.37), while L3 is dramatically less 
stable than both L1 (d = 1.84) and L2 (d = 1.36), confirming that 
threshold instability is an over-specification phenomenon specific 
to L3, not a general richness gradient.
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
