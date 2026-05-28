# System Architecture — Specification-Led Development

## High-Level Pipeline

```mermaid
flowchart TB
    subgraph INPUT["INPUT"]
        desc["Free-text Description<br/><i>'A banking transfer system<br/>with audit logging'</i>"]
    end

    subgraph PHASE0["PHASE 0 — SpecKit Generation"]
        direction TB
        gen["speckit_generator.py"]
        pass1["Pass 1: spec.md<br/><i>FRs, User Stories,<br/>Acceptance Criteria</i>"]
        pass2["Pass 2: data-model.md<br/><i>Entities, Relationships,<br/>Validation Rules</i>"]
        pass3["Pass 3: contracts/http-api.md<br/><i>Endpoints, Auth Matrix,<br/>Request/Response Schemas</i>"]

        gen --> pass1 --> pass2 --> pass3
    end

    subgraph SPECKIT["SPECKIT ARTEFACTS"]
        specmd["spec.md"]
        datamd["data-model.md"]
        apimd["contracts/http-api.md"]
    end

    subgraph PHASE1["PHASE 1 — Alloy Structural Verification"]
        direction TB
        patterns["patterns.md<br/><i>16 Structural Patterns</i>"]
        lifter["lifter_design.py<br/><i>LLM → Alloy 6 Model</i>"]
        als["feature_model.als<br/>+ manifest.json"]
        runner["runner.py<br/><i>java -jar alloy.jar</i>"]
        verdicts["Assertion Verdicts<br/><i>PASS / FAIL per check</i>"]
        mutation["Mutation Testing<br/><i>Remove facts, inject violations</i>"]
        mut_verdicts["Mutation Verdicts<br/><i>BIT / VACUOUS per target</i>"]

        patterns --> lifter
        lifter --> als --> runner --> verdicts
        als --> mutation --> mut_verdicts
    end

    subgraph PHASE2["PHASE 2 — WAF-KPI Derivation"]
        direction TB
        waf["waf_index_seed.json<br/><i>59 WAF Principles</i>"]
        embed["Semantic Search<br/><i>OpenAI Embeddings<br/>Cosine Similarity</i>"]
        gqm["GQM + KPI Derivation<br/><i>LLM per FR</i>"]
        kpi_out["GQM Records<br/>+ KPI Thresholds"]

        waf --> embed --> gqm --> kpi_out
    end

    subgraph REPORTING["UNIFIED REPORT"]
        reporter["unified_reporter.py"]
        report["unified_report.md<br/><i>Executive Summary<br/>Compliance Matrix<br/>FR Coverage<br/>Mutation Results<br/>KPI Targets</i>"]

        reporter --> report
    end

    subgraph PHASE3["PHASE 3 — Code Generation Pipeline"]
        direction TB
        extract["extract_verification_context.py<br/><i>→ verification_context.md</i>"]

        subgraph GUIDED["Guided Track"]
            g_code["Code Generation<br/><i>claude -p + guided_codegen.md<br/>+ verification_context.md</i>"]
            g_test["Test Generation<br/><i>claude -p + guided_testgen.md</i>"]
            g_run["pytest"]
        end

        subgraph BASELINE["Baseline Track"]
            b_code["Code Generation<br/><i>claude -p + baseline prompt<br/>description only</i>"]
            b_test["Test Generation"]
            b_run["pytest"]
        end

        scorer["score.py<br/><i>6-Dimension Scoring</i>"]
        judge["LLM Comparison Judge<br/><i>Qualitative Analysis</i>"]
        final["comparison_report.md<br/>+ scores.json"]

        extract --> GUIDED
        extract --> BASELINE
        g_code --> g_test --> g_run
        b_code --> b_test --> b_run
        GUIDED --> scorer
        BASELINE --> scorer
        scorer --> judge --> final
    end

    desc --> PHASE0
    PHASE0 --> SPECKIT
    SPECKIT --> PHASE1
    SPECKIT --> PHASE2
    verdicts --> reporter
    mut_verdicts --> reporter
    kpi_out --> reporter
    report --> PHASE3
```

## Component Detail — SpecKit Generator (Phase 0)

