# spec-led-eval — Evaluation Plan

**Status**: pre-registered (committed before any experimental runs)
**Author**: Leon Hausmann, Microsoft Project 9 (Specification-Led Development)
**Date**: 2026-05-17
**Companion plan**: Charlotte Lett's KPI Derivation Evaluation (`charlotte_work_and_evaluation/.../eval/`)

## 1. Purpose and research question

The Alloy half of the joint MVP — `spec-led-eval`'s Phase-3 `verify-design`
pipeline — has been built and verified end-to-end on the banking feature
(`002-bank-transfer-audit`: 24/26 assertions PASS, 4/6 mutations bit). It has
**not yet been empirically evaluated**. This document specifies how that
evaluation is run.

The central research question is whether the **richness of the Speckit
artefacts** consumed by the lifter systematically predicts the quality of the
Alloy verification it produces, and whether that relationship holds
consistently across application domains.

This mirrors Charlotte's research question exactly. Her pipeline derives WAF-grounded
numerical KPIs from FRs; this pipeline lifts Speckit artefacts into Alloy
predicates. Each half's evaluation tests its own pipeline on its own natural
input format, but **the methodology is shared end-to-end** so the joint
methodology chapter reads coherently and the two halves' results sit
side-by-side in the report.

## 2. Experimental design

### 2.0 Two-stage structure

The evaluation runs in **two sequential, independently triggerable stages**.
Stage 1 is the main scientific deliverable; Stage 2 is a follow-up extension
fired only when Leon explicitly decides.

| Stage | Design | Runs | Hypotheses tested | Status |
|---|---|---|---|---|
| **Stage 1 — Main evaluation** | 3 domains × 3 richness × 10 replicates, on M-best model | **90** | H1, H2, H3, H4 | Primary deliverable; runs first |
| **Stage 2 — Model comparison** | The same 3×3×10 design, repeated on M-mid and M-small | **+180** | H5, H6, H7 | Deferred; runs only when Leon triggers it independently |

Stage 1 alone produces a complete, publishable result on the richness
question (H1–H4 are the main hypotheses) using Anthropic's strongest
model with extended thinking at maximum. The headline figures, statistics,
and write-up are produced after Stage 1 only.

Stage 2 adds the model-capability question — "do we need the best model,
or does a cheaper one suffice?" — without changing anything about Stage 1.
The harness, scorer, aggregator, statistics module, and visualiser are
written from the start to support both stages: Stage 1 outputs land in
`runs/<cell-id>/M-best/run_NN/`; Stage 2, when triggered, adds
`runs/<cell-id>/M-mid/run_NN/` and `runs/<cell-id>/M-small/run_NN/`
without overwriting anything. Stage-2-only outputs (the comparison
figures and statistics) are generated only when M-mid and M-small data
are present; otherwise the pipeline produces Stage-1-only outputs and
stops cleanly.

### 2.1 Factorial structure

| Factor | Levels |
|---|---|
| Application context | **A** Banking (loan application), **B** SaaS (task management), **C** Healthcare (clinical record access) |
| Speckit prompt richness | **L1** sparse one-sentence prompt, **L2** standard paragraph prompt, **L3** rich multi-paragraph prompt with explicit numeric constraints and regulatory references |
| **Model tier** | **M-best** Anthropic's strongest frontier model with extended thinking at maximum (the "main evaluation" model — see Phase E0a and Appendix D for the exact selection); **M-mid** Sonnet-tier (Stage 2 only); **M-small** Haiku-tier (Stage 2 only) |
| Replicates | 10 per (cell, model) combination |

**Stage 1 total: 9 cells × 1 model × 10 replicates = 90 runs.**
**Stage 2 total (if triggered): +9 cells × 2 models × 10 replicates = +180 runs.**

**Why a model factor at all.** Holding the model constant tells us only
how the lifter behaves *given that model*. Varying the model answers the
question practitioners actually ask: is the best model necessary, or
does a smaller cheaper model suffice? Charlotte's KQS evaluation did not
vary the model; adding model as a Stage-2 factor in the Alloy half makes
the methodology more rigorous, not just analogous. **Stage 2 is optional**
because Stage 1 alone is already publishable; we structure the code to
make Stage 2 a one-command extension when (or if) Leon decides to run it.

### 2.2 Input strategy — one Speckit folder per cell, pinned

For each cell we **run Speckit once** on the corresponding L1/L2/L3 feature
prompt (Appendix A), inspect the produced folder, and **pin that folder** as
the canonical input for all 10 replicates of that cell. Variance across the 10
replicates therefore attributes to the Alloy lifter only, not to Speckit's own
non-determinism — which is a separate confound worth studying but not in this
experiment.

Three reasons for this approach:

1. **Real Speckit output.** Every cell is a production-faithful Speckit
   folder, not Claude-fabricated artefacts shaped to look Speckit-like. The
   evaluation claim is "we measured the Alloy verification pipeline on
   production-faithful inputs," which is the strongest defensible position.
2. **Naturalistically generated richness.** The richness gradient is produced
   by Speckit translating richer prompts, not by us ablating sections of a
   single rich baseline.