```mermaid
flowchart LR
    desc["Free-text<br/>Description"] --> cache{"SHA-256<br/>Cache Hit?"}
    cache -- Yes --> cached["Return<br/>Cached Artefacts"]
    cache -- No --> p1

    subgraph LLM["Three Sequential LLM Passes"]
        p1["Pass 1<br/>SPEC_SYSTEM_PROMPT<br/>+ description"]
        p2["Pass 2<br/>DATA_MODEL_SYSTEM_PROMPT<br/>+ description + spec.md"]
        p3["Pass 3<br/>HTTP_API_SYSTEM_PROMPT<br/>+ description + spec.md<br/>+ data-model.md"]
        p1 --> p2 --> p3
    end

    subgraph VALIDATE["Regex Validation"]
        v1["spec.md<br/><i>FR-NNN anchors<br/>Given/When/Then</i>"]
        v2["data-model.md<br/><i>Entity tables<br/>Relationships</i>"]
        v3["http-api.md<br/><i>Auth Matrix<br/>Endpoint defs</i>"]
    end

    p1 --> v1
    p2 --> v2
    p3 --> v3

    v1 & v2 & v3 --> out["specs/&lt;feature-id&gt;/"]
```

## Component Detail — Alloy Verification (Phase 1)

```mermaid
flowchart TB
    subgraph INPUTS["Design Inputs"]
        spec["spec.md"]
        dm["data-model.md"]
        api["http-api.md"]
        pat["patterns.md<br/><i>16 patterns</i>"]
    end

    cache{"SHA-256<br/>Cache Hit?"} -- Yes --> cached_als["Cached<br/>feature_model.als"]
    cache -- No --> llm["LLM Lifter<br/><i>DESIGN_LIFT_SYSTEM_PROMPT</i>"]

    INPUTS --> cache

    llm --> als["feature_model.als<br/><i>Self-contained<br/>Alloy 6 model</i>"]
    llm --> manifest["manifest.json<br/><i>patterns_applied<br/>fr_assertion_map<br/>mutation_targets</i>"]

    als --> alloy["Alloy Analyzer<br/><i>java -jar alloy.jar exec</i>"]
    alloy --> verdicts["Per-Check Verdicts<br/><i>check &lt;name&gt; for &lt;scope&gt;<br/>→ PASS / FAIL</i>"]

    manifest --> mut_loop

    subgraph mut_loop["Mutation Testing Loop"]
        direction TB
        target["For each mutation_target"]
        clear["Clear fact body → {}"]
        inject["Inject violation fact"]
        rerun["Re-run Alloy"]
        check{"Targeted assertions<br/>now FAIL?"}
        bit["BIT<br/><i>Assertion is meaningful</i>"]
        vacuous["VACUOUS<br/><i>Assertion is tautologous</i>"]

        target --> clear --> inject --> rerun --> check
        check -- Yes --> bit
        check -- No --> vacuous
    end

    als --> mut_loop
```

## Component Detail — KPI Derivation (Phase 2)

```mermaid
flowchart LR
    spec["spec.md"] --> parse["parse_spec()<br/><i>Extract FRs</i>"]
    parse --> fr_loop

    waf["waf_index_seed.json<br/><i>59 WAF Principles</i>"] --> embeddings["load_waf_embeddings()<br/><i>text-embedding-3-small<br/>cached locally</i>"]

    subgraph fr_loop["Per-FR Pipeline"]
        direction TB
        fr["FR-NNN"]
        search["search_waf()<br/><i>Cosine similarity<br/>Top-3 WAF matches</i>"]
        derive["derive_gqm_and_kpi()<br/><i>LLM call</i>"]
        fr --> search --> derive
    end

    embeddings --> search

    derive --> gqm["GQM Record<br/><i>goal, question,<br/>metric_name, metric_unit</i>"]
    derive --> kpi["KPI Records<br/><i>threshold_value<br/>threshold_numeric<br/>threshold_direction<br/>measurement_method</i>"]
```

## Component Detail — Code Generation (Phase 3)