3. **Clean variance attribution.** Pinning isolates the dependent variable
   (the lifter's behaviour) from Speckit's own LLM noise.

### 2.3 Replicate protocol

Each replicate (1..10) invokes:

```
python -m speceval.cli verify-design --no-cache --java-bin <jdk4py> \
    eval/specs/<cell-id>/
```

`--no-cache` is non-negotiable: SHA-identical inputs would otherwise return
the same cached lift across all 10 replicates and Monte Carlo variance would
collapse to zero. The harness `eval/run_experiment.py` enforces this and
copies the per-run artefacts into `eval/runs/<cell-id>/run_NN/`.

### 2.4 What is held constant

- The 9 Speckit folders (pinned)
- `patterns.md` (the curated 15-pattern catalogue)
- The lifter system prompt (`DESIGN_LIFT_SYSTEM_PROMPT`)
- Alloy version (bundled `tools/alloy.jar`)
- Java runtime (jdk4py)
- Extended-thinking budget (held at maximum for each model that supports
  it; specific budget values per model documented in Appendix D after
  Phase E0a)

### 2.5 What varies

- The cell (domain × richness)
- **The model** (M-best, M-mid, M-small) — each model is run with its
  own optimal request-body configuration (extended thinking enabled to
  maximum where supported), so each model is being given its best
  shot per Phase E0a
- The replicate index 1..10 — same (cell, model, prompt), distinct
  sampling via Anthropic API non-determinism

## 3. AQS — the Alloy Quality Score

AQS (Alloy Quality Score) is a composite metric normalised to [0, 1],
analogous in role to Charlotte's KQS (KPI Quality Score). AQS is a
**structural quality metric, not a semantic one**: a high AQS means the
lifted Alloy is well-formed, traceable, and non-vacuous. It does **not** mean
the encoded invariants capture the FR's intended meaning. The known FR-15
`NoInformationLeakage` case in `002-bank-transfer-audit` — where the lifter
produced a compiling, FR-mapped, mutation-resistant predicate that was in
fact a tautology — is the canonical example of high-AQS-but-semantically-wrong
output. This limitation is acknowledged up front, in parallel with Charlotte's
"KQS is structural validity, not semantic quality" disclaimer.

### 3.1 Five dimensions

All five dimensions return a value in {0.0, 0.5, 1.0}. Three-level scoring is
inherited from Charlotte's rubric design and avoids the all-or-nothing penalty
that misrepresents partial-credit outcomes.

#### D1 — Syntactic & semantic compilability

| Score | Condition |
|---|---|
| 1.0 | Alloy returns parseable verdicts AND `list_assertions(als)` ≥ 1 |
| 0.5 | Alloy parses the model but the lifter emitted 0 `assert` declarations |
| 0.0 | Alloy errors out (parse failure, scope error, no parseable output) |

Source: `outcome.results`, `list_assertions(feature_model.als)`.

This is a hard floor — most successful Phase-3 lifts will score 1.0. It exists
so that L1 cells where the LLM bails out are scored 0.0 rather than being
silently missing from the dataset.

#### D2 — Pattern grounding

For each pattern name in `manifest.patterns_applied`:
- 1.0 if the name matches a valid pattern in `patterns.md` **AND** a
  corresponding `pred <Name>` declaration appears in the .als
- 0.5 if the name is valid in `patterns.md` but no matching predicate is
  declared (or vice versa)
- 0.0 if the name is not in `patterns.md` at all (hallucinated)

D2 score = mean across the manifest's declared patterns.

Source: `manifest.patterns_applied`, `patterns.md`, `list_assertions(als)`.

This is the analogue of Charlotte's "WAF code precision" — it tests whether
the LLM cites authoritative grounding consistently.

#### D3 — Mutation discrimination (with over-constraint disambiguation)

For each `mutation_target` declared in the manifest:

1. Apply the mutation (clear the named fact, append `inject_violation`),
   re-run Alloy.
2. If **all** of `asserts_violated` for that target now FAIL → **1.0** (BIT).
3. If at least one targeted assertion still PASSes:
   - Apply the **over-constraint test**: take the un-mutated model, append
     just the `inject_violation` snippet, re-run Alloy.
   - If that combined model is UNSAT → **0.5** (over-constraint: the
     violation is incompatible with the rest of the model, so the assertion
     can't fail — the predicate is correct but redundantly enforced).
   - If SAT → **0.0** (genuine vacuity / tautology: a counterexample exists
     but the assertion fails to detect it).

D3 score = mean across declared mutation targets.

Source: `mutation_outcomes.json` (extended to record over-constraint check).

**Rationale.** The current Phase-3 mutation engine reports VACUOUS for two
distinct failure modes that should be scored differently. Genuine vacuity (a
tautological predicate) is a real assertion-strength problem; over-constraint
(the same invariant enforced by two named facts) is good engineering. The
over-constraint test distinguishes them with one additional Alloy run per
target (≈ 3 seconds each). This addresses the risk that stylistic LLM choices
unfairly drag the rubric down.

#### D4 — FR coverage and verdict

For each FR-NNN parsed from `spec.md`:
- 1.0 if it has ≥ 1 matching assertion (via `fr_coverage(...)`) AND ≥ 1 of
  those assertions returned PASS
- 0.5 if it has matching assertions but **all** of them returned FAIL
- 0.0 if it has no matching assertion (uncovered FR)

D4 score = mean across FRs in `spec.md`.

Source: `parse_spec`, `fr_coverage(...)`, `outcome.by_name()`.

This is the analogue of Charlotte's "GQM chain coherence" — it tests whether
the lifter produces traceable, useful predicates per FR.

#### D5 — Verdict stability across replicates (computed per cell, not per run)

Across the 10 replicates of a given cell:

1. Build a normalised assertion key per assertion in each replicate:
   - If the assertion name matches a `patterns_applied` entry → use the
     pattern name as key.
   - Else if the name matches the regex `FR_(\d+)_.*` → use `FR-NNN` as key.
   - Else → fall back to the literal assertion name.
2. For each key that appears in ≥ 5 of the 10 replicates: compute the modal
   verdict count divided by the number of replicates the key appeared in.
3. D5 for the cell = mean of these per-key stability scores.
4. Keys appearing in < 5 replicates are excluded (treated as noise).

D5 captures two things together: (a) does the lifter produce a stable set
of assertions across replicates, and (b) when the same logical assertion
appears in multiple replicates, does it return the same verdict?

Source: cross-run aggregation in `aggregate.py`.

### 3.2 Composite

Per run: `aqs_partial = mean(D1, D2, D3, D4)` in [0, 1].
Per cell: `aqs_full = mean(D1, D2, D3, D4, D5)` in [0, 1].

## 4. Per-run output schema

Each replicate produces, in `eval/runs/<cell-id>/<model-tag>/run_NN/`:

- `input_spec/` — symlink or copy of `eval/specs/<cell-id>/` for traceability
- `feature_model.als` — the lifted Alloy model
- `feature_model.manifest.json` — the LLM's structured manifest
- `alloy_verdicts.json` — `{assertion_name: "PASS"|"FAIL"}`
- `mutation_outcomes.json` — `{fact_name: {targeted_asserts: {a: "BIT"|"VACUOUS_OVERCONSTRAINT"|"VACUOUS_TAUTOLOGY"}, all_bit: bool}}`
- `cost_log.json` — `{run_id, model, thinking_enabled, thinking_budget_tokens, input_tokens, output_tokens, thinking_tokens, cost_usd, cost_per_assertion_usd, started_at, elapsed_seconds}`
- `report.txt` — legacy `verify-design` text report (still produced)
- `scores.json` — per-run D1..D4 + `aqs_partial` + `model` tag

`<model-tag>` is one of `M-best`, `M-mid`, `M-small`, mapped to concrete
Anthropic API model strings in Appendix D.

`alloy_verdicts.json`, `mutation_outcomes.json`, and `cost_log.json` are new
artefacts added in Phase E0b instrumentation. The `model`,
`thinking_enabled`, `thinking_budget_tokens`, and `thinking_tokens` fields
in `cost_log.json` are new in this revised plan to support the model
factor.

## 5. Statistics

The same statistical machinery Charlotte applies to KQS, applied to AQS.
Stage 1 statistics run on the M-best dataset alone; Stage 2 statistics
extend the analysis when the additional model data is present.

### Stage 1 — On the 90-run M-best dataset

- **Overall richness effect**: Kruskal-Wallis H test on per-run
  `aqs_partial` grouped by richness level (L1, L2, L3), pooled across
  domains.
- **Per-domain richness effect**: Kruskal-Wallis H test, one per domain.
- **Pairwise richness contrasts**: Mann-Whitney U on L1-vs-L2, L1-vs-L3,
  L2-vs-L3, Bonferroni-corrected for 3 comparisons.
- **Effect sizes**: Cohen's d for each pairwise contrast.
- **Stability differences**: Kruskal-Wallis on per-key D5 across richness
  levels; pairwise Mann-Whitney with Bonferroni.

### Stage 2 — Additional statistics (only when Stage 2 data present)

When `aggregate.py` finds M-mid and M-small data in the CSVs, the same
`statistics.py` script extends to:

- **Overall model effect**: Kruskal-Wallis H test on per-run `aqs_partial`
  grouped by model (M-best, M-mid, M-small), pooled across cells.
- **Per-richness-level model effect**: Kruskal-Wallis H test, one per
  richness level — does model capability matter more at L1 (where the
  LLM has to fill in defaults) or at L3 (where the LLM has less to
  invent)?
- **Per-domain model effect**: Kruskal-Wallis H test, one per domain.
- **Pairwise model contrasts**: Mann-Whitney U on M-best-vs-M-mid,
  M-best-vs-M-small, M-mid-vs-M-small, Bonferroni-corrected for 3
  comparisons.
- **Cross-factor effect-size comparison**: compute Cohen's d for the
  L1-vs-L3 contrast on M-best, and for the M-best-vs-M-small contrast
  on L2. Whichever is larger tells the headline story for H6.

α = 0.05. Cohen's d interpretation: small ≥ 0.2, medium ≥ 0.5, large ≥ 0.8
(Cohen 1988). All statistics committed to `eval/statistics.py` — Charlotte's
own evaluation reported these numbers in the write-up but did not commit
the analysis script; we commit ours for reproducibility.

## 6. Figures

Up to six figures total. Stage 1 produces four; Stage 2, if triggered,
adds two more.

**Stage 1 headline figures (always produced, M-best only):**

1. `bar_chart_aqs_by_richness.png` — mean AQS by richness × context, with
   95% CI error bars.
2. `verdict_stability_heatmap.png` — D5 per cell × normalised assertion-key
   group (analogue of Charlotte's variance heatmap).
3. `pattern_coverage.png` — number of distinct patterns activated per cell,
   coloured by richness.
4. `cost_efficiency.png` — dual-axis cost-per-assertion (USD) and mean AQS
   vs richness, one line per domain.

**Stage 2 model-comparison figures (only produced if M-mid/M-small data present):**

5. `bar_chart_aqs_by_model.png` — mean AQS by model × richness, with 95%
   CI error bars; three sub-panels by domain. The headline "does model
   capability matter?" figure.
6. `cost_quality_frontier.png` — scatter of mean AQS vs mean cost-per-run
   (USD), one point per (model, richness, domain) cell; clusters by
   model. Shows the cost-quality frontier the practitioner faces.

`visualise.py` checks for the presence of M-mid and M-small data in the
aggregated CSVs and conditionally generates figures 5–6. If those data
are absent, the script logs that fact and exits cleanly after generating
figures 1–4.

## 7. Folder layout

```
spec-led-eval/eval/
├── EVALUATION_PLAN.md          # this file
├── MODEL_SELECTION.md          # Phase E0a output — exact model strings + thinking config
├── specs/                      # 9 pinned Speckit folders (one per cell)
│   ├── A-L1/{spec.md, data-model.md, plan.md, contracts/http-api.md, ...}
│   ├── A-L2/{...}
│   ├── A-L3/{...}
│   ├── B-L1/...
│   ├── ...
│   └── C-L3/...
├── run_experiment.py           # iterates 9 × 3 × 10 = 270 runs over (cell, model, rep)
├── scorer.py                   # D1..D4 deterministic scorer (model-agnostic)
├── aggregate.py                # D5 across replicates, writes CSVs (model-aware)
├── statistics.py               # Kruskal-Wallis + Mann-Whitney + Cohen's d on richness AND model
├── visualise.py                # 6 PNGs
├── tests/test_scorer.py        # pytest, mirrors Charlotte's coverage
├── runs/<cell-id>/<model-tag>/run_NN/   # per-run outputs (see §4)
└── results/
    ├── all_scores.csv          # one row per (cell, model, replicate, assertion)
    ├── cell_summary.csv        # one row per (cell, model) — aggregated AQS
    ├── statistics_report.txt
    └── figures/
        ├── bar_chart_aqs_by_richness.png      # headline (M-best only)
        ├── verdict_stability_heatmap.png      # headline (M-best only)
        ├── pattern_coverage.png               # headline (M-best only)
        ├── cost_efficiency.png                # headline (M-best only)
        ├── bar_chart_aqs_by_model.png         # model-comparison
        └── cost_quality_frontier.png          # model-comparison
```

`<model-tag>` is one of `M-best`, `M-mid`, `M-small`.

## 8. Phases

Phases are grouped into **shared infrastructure** (everything before the
actual sweeps; needed for both stages), then **Stage 1** (the main 90-run
M-best evaluation and write-up), then **Stage 2** (the deferred,
independently-triggerable model-comparison extension).

### Shared infrastructure

| Phase | Description | Effort |
|---|---|---|
| **E0a** *(preflight, no code)* | **Model research and selection.** Read Anthropic docs to identify (a) the current best-frontier model with maximum reasoning capacity and largest context window for the M-best tier, (b) the Sonnet-tier model for M-mid, (c) the Haiku-tier model for M-small. Document the exact API model strings, pricing, context window sizes, and the request-body shape needed to enable extended thinking at the maximum supported budget per model. Verify which models support the `thinking` field, and what `budget_tokens` value is the cap. Commit findings as `eval/MODEL_SELECTION.md` (also surfaced into Appendix D of this plan once filled in). All three tiers are researched even though Stage 2 may never run — re-research later would risk model lineup drift, and the cost of researching three tiers vs one is negligible. **This must complete before E0b. No implementation work happens until E0a's selections are committed.** | ≈ 0.5 day |
| **E0b** | Instrumentation: add `cost_log.json` (now including `model`, `thinking_enabled`, `thinking_budget_tokens`, `thinking_tokens` fields), `alloy_verdicts.json`, `mutation_outcomes.json` emission to `lifter_design.py` and `cli.py`; add over-constraint test for D3; extend `providers/anthropic.py` to accept and send the `thinking` field per E0a's spec; add a `--model M-best\|M-mid\|M-small` flag to `verify-design` (default: `M-best`). | ≈ 1 day |
| **E1** | Run Speckit on 9 feature prompts (Appendix A), pin each output to `eval/specs/<cell-id>/` | ✅ done 2026-05-17 |
| **E2** | Write `run_experiment.py` — accepts `--models M-best[,M-mid,M-small]` (default `M-best` for Stage 1). Iterates `9 cells × <selected models> × 10 replicates`. Calls `verify-design --no-cache --model <model-tag>` per cell-model-rep. Writes to `runs/<cell-id>/<model-tag>/run_NN/`. | ≈ 0.5 day |
| **E3** | Write `scorer.py` for D1..D4 + `tests/test_scorer.py`. Scorer is model-agnostic — it reads run-dir artefacts and emits one scored record per assertion with the `model` tag carried through. | ≈ 1 day |
| **E4** | Write `aggregate.py` — walks every `runs/<cell>/<model>/run_NN/scores.json` that exists, computes D5 per (cell, model) group, writes `all_scores.csv` and `cell_summary.csv` with `model` as a column. Gracefully handles "only M-best data present" by aggregating only what's there. | ≈ 0.5 day |
| **E5** | Write `statistics.py` (Kruskal-Wallis + Mann-Whitney + Cohen's d on the richness factor always; ALSO on the model factor if M-mid and M-small data are present in the CSVs) + `visualise.py` (4 headline figures always; 2 model-comparison figures only if M-mid/M-small data present). | ≈ 1 day |

### Stage 1 — Main evaluation (90 runs)

| Phase | Description | Effort |
|---|---|---|
| **E6** | **Stage 1 sweep.** Run `python eval/run_experiment.py` (default: M-best only). 90 runs, ~30s LLM + 3s Alloy per run = ~60 min LLM-bound + ~5 min Alloy = ~1 hr wall clock. Cost ~$18 at M-best Opus pricing. Then run `aggregate.py`, `statistics.py`, `visualise.py` — which produce CSVs + the 4 headline figures + statistics report. | ≈ 0.5 day (overnight if you prefer) |
| **E7** | **Stage 1 write-up.** Headline results on H1–H4: richness gradient effect, mutation-discrimination behaviour, D5 stability, pattern activation breadth across the three domains. Limitations section acknowledges that the model factor was deliberately deferred to Stage 2. | ≈ 1 day |

**Stage 1 stops here.** The full evaluation chapter of the project report
can be written from Stage 1 alone. Charlotte's evaluation has the same
shape (90 runs, single-model); Stage 1 matches her methodology one-for-one.

### Stage 2 — Model comparison (deferred, optional, +180 runs)

| Phase | Description | Effort |
|---|---|---|
| **E8** | **Stage 2 sweep, triggered independently.** Run `python eval/run_experiment.py --models M-mid,M-small`. 180 runs, ~$7 in API cost, ~30-40 min wall clock (Sonnet and Haiku are both much faster than Opus). Outputs land in `runs/<cell>/M-mid/` and `runs/<cell>/M-small/` next to the existing `M-best/` directories — Stage 1 data is untouched. Re-run `aggregate.py`, `statistics.py`, `visualise.py` — they now have data for all three models, so they produce the model-comparison figures and statistics in addition to the headline ones. | ≈ 0.5 day |
| **E9** | **Stage 2 write-up addendum.** Adds a model-comparison section to the chapter: H5 (model capability dominates), H6 (effect-size comparison vs richness), H7 (smaller models more variant). Re-uses Stage 1's framing; only adds new figures and a new sub-section. | ≈ 1 day |

### Effort totals

- **Stage 1 path only (skip Stage 2):** 7-8 working days. Matches the original pre-revision estimate.
- **Stage 1 + Stage 2:** 8.5-9.5 working days.
- The extra Stage 2 cost (≈ $7 API + ~1.5 days of effort) is the entire price of adding the model-comparison study. Triggered independently whenever Leon decides — could be the day after Stage 1 finishes, or weeks later when the report's other chapters are done.

## 9. Pre-registered hypotheses

Committed before any results are collected.

### Stage 1 hypotheses — tested on the 90-run M-best dataset

These are the primary scientific claims of the evaluation. Stage 1 alone
suffices to test all four.

- **H1** AQS is **monotone non-decreasing with richness** (richer prompts →
  richer Speckit artefacts → more concrete Alloy predicates). Direction:
  L1 ≤ L2 ≤ L3. *Plausibly opposite to Charlotte's inverted-U finding for
  KQS, because the Alloy lifter benefits structurally from explicit data-model
  and contract content, whereas her LLM benefits semantically from non-numeric
  context.*
- **H2** D3 mutation discrimination scales with richness — richer artefacts
  reduce duplicated-fact / vacuous-predicate rates.
- **H3** D5 stability is **higher at L3** than at L1 — richer inputs constrain
  the lifter and reduce structural variance across replicates.
- **H4** Healthcare and Banking show **higher pattern activation breadth**
  than SaaS, because the security/audit-heavy patterns in `patterns.md` map
  more naturally onto those domains.

### Stage 2 hypotheses — tested on the full 270-run dataset (deferred)

These are committed now (so they remain pre-registered if/when Stage 2
runs), but the data to test them is not collected unless Stage 2 is
triggered.

- **H5** Model capability is a **dominant determinant of AQS, ordered
  M-best > M-mid > M-small at every richness level**.
- **H6** The effect size of model (M-best-vs-M-small) is **larger** than
  the effect size of richness (L1-vs-L3) at fixed model. *If H6 holds,
  the practitioner takeaway is: invest in the best model before
  investing in richer prompts. If H6 fails, the opposite.*
- **H7** Smaller models (M-small) show **higher Monte Carlo variance**
  (lower D5) than larger models at every richness level — capability
  reduces output instability, not just average quality.

## 10. Limitations

1. **AQS is structural, not semantic.** A high-AQS predicate can still encode
   the wrong invariant (FR-15 `NoInformationLeakage` is the worked example).
   Same disclaimer Charlotte makes for KQS.
2. **N=10 replicates per cell-model combination.** Same as Charlotte. If D5
   confidence intervals are too wide on the actual results, we may need to
   extend to 20 replicates (budget allows).
3. **Speckit variance is held constant.** One Speckit output is pinned per
   cell; we do not measure Speckit's own non-determinism. A separate study
   could vary Speckit replicates per cell.
4. **Domain coverage is three.** Same as Charlotte. The findings generalise
   only as far as the three sampled domains; cross-domain claims are
   suggestive, not conclusive.
5. **Cell-level richness is operationalised via the prompt to Speckit, not
   via direct artefact-content control.** The mapping prompt → artefact is
   mediated by Speckit's own LLM and may not be monotone in every specific
   case. The pinning protocol mitigates this at the run-replicate level but
   not at the cell level.
6. **No human qualitative review of the lifted Alloy.** A human-grader study
   on a subsample of cells (analogous to Charlotte's planned business-vs-
   technical-register follow-up) is out of scope here but would complement
   AQS by addressing semantic correctness directly.
7. **Model coverage is three Anthropic models.** Cross-vendor comparisons
   (Anthropic vs OpenAI vs Google) are out of scope here. The three tiers
   are chosen to bracket the capability axis within a single vendor's
   lineup, which makes the per-tier comparison cleanest (same prompt,
   same API, same conventions). Generalising the M-best > M-mid > M-small
   ordering to other vendors is suggestive, not conclusive.
8. **Extended thinking is enabled at maximum** on every model that supports
   it. This is a deliberate "best shot per model" choice (Phase E0a); it
   means we are not comparing models *at the same compute budget* but
   rather *at each model's strongest configuration*. This is the right
   methodology for "which model should a practitioner choose," but the
   wrong methodology for "which model is fundamentally most capable per
   token of compute" — a different study.
9. **Thinking-mode asymmetry between tiers.** Phase E0a established that
   Opus 4.7 only supports *adaptive* thinking (with `effort: "max"`),
   while Haiku 4.5 only supports *manual* extended thinking (with
   `budget_tokens: 16384`); Sonnet 4.6 supports both but is run in
   adaptive mode for symmetry with Opus 4.7. This means M-best and
   M-mid let the model decide how many thinking tokens to spend
   per call, whereas M-small is constrained to a fixed 16k thinking
   budget. The asymmetry is an artefact of Anthropic's API surface,
   not a deliberate design choice. It is consistent with the "best
   shot per model" methodology (each tier runs in its strongest
   supported configuration) but means H5–H7 should be interpreted as
   "is the best-configured Opus better than the best-configured
   Sonnet better than the best-configured Haiku," not "is Opus better
   than Sonnet better than Haiku at matched thinking budgets." See
   `eval/MODEL_SELECTION.md` §1 for the full rationale.

## 11. Comparison with Charlotte's KQS evaluation

|  | Charlotte (KPI agent) | This plan (Alloy lifter) |
|---|---|---|
| Input format | Hand-crafted single-`.md` files | Real Speckit folders (`spec.md` + `data-model.md` + `contracts/http-api.md`) |
| Domains | Banking, SaaS, Healthcare | Banking, SaaS, Healthcare |
| Richness ladder | L1/L2/L3 in FR sentence detail | L1/L2/L3 in Speckit prompt detail |
| Replicates per cell | 10 | 10 |
| Composite metric | KQS = mean(D1..D5) ∈ [0,1] | AQS = mean(D1..D5) ∈ [0,1] |
| D1 | Threshold specificity | Compilability |
| D2 | WAF code precision | Pattern grounding |
| D3 | Directionality coherence | Mutation discrimination (BIT / over-constraint / tautology) |
| D4 | GQM chain coherence | FR coverage + verdict |
| D5 | Monte Carlo threshold stability | Monte Carlo verdict-and-key stability |
| Statistics | Kruskal-Wallis + Mann-Whitney + Cohen's d | Same |
| Figures | 4 PNGs | Same 4 PNG types |
| Statistics script | Not committed | Committed (`statistics.py`) |
| Limitation disclaimer | "KQS is structural, not semantic" | Same wording, FR-15 as worked example |

---

## Appendix A — Speckit feature prompts

Each prompt below is fed verbatim to `/speckit-specify` in Claude Code,
followed by `/speckit-plan`. The produced folder is pinned to
`eval/specs/<cell-id>/`.

### A-L1 — Banking, sparse

```
Build a loan application feature where customers can apply for personal loans and bank staff can approve or reject them.
```

### A-L2 — Banking, standard

```
Build a loan application feature for a retail bank. Authenticated customers can submit loan applications specifying the amount requested and the purpose. Loan officers can review pending applications and approve or reject them; only the loan officer assigned to an application can change its status. Compliance reviewers can read any application and its decision history but cannot modify it. Every status change must be recorded in an audit trail showing the actor, timestamp, and previous/new status.
```

### A-L3 — Banking, rich

```
Build a loan application feature for a retail bank under FCA consumer credit regulation. Authenticated customers (role: applicant) can submit loan applications for amounts between £1,000 and £25,000 with a stated purpose drawn from a fixed list of categories. Each application is automatically assigned to one loan officer (role: officer) on submission. Only the assigned officer can change an application's status (pending → under_review → approved | rejected); applicants cannot modify an application after submission, and officers cannot self-approve their own applications. Compliance reviewers (role: auditor) have read-only access to any application and its full decision history but must not be able to modify any record. Every state transition must be written to an immutable audit log within 2 seconds of occurrence, capturing application_id, actor_id, actor_role, timestamp (UTC ISO 8601), previous_status, new_status, and a reason field. Audit log entries cannot be updated or deleted; logs must be retained for at least 6 years to satisfy FCA SYSC record-keeping rules. All API endpoints must require OAuth 2.0 bearer authentication; unauthenticated requests must be rejected with HTTP 401 before any business logic runs. The system must enforce that the response to GET /applications/{id} for two applications belonging to different applicants is byte-equivalent to outsiders, preventing information leakage about other customers' applications. Available endpoints: POST /applications, GET /applications/{id}, PATCH /applications/{id}/status, GET /applications/{id}/audit.
```

### B-L1 — SaaS, sparse

```
Build a feature where team members can create and manage tasks.
```

### B-L2 — SaaS, standard

```
Build a task management feature for a SaaS workspace where authenticated team members can create, edit, and delete tasks within their team. Each task is owned by the member who created it. Team admins can edit or delete any task in their team. Members cannot see or modify tasks belonging to other teams. The system must keep an audit trail of changes to each task, including who made the change and when.
```

### B-L3 — SaaS, rich

```
Build a task management feature for a multi-tenant SaaS workspace. Each user is authenticated via OAuth 2.0 and belongs to exactly one team identified by team_id. Users have one of two roles: member or team_admin. Members can create, edit, delete, and view tasks they own; they cannot view or modify any task owned by another user, even within the same team, except where a task has been explicitly shared with them. Team admins can view, edit, and delete any task within their own team, but have no access to other teams' tasks. Cross-team data isolation must be absolute: the response payload for GET /tasks/{id} must be byte-equivalent for an unauthorised caller regardless of whether the requested task exists in a different team. Every mutation (create, edit, delete) must be appended to a task-level audit log within 1 second of the operation completing; entries record task_id, actor_user_id, actor_role, timestamp, operation, and a diff_summary. Audit entries are immutable. The API must sustain at least 200 requests per second per workspace at p99 latency ≤ 300ms. Endpoints: POST /tasks, GET /tasks/{id}, PATCH /tasks/{id}, DELETE /tasks/{id}, GET /tasks/{id}/audit.
```

### C-L1 — Healthcare, sparse

```
Build a feature where clinicians can access patient medical records.
```

### C-L2 — Healthcare, standard

```
Build a clinical record access feature for a hospital information system. Authenticated clinicians can read patient records and add new clinical notes. Only the patient's assigned care team can read or modify their records. Hospital administrators can read access logs but cannot read the clinical content of records. Every access event must be logged including which user accessed which record and when.
```

### C-L3 — Healthcare, rich

```
Build a clinical record access feature for a hospital information system under HIPAA. Authenticated users carry one of three roles: clinician, patient, or compliance_officer. Clinicians can read a patient's medical record only if they are listed in that patient's current care team (a many-to-many relationship); clinicians outside the care team must be rejected with HTTP 403 within 200ms. Clinicians who are in the care team can append clinical notes (a write-only operation) but cannot modify or delete existing notes. Patients (role: patient) can read their own records and their own access logs but no one else's, and cannot write any clinical content. Compliance officers can read all access logs system-wide but cannot read the clinical content of records, and cannot write to any record. The system must enforce that the response to GET /records/{id} is byte-equivalent for any caller without permission, regardless of whether the record exists — preventing information leakage about which patient identifiers exist. Every record-access event (read, append, list) must be written to an append-only audit log within 1 second, capturing record_id, accessor_user_id, accessor_role, timestamp (UTC ISO 8601), operation type, and originating IP address. Audit entries cannot be updated or deleted, and must be retained for at least 7 years to satisfy HIPAA §164.530(j). Endpoints: GET /records/{id}, POST /records/{id}/notes, GET /records/{id}/audit, GET /access-log.
```

---

## Appendix B — Speckit invocation procedure (per cell)

For each cell (9 cells total):

1. In a terminal, `cd` to `speckit-trial/` and launch Claude Code.
2. In Claude Code, run: `/speckit-specify <prompt from Appendix A>`
3. Answer any clarifying questions consistent with the prompt's richness
   level. For L1 prompts, defer to Speckit's defaults rather than adding
   detail. For L3 prompts, supply specific numeric or regulatory
   information when asked.
4. Once `spec.md` is generated, run: `/speckit-plan`
5. Verify the generated folder contains: `spec.md`, `data-model.md`,
   `plan.md`, `contracts/http-api.md`.
6. **Do not run `/speckit-tasks` or `/speckit-implement`** — those phases
   produce implementation artefacts the Alloy lifter does not consume.
7. Copy the generated folder into `spec-led-eval/eval/specs/<cell-id>/`
   (where `<cell-id>` is one of `A-L1`..`C-L3`).

After all 9 cells, verify each `eval/specs/<cell-id>/` contains the three
files the Phase-3 lifter requires. A small sanity check:

```
for cell in A-L1 A-L2 A-L3 B-L1 B-L2 B-L3 C-L1 C-L2 C-L3; do
  ls eval/specs/$cell/spec.md eval/specs/$cell/data-model.md \
     eval/specs/$cell/contracts/http-api.md >/dev/null \
   && echo "$cell  OK" \
   || echo "$cell  MISSING"
done
```

---

## Appendix C — Phase E1 outcomes (committed 2026-05-17, after the 9-cell sweep)

Phase E1 ran successfully but surfaced three methodological points that
were not anticipated in the original plan. They are documented here so the
experiment is reproducible and the deviations are auditable.

### C.1 Clarification-resolution rule

Speckit's `/speckit-specify` skill may produce `[NEEDS CLARIFICATION]`
markers when the prompt leaves scope-defining decisions open. The evaluator
resolves them with the smallest option that is faithful to what the prompt
already states — never elaborating beyond the prompt, never contradicting
it. This rule is deterministic enough for anyone reproducing the experiment
to arrive at the same answers.

In practice:

- **B-L1** prompt was so sparse that smallest = `Q1: A, Q2: A, Q3: A`
  (Speckit's own defaults).
- **B-L2** prompt explicitly states multi-team workspace + admin role →
  `Q1: B, Q2: A` (Speckit's "recommended defaults").
- **B-L3** prompt implies sharee can edit but not delete shared tasks →
  `Q1: A, Q2: A, Q3: B`.
- **C-L1** needed `Q1: A (UK NHS), Q2: A (read-only), Q3: A (care-team
  membership)` — Speckit's "deliberately narrow v1" default.

### C.2 Healthcare governance-review override

Speckit's interaction protocol is **domain-sensitive**: for healthcare
prompts (cells C-L1, C-L2, C-L3) it inserts a "governance review pending"
block and refuses to auto-run `/speckit-plan` until the evaluator confirms
the review has happened. Banking and SaaS prompts do not trigger this.

For the experiment, the evaluator gives this override verbatim:

> *"This is a teaching/research trial of speckit for an evaluation
> experiment, not a real clinical deployment. The governance-review block
> does not apply. Please proceed to /speckit-plan now and keep the
> governance notice in plan.md as a documentation artefact."*

The governance notice remains visible in the produced spec/plan, which is
expected — the lifter treats it as ordinary prose.

This domain-sensitivity is itself a real finding about Speckit's
interaction protocol and is worth reporting in the write-up's
"experimental conduct" section.

### C.3 Self-containment override for C-L2 and C-L3

When generating C-L2 (originally `010-hospital-record-access`) and C-L3
(originally `011-hipaa-record-access`), Speckit's Claude-Code agent looked
at sibling features in `specs/` and chose to **defer entity definitions to
the C-L1 / 009 folder** ("see 009's data-model for column shapes",
"carry-forward from 010", etc.). The resulting `data-model.md` files only
declared 3-4 SQL tables instead of the 7-8 needed; the missing definitions
were references the lifter cannot follow (it only reads one cell's three
artefacts).

Both cells were re-generated with an augmented prompt appended verbatim:

> *"IMPORTANT METHODOLOGY NOTE: Produce a fully self-contained
> specification. Do not reference, defer to, or carry forward content from
> any other feature in the specs/ directory. Every entity, role, endpoint,
> constraint, SQL schema, and enum must be defined inline in this feature's
> own spec.md, data-model.md, and contracts/http-api.md. Treat this as if
> no other feature exists in the repo. Do not use phrases like 'see feature
> 010', 'carry-forward from 010', 'same as 010', or '(see 010's
> data-model)'."*

The re-runs produced `012-hospital-clinical-records` and
`013-hipaa-clinical-records` with zero carry-forward references and
substantially more inlined content. These are the cells pinned at
`eval/specs/C-L2/` and `eval/specs/C-L3/`.

A, B, and C-L1 cells did not need this override — they were already
self-contained. Only the two later healthcare cells (which Speckit treated
as "incremental features" on top of 009) required it. **The augmented
prompt should be applied if any C-L2 or C-L3 cell is ever re-run.**

### C.4 Audit results

All 27 artefacts (9 cells × 3 files) verified clean as of 2026-05-17:

| Check | Result |
|---|---|
| Files present | 27/27 OK |
| `[NEEDS CLARIFICATION]` markers | 0 |
| Template-string leakage | 0 |
| Entity-deferring carry-forward references | 0 |
| Cosmetic-only cross-references | 6 in B-L2 + B-L3 (all "see feature 005 for chained-hash pattern" prose asides; do not defer any entity content; lifter-irrelevant) |

### C.5 Richness gradient (input dataset)

Total artefact line counts:

| | L1 | L2 | L3 |
|---|---:|---:|---:|
| **A (Banking)** | 744 | 802 | 900 |
| **B (SaaS)** | 596 | 848 | 863 |
| **C (Healthcare)** | 642 | 864 | 1033 |

Monotone L1 < L2 < L3 across all three domains. C-L3 is the largest cell
(1033 lines). The gradient is preserved but compressed (1.5× max-to-min
ratio) compared to the prompt-character gradient (~50×); Speckit smooths
but does not flatten prompt richness — a publishable secondary finding.

### C.6 Cell-to-Speckit-folder mapping

For reproducibility — the Speckit-trial source folder for each pinned cell:

| Cell | Source folder in `speckit-trial/specs/` |
|------|---|
| A-L1 | `003-loan-application` |
| A-L2 | `004-loan-application-rbac` |
| A-L3 | `005-fca-loan-applications` |
| B-L1 | `006-task-management` |
| B-L2 | `007-team-tasks` |
| B-L3 | `008-task-sharing` |
| C-L1 | `009-clinician-record-access` |
| C-L2 | `012-hospital-clinical-records` (re-run with self-containment override) |
| C-L3 | `013-hipaa-clinical-records` (re-run with self-containment override) |

The original `010-hospital-record-access` and `011-hipaa-record-access`
folders were deleted from `speckit-trial/specs/` after the audit identified
their entity-deferral problem.

---

## Appendix D — Model selection (Phase E0a output)

**Status: COMMITTED 2026-05-17.** Full details and rationale are in the
standalone `eval/MODEL_SELECTION.md`. This appendix mirrors the
load-bearing tables and protocols so that the plan is self-contained.

Two findings from E0a deviate from the original placeholder assumptions
in this plan and are flagged up front:

1. **Opus 4.7 (M-best) does not support manual extended thinking.**
   `thinking: {"type": "enabled", "budget_tokens": N}` returns a 400
   error on Opus 4.7. The only supported thinking mode is *adaptive*
   thinking with the new `effort` parameter. This is a recent Anthropic
   API change (Opus 4.7 was released 2026-04-16); the plan's earlier
   phrasing about "thinking budget at maximum" must therefore be read
   as "effort=max on adaptive thinking" for M-best and M-mid, and
   "budget_tokens=16384 on manual extended thinking" for M-small.
2. **Haiku 4.5 (M-small) does support extended thinking** — manual
   mode with `budget_tokens`. (It does not support adaptive thinking.)
   So all three tiers run with thinking enabled at their best
   supported configuration. The asymmetry that does survive is
   "adaptive on Opus/Sonnet, manual on Haiku" — documented in
   Limitations §10.8.

### D.1 — Research questions (now answered in D.2 / D.3)

The original D.1 list — API string, context window, thinking support,
thinking budget, output cap, prices, request-body shape — is fully
addressed in the table and JSON examples below. See MODEL_SELECTION.md
for source URLs and reasoning.

### D.2 — Tier table (committed)

| Tier | API model string | Context | Thinking | Thinking config (this eval) | Max output (sync) | Input $/MTok | Output $/MTok |
|---|---|---:|---|---|---:|---:|---:|
| **M-best** | `claude-opus-4-7` | 1M | Adaptive only (manual = 400) | `{type: "adaptive", display: "omitted"}` + `effort: "max"` | 128k | $5.00 | $25.00 |
| **M-mid** | `claude-sonnet-4-6` | 1M | Adaptive (recommended) or manual (deprecated) | `{type: "adaptive", display: "omitted"}` + `effort: "max"` | 64k | $3.00 | $15.00 |
| **M-small** | `claude-haiku-4-5` | 200k | Manual only (no adaptive) | `{type: "enabled", budget_tokens: 16384}` | 64k | $1.00 | $5.00 |

Thinking tokens are billed as output tokens; there is no separate
thinking-token price line. Opus 4.7 uses a new tokenizer that may
consume up to ~1.35× more tokens than previous models for the same
input. `max_tokens` for all three tiers in this eval is **32000**
(see D.4).

### D.3 — Request-body templates (committed)

`<SYSTEM>` and `<USER>` are the existing `DESIGN_LIFT_SYSTEM_PROMPT`
and `build_design_lift_prompt(...)` outputs — unchanged across tiers.
Headers (`x-api-key`, `anthropic-version: 2023-06-01`, `content-type:
application/json`) are unchanged from the current lifter.

#### M-best — Claude Opus 4.7

```json
{
  "model": "claude-opus-4-7",
  "max_tokens": 32000,
  "thinking": {"type": "adaptive", "display": "omitted"},
  "output_config": {"effort": "max"},
  "system": "<SYSTEM>",
  "messages": [{"role": "user", "content": "<USER>"}]
}
```

#### M-mid — Claude Sonnet 4.6

```json
{
  "model": "claude-sonnet-4-6",
  "max_tokens": 32000,
  "thinking": {"type": "adaptive", "display": "omitted"},
  "output_config": {"effort": "max"},
  "system": "<SYSTEM>",
  "messages": [{"role": "user", "content": "<USER>"}]
}
```

#### M-small — Claude Haiku 4.5

```json
{
  "model": "claude-haiku-4-5",
  "max_tokens": 32000,
  "thinking": {"type": "enabled", "budget_tokens": 16384},
  "system": "<SYSTEM>",
  "messages": [{"role": "user", "content": "<USER>"}]
}
```

Note the absence of `output_config` on M-small — `effort` is an
adaptive-thinking parameter and is invalid in manual mode.

### D.4 — Implementation implications

- **`providers/anthropic.py` shape.** A single `complete(...)` function
  parameterised by a model tag (`M-best`/`M-mid`/`M-small`) is
  sufficient. The three tier configs differ only in three fields —
  `model`, `thinking`, and the presence/absence of `output_config` —
  which a `TIER_CONFIG` dict can supply.
- **`max_tokens` bump.** The current lifter sends `max_tokens: 16000`,
  which is marginal even without thinking and too small once thinking
  is enabled (`budget_tokens` must be strictly less than `max_tokens`
  on the manual tier; thinking eats into the cap on the adaptive
  tiers). Raise to **32000** in E0b. Fits the ~16k visible output of
  manifest+.als with comfortable buffer; well within all three tiers'
  caps (128k / 64k / 64k).
- **Timeout bump.** `timeout_seconds: 120` is too short for adaptive
  thinking at effort=max. Raise to **600 seconds**. `max_retries: 2`
  stays.
- **Streaming.** Not required. The Anthropic SDK's "max_tokens > 21,333
  requires streaming" rule is a client-side SDK validation, not an API
  restriction; the raw-`requests` provider is not subject to it. Keep
  the simple synchronous POST path.
- **Cost-log thinking tokens.** Anthropic's API does *not* currently
  expose thinking tokens as a separate field in `response.usage` —
  thinking tokens are folded into `output_tokens`. So
  `cost_log.json.thinking_tokens` should be set to `null` on all three
  tiers (the field is harmless to carry; it just won't be populated).
  `output_tokens` will be the billed total including thinking; that's
  what cost calculations should use. The `thinking_enabled` and
  `thinking_budget_tokens` fields are populated as in D.2 (budget is
  `null` for adaptive tiers, `16384` for M-small).
- **Error handling.** `stop_reason: "max_tokens"` is the failure
  signal when thinking blows the cap — it surfaces as a *200 response*
  with truncated content, not as a 4xx. Treat as a structural
  failure (the fenced-block parser will fail downstream, D1 scores
  0.0, run continues). No new 4xx error paths required beyond the
  existing 429/5xx retry logic.

### D.5 — Sanity check on M-small

Deferred to Phase E0b (requires the instrumented provider). Protocol:
one `verify-design --no-cache --model M-small` invocation on
`eval/specs/A-L2/`. Pass conditions:

1. Response contains both a fenced ```` ```alloy ```` block and a
   fenced ```` ```json ```` block (manifest).
2. Manifest parses as JSON; declares ≥ 1 entry each in
   `patterns_applied` and `mutation_targets`.
3. The .als compiles under Alloy (parseable verdicts).
4. D1 dimension scores 1.0.

If any condition fails, **drop M-small from the design** rather than
quietly substituting another model (asymmetry must be visible).
Stage 2 then runs M-mid only (180 → 90 runs); H6 and H7 are weakened
but still testable.

### D.6 — Cost re-estimate

Adaptive thinking at effort=max and Opus 4.7's new tokenizer make the
original cost estimates lower bounds. Updated envelopes:

| Stage | Model | Runs | Low estimate | High estimate |
|---|---|---:|---:|---:|
| 1 | M-best (Opus 4.7) | 90 | $18 | $50 |
| 2 | M-mid (Sonnet 4.6) | 90 | $4 | $12 |
| 2 | M-small (Haiku 4.5) | 90 | $1 | $4 |
| **Stage 1 + Stage 2** | | **270** | **~$23** | **~$66** |

These are documentation updates only; the methodology is unchanged.

---

## Appendix E — 2026-05-18 revision (post-E0b)

**Status: COMMITTED 2026-05-18.** Phase E0b (instrumentation + the
Opus 4.7 streaming/prompt work) is complete. The methodology pinned in
sections 1–11 and Appendix D above remains the *pre-registered* plan,
but reality diverged in four ways during E0b that need to be on the
record before Stage 1 sweeps. **Sections 1–11 and Appendix D are
preserved verbatim above so the audit trail is intact**; this appendix
captures the deviations. In any conflict between the body of the plan
and this appendix, the appendix is authoritative.

### E.1 — Methodology drift: effort=max → effort=high, with SSE streaming

**Original E0a choice** (Appendix D.2 / §3.1 of MODEL_SELECTION): Opus
4.7 + adaptive thinking + `output_config.effort = "max"`, synchronous
POST + JSON response. Rationale: "strongest extended-thinking
configuration available across M-best and M-mid".

**What changed.** During E0b implementation, `effort=max` proved
operationally unreliable on Opus 4.7: requests on richer cells (e.g.
A-L2) hung past the original 600-second timeout and past a manual
30-minute bound. Bumping the per-request timeout to 1800s did not help
because the underlying issue is HTTP connection liveness, not server
latency — the non-streaming socket has nothing to send back during the
multi-minute thinking phase and intermediate proxies drop it.

Dropping the effort knob to `effort: "high"` alone did **not** fix the
hang (same socket-liveness problem). The fix was to switch to **SSE
streaming**: `_consume_sse_stream(resp)` in
`speceval/providers/anthropic.py` parses Anthropic's
`message_start` / `content_block_start` / `content_block_delta` /
`message_delta` / `message_stop` events incrementally, which keeps the
socket alive throughout Opus 4.7's multi-minute thinking phase and
makes 5–15-minute lifts reliable.

With streaming working, the **final pinned M-best configuration** is:

- `model: "claude-opus-4-7"`
- `thinking: {type: "adaptive", display: "omitted"}`
- `output_config: {effort: "high"}`  *(was `effort: "max"`)*
- `max_tokens: 64000`  *(was 32000)*
- `timeout_seconds: 1800`  *(was 600)*
- `max_retries: 4`  *(was 2; with exponential backoff)*
- `stream: True`  *(was False)*

`effort: "high"` is Anthropic's documented default for Opus 4.7
adaptive thinking — strictly weaker than `"max"` but still extended-
thinking-on. The methodology drift is from "strongest available" to
"default-strong-and-actually-reliable". This is documented as
Limitation §E.4.2 below.

### E.2 — Stage 2 dropped: only H1–H4 are tested

**Original plan** (§2.0, §8): Stage 2 = +180 runs on M-mid and
M-small, optional but triggerable. Hypotheses H5/H6/H7 tested only
when Stage 2 runs.

**2026-05-18 decision:** Stage 2 is **dropped from this project**.
Hypotheses **H5, H6, H7 will not be tested**. Stage 1's 90 M-best runs
remain the full experimental dataset.

**Reasons:**

- E0b's empirical cost envelope for Opus 4.7 (~$1/lift, see §E.3) is
  higher than the original $0.20/lift assumption baked into the
  Stage 1+2 cost estimates. Stage 1 alone now budgets ~$90.
- The lifter prompt was iterated three times during E0b based on
  empirical Alloy-parse failures observed on Opus 4.7 (see §E.4.3).
  These fixes are now well-validated on M-best but have **not** been
  re-validated on M-mid or M-small. Running Stage 2 without that
  re-validation would conflate "model is weaker" with "prompt was
  tuned for the strongest model"; running it *with* re-validation
  doubles the E0b effort budget.
- The M-best configuration retains its `M-mid`/`M-small` entries in
  `TIER_CONFIG` (so the harness's `--models` flag still accepts them
  syntactically), but only `M-best` is **validated** for use. The
  harness defaults to `--models M-best`.

§9 of the body still lists H5/H6/H7 as pre-registered hypotheses
because they were pre-registered. They are now marked **not tested**
in the write-up; the dissertation chapter will note that this leaves
the model-capability question open as future work.

### E.3 — Revised cost / wall-clock envelopes

Phase E0b's three-iteration 9-cell survey gave us anchor data for the
final M-best configuration:

| | E0a estimate (effort=max, no streaming) | E0b empirical (effort=high, streaming) |
|---|---|---|
| Per-lift cost | $0.20–$0.55 | **$0.90–$1.30** (range $0.40–$1.54) |
| Per-lift wall clock | unknown (hung) | **6–9 min mean** (range 2.7–38 min) |
| Output tokens per lift | ~5–15k | **~10k–30k** (Opus 4.7 thinks a lot) |
| **Stage 1 total cost** | $18–$50 | **~$90** |
| **Stage 1 total wall clock** | ~1 hr | **~15 hr (overnight-runnable)** |

This is the planning number for the Stage 1 sweep. The harness writes
`progress.json` so the 15-hour sweep is resumable if it is interrupted.

### E.4 — Additional methodological points to document

#### E.4.1 — Thinking budget reporting

`response.usage` from the streaming endpoint exposes only
`input_tokens` and `output_tokens`; thinking tokens are folded into
`output_tokens` (consistent with Appendix D.4 / §4.5 of MODEL_SELECTION).
`cost_log.json.thinking_tokens` is therefore `null` on M-best runs.
`output_tokens` is the billed quantity used for cost calculation.

#### E.4.2 — Effort level reported in the write-up

The methodology section should report **`effort: "high"`**, not
`"max"`. This is the level that produced the validated results.

#### E.4.3 — Lifter prompt iterated 3× during E0b

The system prompt (`DESIGN_LIFT_SYSTEM_PROMPT` in `speceval/prompts.py`)
was iterated three times during E0b based on empirical Alloy parse
failures observed on Opus 4.7 single-replicate lifts. The three
iterations:

1. **Fix A — Permission matrix syntax (rule 7).** The original prompt
   showed `sig Allowed in Role -> OperationKind {}`, which is **invalid
   Alloy 6 syntax** (`in` on a sig declaration takes a sig, not a
   relation product). Replaced with the singleton-sig-with-field
   pattern: `one sig PermMatrix { Allowed: set Role -> OperationKind }`
   plus `Role -> Op in PermMatrix.Allowed` fact statements. Fixed
   parse failures on A-L1/A-L2/A-L3, B-L1, B-L3.
2. **Fix B — F_NonEmptyUniverse fact (rule 9).** The original prompt
   advised adding `some <Sig>` witness clauses inside `pred` bodies to
   prevent vacuous truth. Alloy's empty-universe semantics make those
   in-pred witnesses **false** on empty-universe worlds, so the
   assertion check returns SAT and we record FAIL. Replaced with a
   single top-of-model `F_NonEmptyUniverse` fact (`some <DynamicSig>`
   for each dynamic sig). Fixed 21/21 spurious FAILs on B-L2 and
   13/18 on C-L1.
3. **Fix C — Parenthesize `implies one x: T | …` (rule 10).** Alloy's
   parser binds `one`/`some`/`lone` tighter than `|` after `implies`,
   so `P implies one log: Log | log.op = op` is a syntax error. Added
   the rule "parenthesize as `P implies (one log: Log | log.op = op)`".
   Eliminated B-L1's PARSE_FAIL.

These three fixes are **part of the methodology** and should be
flagged in §10 (Limitations) as: *"The lifter system prompt was
iterated three times during Phase E0b based on empirical Alloy-parse
failures on single-replicate Opus 4.7 lifts. The final prompt produces
~88% PARSE_OK on single-replicate lifts and ~97% aggregate PASS within
parsed cells; the iteration trajectory and per-fix empirical
validation are documented in this appendix."*

Specifically, this adds **Limitation §10.10** to the body of the plan:
*"The lifter prompt was iterated 3× during E0b in response to observed
Alloy parse errors and witness-clause-induced spurious FAILs. The
final prompt is therefore tuned to the empirical failure modes of
Opus 4.7 on the 9-cell input dataset. It is plausible that re-tuning
would be needed for a different model lineup, and we have not validated
the final prompt on M-mid or M-small (see §E.2)."*

#### E.4.4 — Real spec findings vs lifter bugs

Within the 8/9 PARSE_OK cells of the E0b validation run 3, the
remaining ~3% of FAILs are **real spec findings** — Alloy correctly
surfacing gaps in Speckit's prose-level specifications (e.g., A-L2
audit cardinality ambiguity; A-L3, B-L1, B-L3 task-management
semantic gaps; C-L1 information-leakage byte-equivalence when it
parses). This is exactly the "structural quality, not semantic
quality" signal AQS is designed to capture (cf. §10.1 of the body).
Stage 1's 10 replicates per cell will surface these consistently and
they should be reported as findings in the write-up, not as lifter
quality problems.

### E.5 — Section-by-section authoritative changes

For ease of reference when reading the body, these are the specific
sentences that are superseded by this appendix:

- **§2.0 and §8** — Stage 2 status changes from "deferred, optional"
  to "**dropped, not run**". The phase table's E8/E9 rows still exist
  in the body but are now marked obsolete.
- **§2.4** — "Extended-thinking budget held at maximum" → "held at
  Opus 4.7's `effort: "high"` (the default for adaptive thinking on
  M-best)".
- **§2.5** — "Each model run with its own optimal configuration" →
  "M-best run with its empirically validated configuration; M-mid and
  M-small are not run".
- **§5 (Stage 2 statistics)** — Section is obsolete; only Stage 1
  statistics are produced.
- **§6 (Stage 2 figures)** — Figures 5 and 6 are obsolete; only
  figures 1–4 are produced.
- **§9 (Stage 2 hypotheses)** — H5, H6, H7 remain pre-registered but
  are marked **not tested in this evaluation**.
- **§10 (Limitations)** — Add §10.10 per E.4.3 above.
- **Appendix D.2/D.3** — Opus 4.7 row's "effort: max" reads as
  "effort: high" per E.1. `max_tokens` reads as 64000 per E.1.
- **Appendix D.6 (cost re-estimate)** — Stage 1 high estimate is now
  ~$90 per E.3.

The original wording in those sections is preserved so the
methodology drift is visible in the audit trail.