```mermaid
flowchart TB
    report["unified_report.md"] --> extract["extract_verification_context.py"]
    manifest["manifest.json"] --> extract
    als["feature_model.als"] --> extract
    extract --> vc["verification_context.md<br/><i>1. Structural Patterns<br/>2. FR→Assertion Map<br/>3. Mutation Results<br/>4. Invariant Semantics<br/>5. Feature-Specific Predicates<br/>6. Full Unified Report</i>"]

    vc --> guided_code["Guided Code Gen<br/><i>claude -p<br/>guided_codegen.md</i>"]
    guided_code --> guided_test["Guided Test Gen<br/><i>claude -p<br/>guided_testgen.md</i>"]
    guided_test --> guided_run["pytest"]

    desc["Goal Description"] --> baseline_code["Baseline Code Gen<br/><i>claude -p<br/>baseline prompt</i>"]
    baseline_code --> baseline_test["Baseline Test Gen"]
    baseline_test --> baseline_run["pytest"]

    guided_run --> scorer

    subgraph scorer["score.py — 6 Dimensions"]
        direction LR
        d1["Structural<br/>Completeness<br/><i>25%</i>"]
        d2["FR<br/>Coverage<br/><i>25%</i>"]
        d3["Invariant<br/>Enforcement<br/><i>20%</i>"]
        d4["Test<br/>Quality<br/><i>15%</i>"]
        d5["KPI<br/>Instrumentation<br/><i>10%</i>"]
        d6["Security<br/>Posture<br/><i>5%</i>"]
    end

    baseline_run --> scorer
    scorer --> judge["LLM Comparison Judge"]
    judge --> verdict["GUIDED_WINS / BASELINE_WINS / TIE"]
    judge --> report_out["comparison_report.md<br/>scores.json<br/>cost_breakdown.json"]
```

## Orchestration & CLI

```mermaid
flowchart TB
    cli["speceval CLI<br/><i>cli.py</i>"]

    cli --> cmd_gen["speceval generate<br/><i>'description'</i>"]
    cli --> cmd_run["speceval run<br/><i>feature_dir/</i>"]
    cli --> cmd_doc["speceval doctor"]

    cmd_gen --> gen["speckit_generator.py<br/><i>Phase 0</i>"]
    gen --> specdir["specs/&lt;feature-id&gt;/"]

    cmd_run --> unified["unified_run.py"]

    unified --> |"--from-description"| gen
    unified --> |"Phase 1<br/>(unless --skip-alloy)"| verify["verify.py"]
    unified --> |"Phase 2<br/>(unless --skip-kpi)"| kpi["kpi_agent.py"]

    verify --> reporter["unified_reporter.py"]
    kpi --> reporter
    reporter --> runs["runs/&lt;feature-id&gt;/<br/><i>unified_report.md</i>"]

    runs --> pipeline["pipeline/run_pipeline.sh<br/><i>Phase 3</i>"]
    pipeline --> pipeline_runs["pipeline_runs/&lt;timestamp&gt;/"]

    cmd_doc --> doctor["Health Checks<br/><i>Java, Alloy JAR,<br/>test snapshots</i>"]
```

## Data Flow Summary

```mermaid
flowchart LR
    A["Free-text<br/>Description"] -->|Phase 0| B["SpecKit<br/>Artefacts<br/><i>spec.md<br/>data-model.md<br/>http-api.md</i>"]
    B -->|Phase 1| C["Alloy Model<br/>+ Verdicts<br/><i>20/20 PASS<br/>Mutation BIT/VACUOUS</i>"]
    B -->|Phase 2| D["GQM + KPI<br/>Targets<br/><i>10 GQM chains<br/>12 KPI thresholds</i>"]
    C --> E["Unified<br/>Report"]
    D --> E
    E -->|Phase 3| F["Generated Code<br/>+ Test Suite<br/><i>Guided vs Baseline<br/>6-dim scoring</i>"]
```

## Caching Strategy

```mermaid
flowchart TB
    subgraph cache["Content-Addressed Caching"]
        direction LR

        c0["SpecKit Cache<br/><i>SHA-256(<br/>description +<br/>config +<br/>system prompts<br/>)</i>"]

        c1["Design Lift Cache<br/><i>SHA-256(<br/>spec.md +<br/>data-model.md +<br/>http-api.md +<br/>patterns.md +<br/>system prompt<br/>)</i>"]

        c2["WAF Embedding Cache<br/><i>waf_embeddings_cache.json<br/>59 embeddings<br/>computed once</i>"]
    end

    c0 -->|hit| skip0["Skip 3 LLM calls"]
    c1 -->|hit| skip1["Skip lifter LLM call"]
    c2 -->|hit| skip2["Skip 59 embedding calls"]
```
