"""speceval.speckit_generator — generate SpecKit artefacts from a description.

Three sequential LLM calls (spec.md -> data-model.md -> http-api.md),
each building on the previous output. Caching is content-addressed.
"""

from __future__ import annotations

import hashlib
import json
import re
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable

from speceval.providers import Provider



@dataclass
class GeneratorConfig:
    """Configuration knobs for the SpecKit generator."""
    project_type: str = "web-api"
    tech_stack: str = ""
    target_fr_count: int = 10
    feature_name: str = ""
    feature_id: str = ""


@dataclass
class PassUsage:
    """Token consumption and timing for one LLM pass."""
    artefact: str
    input_tokens: int = 0
    output_tokens: int = 0
    elapsed_seconds: float = 0.0
    model: str = ""
    stop_reason: str = ""


@dataclass
class GenerationResult:
    """Everything produced by a single generate_speckit() call."""
    feature_id: str
    feature_dir: Path
    spec_md: str
    data_model_md: str
    http_api_md: str
    cache_hit: bool
    sha: str
    model: str
    config: GeneratorConfig
    usage: list[PassUsage] = field(default_factory=list)


class GenerationError(RuntimeError):
    """Raised when the generator fails (bad LLM output, validation, etc.)."""



_SPEC_SYSTEM_PROMPT = """\
You are a SpecKit specification author. Given a free-text project description \
and configuration, produce a **spec.md** file in the EXACT SpecKit template \
format shown below.

CONSTITUTION PRINCIPLE — Formal Specification & Business KPI Alignment:
Every feature specification must explicitly map formal constraints to business \
outcomes. Whenever describing a system state or invariant (conceptually mapping \
to an Alloy `sig` or `fact`), define how maintaining that state impacts a \
business metric. Whenever describing a state transition or action (conceptually \
mapping to an Alloy `pred`), define a measurable Business KPI (e.g., propensity \
scores, agent success rates) that tracks the success of this transition.

EXACT TEMPLATE — follow this structure precisely:

```
# Feature Specification: <Feature Name>

**Feature Branch**: `<feature-id>`
**Created**: <YYYY-MM-DD>
**Status**: Draft
**Input**: User description: "<original description>"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - <Brief Title> (Priority: P1)

<Describe this user journey in plain language>

**Why this priority**: <Explain the value and why it has this priority level>

**Independent Test**: <Describe how this can be tested independently>

**Acceptance Scenarios**:

1. **Given** <precondition>, **When** <action>, **Then** <expected outcome>
2. **Given** <precondition>, **When** <action>, **Then** <expected outcome>

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| <business metric> | <Alloy sig/fact/pred concept> | <how to measure> |

---

### User Story 2 - <Brief Title> (Priority: P2)
<...same structure...>

---

### Edge Cases

- What happens when <boundary condition>?
- How does system handle <error scenario>?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST <specific capability>
- **FR-002**: System MUST <specific capability>
<...number sequentially up to target count...>

### Key Entities

- **<Entity1>**: <What it represents, key attributes>
- **<Entity2>**: <What it represents, relationships>

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: <Measurable metric>
- **SC-002**: <Measurable metric>

## Assumptions

- <Assumption about target users>
- <Assumption about scope boundaries>

## Formal Requirements & Advanced KPI Mapping

| KPI Category | Specific Business Metric | Formal Constraint (Alloy Concept) | Measurement & Telemetry Strategy |
| :--- | :--- | :--- | :--- |
| **Success Rate** | <success rate KPI> | <Alloy pred pre/post conditions> | <how to log> |
| **Propensity Score** | <predictive score KPI> | <Alloy sig relational density> | <data pipeline> |
```

CRITICAL PARSER CONSTRAINTS — the downstream parser uses these exact regex \
anchors. If you deviate, the pipeline breaks:

1. First line MUST be: `# Feature Specification: <Name>`
2. Functional requirements MUST be: `- **FR-NNN**: System MUST ...`
3. User stories MUST be: `### User Story N - <Title> (Priority: PN)`
4. Acceptance scenarios MUST use: `**Given** ... **When** ... **Then** ...`
5. Separate user stories with `---` horizontal rules.
6. Each user story MUST have a `**Formal Requirements & KPI Mapping**:` table.

As you analyze the feature, identify the underlying formal logic (conceptually \
mapping to Alloy). Extract two specific types of metrics:
1. **Agent Success Rates**: Identify state transitions (Alloy `pred`) and define \
a KPI measuring the ratio of successful executions vs. failures/fallbacks.
2. **Propensity Scores**: Analyze structural relations (Alloy `sig` and `fact`) \
and define a predictive scoring metric based on entity state and relationships.

Return the complete spec.md content inside a single ```markdown ... ``` fence."""

_DATA_MODEL_SYSTEM_PROMPT = """\
You are a SpecKit data-model author. Given a project description and the \
previously generated spec.md, produce a **data-model.md** file in the EXACT \
SpecKit format shown below.

EXACT TEMPLATE — follow this structure precisely:

```
# Data Model: <Feature Name>

**Spec**: spec.md
**Created**: <YYYY-MM-DD>

## Entities

### <EntityName>

<Description paragraph>

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | UUID | Yes | Unique identifier |
| <field> | <type> | <Yes/No> | <description> |

**Validation Rules**:
- <rule about this entity>
- <rule about this entity>

---

### <NextEntity>
<...same structure...>

---

## Relationships

- **Entity1** 1:N **Entity2** (<description>)
- **Entity3** 1:N **Entity4** (<description>)

## Indexes

- `Entity.field` (<purpose>)
- `Entity.field` (<purpose>)
```

CRITICAL FORMAT RULES:

1. First line MUST be: `# Data Model: <Feature Name>`
2. Include metadata: `**Spec**: spec.md` and `**Created**: <date>`
3. Use `## Entities` as parent heading, then `### <EntityName>` for each entity
4. Field table columns MUST be: `Field | Type | Required | Description`
5. Type conventions: `UUID`, `string`, `string(email)`, `enum(a, b, c)`, \
`set(type)`, `datetime`, `integer`, `UUID (-> Entity.field)` for foreign keys
6. Each entity MUST have inline `**Validation Rules**:` (bold, with colon)
7. Separate entities with `---` horizontal rules
8. Include `## Relationships` with `1:N`, `N:M` notation
9. Include `## Indexes` listing indexed fields

Return the complete data-model.md content inside a single ```markdown ... ``` fence."""

_HTTP_API_SYSTEM_PROMPT = """\
You are a SpecKit HTTP API contract author. Given a project description, \
the previously generated spec.md, and data-model.md, produce a \
**contracts/http-api.md** file in the EXACT SpecKit format shown below.

EXACT TEMPLATE — follow this structure precisely:

```
# HTTP API Contract: <Feature Name>

**Spec**: ../spec.md
**Data Model**: ../data-model.md
**Created**: <YYYY-MM-DD>
**Base URL**: `/api/v1`

## Authentication

<Description of authentication requirement, referencing FR-NNN>

## Authorization Matrix

| Endpoint | <role1> | <role2> | <role3> |
|----------|---------|---------|---------|
| GET /resource | Allow (conditions) | Deny | Allow |
| POST /resource | Deny | Allow | Deny |

## Endpoints

### GET /resource

**Description**: <what it does>
**Implements**: FR-NNN, FR-MMM

**Request**:

| Parameter | Location | Type | Required | Description |
|-----------|----------|------|----------|-------------|
| Authorization | header | string (Bearer token) | Yes | Auth token |
| <param> | <query/path/body> | <type> | <Yes/No> | <description> |

**Response (200 OK)**:

```json
{
  "data": [...]
}
```

**Error Responses**:

| Status | Code | Description |
|--------|------|-------------|
| 401 | UNAUTHORIZED | Missing or invalid auth token |
| 403 | FORBIDDEN | Caller lacks required role |

---

### POST /resource
<...same structure...>
```

CRITICAL FORMAT RULES:

1. First line MUST be: `# HTTP API Contract: <Feature Name>`
2. Include metadata: `**Spec**:`, `**Data Model**:`, `**Created**:`, `**Base URL**:`
3. Include `## Authentication` section referencing the auth FR
4. Authorization matrix columns MUST be: `Endpoint | <role1> | <role2> | ...` \
(one column per role from the spec, NOT `Role | Endpoint | Methods`)
5. Use `## Endpoints` as parent heading, then `### <METHOD> /path` for each endpoint
6. Each endpoint MUST have: `**Description**:`, `**Implements**: FR-NNN`, \
`**Request**:` parameter table, `**Response (NNN Status)**:` with JSON example, \
`**Error Responses**:` table
7. Request parameter table columns: `Parameter | Location | Type | Required | Description`
8. Error table columns: `Status | Code | Description`
9. Separate endpoints with `---` horizontal rules

Return the complete http-api.md content inside a single ```markdown ... ``` fence."""



def generate_speckit(
    description: str,
    *,
    config: GeneratorConfig | None = None,
    provider: Provider,
    output_base: Path,
    cache_dir: Path,
    use_cache: bool = True,
    echo: Callable[[str], Any] | None = None,
) -> GenerationResult:
    """Generate SpecKit artefacts from a free-text description.

    Raises GenerationError on LLM output that doesn't pass validation.
    """
    if echo is None:
        def echo(_msg, *args, **kwargs):  # noqa: ARG001
            return None

    cfg = config or GeneratorConfig()
    sha = _generation_sha(description, cfg, provider.model)
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_path = cache_dir / f"{sha}.json"

    # --- Determine feature ID ---
    feature_id = cfg.feature_id or _derive_feature_id(description, output_base)
    feature_dir = output_base / feature_id

    # --- Check cache ---
    if use_cache and cache_path.exists():
        echo(f"[gen]     cache hit (sha={sha[:12]})")
        cached = json.loads(cache_path.read_text(encoding="utf-8"))
        spec_md = cached["spec_md"]
        data_model_md = cached["data_model_md"]
        http_api_md = cached["http_api_md"]
        cached_feature_id = cached.get("feature_id", feature_id)
        cached_feature_dir = output_base / cached_feature_id
        _write_artefacts(cached_feature_dir, spec_md, data_model_md, http_api_md)
        echo(f"[gen]     wrote artefacts to {cached_feature_dir}")
        return GenerationResult(
            feature_id=cached_feature_id,
            feature_dir=cached_feature_dir,
            spec_md=spec_md,
            data_model_md=data_model_md,
            http_api_md=http_api_md,
            cache_hit=True,
            sha=sha,
            model=cached.get("model", provider.model),
            config=cfg,
        )

    # Ensure output dirs exist before any LLM calls so we can write
    # each artefact immediately after it's produced.
    feature_dir.mkdir(parents=True, exist_ok=True)
    contracts_dir = feature_dir / "contracts"
    contracts_dir.mkdir(parents=True, exist_ok=True)

    usage_log: list[PassUsage] = []

    # --- Pass 1: spec.md ---
    echo("[gen]     pass 1/3 — generating spec.md...")
    spec_user_prompt = _build_spec_prompt(description, cfg, feature_id)
    t0 = time.monotonic()
    spec_cr = provider.complete_with_usage(
        system=_SPEC_SYSTEM_PROMPT,
        user=spec_user_prompt,
        max_tokens=8192,
    )
    elapsed = time.monotonic() - t0
    spec_md = _extract_markdown(spec_cr.text, "spec.md")
    _validate_spec_md(spec_md)
    (feature_dir / "spec.md").write_text(spec_md, encoding="utf-8")
    p1 = PassUsage(
        artefact="spec.md",
        input_tokens=spec_cr.input_tokens,
        output_tokens=spec_cr.output_tokens,
        elapsed_seconds=round(elapsed, 1),
        model=spec_cr.model,
        stop_reason=spec_cr.stop_reason,
    )
    usage_log.append(p1)
    echo(
        f"[gen]     spec.md validated — {p1.input_tokens}in/"
        f"{p1.output_tokens}out tokens, {p1.elapsed_seconds}s"
    )

    # --- Pass 2: data-model.md ---
    echo("[gen]     pass 2/3 — generating data-model.md...")
    dm_user_prompt = _build_data_model_prompt(description, cfg, spec_md)
    t0 = time.monotonic()
    dm_cr = provider.complete_with_usage(
        system=_DATA_MODEL_SYSTEM_PROMPT,
        user=dm_user_prompt,
        max_tokens=8192,
    )
    elapsed = time.monotonic() - t0
    data_model_md = _extract_markdown(dm_cr.text, "data-model.md")
    _validate_data_model_md(data_model_md)
    (feature_dir / "data-model.md").write_text(data_model_md, encoding="utf-8")
    p2 = PassUsage(
        artefact="data-model.md",
        input_tokens=dm_cr.input_tokens,
        output_tokens=dm_cr.output_tokens,
        elapsed_seconds=round(elapsed, 1),
        model=dm_cr.model,
        stop_reason=dm_cr.stop_reason,
    )
    usage_log.append(p2)
    echo(
        f"[gen]     data-model.md validated — {p2.input_tokens}in/"
        f"{p2.output_tokens}out tokens, {p2.elapsed_seconds}s"
    )

    # --- Pass 3: contracts/http-api.md ---
    echo("[gen]     pass 3/3 — generating contracts/http-api.md...")
    api_user_prompt = _build_http_api_prompt(description, cfg, spec_md, data_model_md)
    t0 = time.monotonic()
    api_cr = provider.complete_with_usage(
        system=_HTTP_API_SYSTEM_PROMPT,
        user=api_user_prompt,
        max_tokens=8192,
    )
    elapsed = time.monotonic() - t0
    http_api_md = _extract_markdown(api_cr.text, "http-api.md")
    _validate_http_api_md(http_api_md)
    (contracts_dir / "http-api.md").write_text(http_api_md, encoding="utf-8")
    p3 = PassUsage(
        artefact="http-api.md",
        input_tokens=api_cr.input_tokens,
        output_tokens=api_cr.output_tokens,
        elapsed_seconds=round(elapsed, 1),
        model=api_cr.model,
        stop_reason=api_cr.stop_reason,
    )
    usage_log.append(p3)
    echo(
        f"[gen]     http-api.md validated — {p3.input_tokens}in/"
        f"{p3.output_tokens}out tokens, {p3.elapsed_seconds}s"
    )

    # --- Usage summary ---
    total_in = sum(p.input_tokens for p in usage_log)
    total_out = sum(p.output_tokens for p in usage_log)
    total_time = sum(p.elapsed_seconds for p in usage_log)
    echo(
        f"[gen]     total: {total_in}in/{total_out}out tokens "
        f"({total_in + total_out} total), {total_time:.1f}s"
    )

    # --- Cache ---
    cache_payload = {
        "spec_md": spec_md,
        "data_model_md": data_model_md,
        "http_api_md": http_api_md,
        "model": provider.model,
        "sha": sha,
        "feature_id": feature_id,
        "config": asdict(cfg),
        "description": description,
        "usage": [asdict(p) for p in usage_log],
    }
    cache_path.write_text(json.dumps(cache_payload, indent=2), encoding="utf-8")

    return GenerationResult(
        feature_id=feature_id,
        feature_dir=feature_dir,
        spec_md=spec_md,
        data_model_md=data_model_md,
        http_api_md=http_api_md,
        cache_hit=False,
        sha=sha,
        model=provider.model,
        config=cfg,
        usage=usage_log,
    )


from pathlib import Path
from speceval.speckit_generator import generate_speckit, GeneratorConfig
from speceval.providers.anthropic import AnthropicProvider
from speceval.kpi_extractor import extract_all_kpis, save_kpis_json


def generate_with_kpis(
    description: str,
    feature_id: str,
    specs_dir: Path,
    cache_dir: Path,
    provider: AnthropicProvider,
):
    """Generate SpecKit artefacts + extract KPIs to JSON."""
    
    # Step 1: Generate SpecKit artefacts (spec.md, data-model.md, http-api.md)
    print(f"[gen]     generating SpecKit for {feature_id}...")
    result = generate_speckit(
        description=description,
        config=GeneratorConfig(
            feature_id=feature_id,
            project_type="web-api",
            target_fr_count=10,
        ),
        provider=provider,
        output_base=specs_dir,
        cache_dir=cache_dir,
        use_cache=True,
    )
    
    # Step 2: Extract KPIs from both spec.md and user prompt
    print(f"[kpi]     extracting KPIs...")
    kpi_collection = extract_all_kpis(
        feature_id=result.feature_id,
        spec_md=result.spec_md,
        user_prompt=description,
        feature_name=result.feature_id.replace("-", " ").title(),
    )
    
    # Step 3: Save KPIs to JSON
    kpi_output = result.feature_dir / "kpis.json"
    save_kpis_json(kpi_collection, kpi_output)
    
    print(f"[kpi]     saved {len(kpi_collection.merged_kpis)} KPIs → {kpi_output}")
    print(f"[kpi]     - {len(kpi_collection.speckit_kpis)} from spec.md")
    print(f"[kpi]     - {len(kpi_collection.user_prompt_kpis)} from user prompt")
    
    return result, kpi_collection

def _build_spec_prompt(
    description: str, cfg: GeneratorConfig, feature_id: str
) -> str:
    from datetime import date
    today = date.today().isoformat()
    parts = [f"## User Description\n\n{description.strip()}"]
    parts.append(f"\n## Generation Parameters\n")
    parts.append(f"- Feature branch / ID: `{feature_id}`")
    parts.append(f"- Date: {today}")
    parts.append(f"- Project type: {cfg.project_type}")
    if cfg.tech_stack:
        parts.append(f"- Tech stack: {cfg.tech_stack}")
    parts.append(f"- Target number of functional requirements: {cfg.target_fr_count}")
    if cfg.feature_name:
        parts.append(f"- Feature name to use in heading: {cfg.feature_name}")
    parts.append(
        "\nGenerate a complete spec.md following the EXACT SpecKit template "
        "format from the system prompt. Fill in the metadata header with the "
        "feature branch, date, and user description above. Include ALL "
        "mandatory sections: User Scenarios & Testing, Requirements, Success "
        "Criteria, Assumptions, and the Formal Requirements & Advanced KPI "
        "Mapping table. Each user story must have a Formal Requirements & "
        "KPI Mapping table."
    )
    return "\n".join(parts)


def _build_data_model_prompt(
    description: str, cfg: GeneratorConfig, spec_md: str
) -> str:
    from datetime import date
    today = date.today().isoformat()
    parts = [f"## User Description\n\n{description.strip()}"]
    parts.append(f"\n## Generation Parameters\n")
    parts.append(f"- Date: {today}")
    parts.append(f"- Project type: {cfg.project_type}")
    if cfg.tech_stack:
        parts.append(f"- Tech stack: {cfg.tech_stack}")
    parts.append(f"\n## Previously Generated spec.md\n\n{spec_md}")
    parts.append(
        "\nGenerate a complete data-model.md following the EXACT SpecKit "
        "format from the system prompt. Cover all entities referenced in "
        "the Key Entities section and implied by the functional requirements. "
        "Include the Entities parent heading, per-entity field tables with "
        "validation rules, Relationships section, and Indexes section."
    )
    return "\n".join(parts)


def _build_http_api_prompt(
    description: str,
    cfg: GeneratorConfig,
    spec_md: str,
    data_model_md: str,
) -> str:
    from datetime import date
    today = date.today().isoformat()
    parts = [f"## User Description\n\n{description.strip()}"]
    parts.append(f"\n## Generation Parameters\n")
    parts.append(f"- Date: {today}")
    parts.append(f"- Project type: {cfg.project_type}")
    if cfg.tech_stack:
        parts.append(f"- Tech stack: {cfg.tech_stack}")
    parts.append(f"\n## Previously Generated spec.md\n\n{spec_md}")
    parts.append(f"\n## Previously Generated data-model.md\n\n{data_model_md}")
    parts.append(
        "\nGenerate a complete contracts/http-api.md following the EXACT "
        "SpecKit format from the system prompt. Include the metadata header, "
        "Authentication section, Authorization Matrix with one column per "
        "role from the spec, Endpoints parent heading, and per-endpoint "
        "sections with Description, Implements, Request table, Response "
        "JSON examples, and Error Responses table. Reference FR-NNN IDs "
        "from the spec in each endpoint's Implements line."
    )
    return "\n".join(parts)



_RE_MARKDOWN_FENCE = re.compile(
    r"```(?:markdown|md)?\s*\n(?P<body>.*?)\n```",
    re.DOTALL,
)


def _extract_markdown(raw: str, label: str) -> str:
    """Pull the markdown content out of a fenced code block."""
    m = _RE_MARKDOWN_FENCE.search(raw)
    if m:
        return m.group("body").strip()
    # Fallback: if the LLM didn't wrap in a fence, use the raw text
    # after stripping any leading/trailing explanation lines.
    stripped = raw.strip()
    if stripped.startswith("#"):
        return stripped
    raise GenerationError(
        f"LLM response for {label} contained no markdown fence and "
        f"doesn't start with a heading. Raw start: {raw[:300]!r}"
    )


def _validate_spec_md(text: str) -> None:
    """Validate that spec.md matches the SpecKit template format.

    Checks both the parser.py regex anchors (Feature Specification heading,
    FR-NNN, User Story headings, Given/When/Then) and the SpecKit-specific
    sections (Requirements *(mandatory)*, Success Criteria, KPI mapping).
    """
    errors: list[str] = []

    # --- Parser-critical anchors (pipeline breaks without these) ---
    if not re.search(
        r"^#\s*Feature Specification:\s*.+$", text, re.MULTILINE
    ):
        errors.append(
            "Missing '# Feature Specification: <Name>' heading"
        )

    fr_matches = re.findall(
        r"^\s*-\s*\*\*FR-\d+\*\*:", text, re.MULTILINE
    )
    if not fr_matches:
        errors.append("No '- **FR-NNN**:' functional requirements found")

    if not re.search(
        r"^###\s*User\s+Story\s+\d+\s*-\s*.+\(Priority:\s*P\d+\)",
        text,
        re.MULTILINE,
    ):
        errors.append(
            "No '### User Story N - <Title> (Priority: PN)' headings found"
        )

    if not re.search(r"\*\*Given\*\*", text):
        errors.append("No '**Given**' markers found in acceptance scenarios")

    if not re.search(r"\*\*When\*\*", text):
        errors.append("No '**When**' markers found in acceptance scenarios")

    if not re.search(r"\*\*Then\*\*", text):
        errors.append("No '**Then**' markers found in acceptance scenarios")

    # --- SpecKit template sections ---
    if not re.search(
        r"^##\s+User Scenarios & Testing", text, re.MULTILINE
    ):
        errors.append(
            "Missing '## User Scenarios & Testing *(mandatory)*' section"
        )

    if not re.search(
        r"^##\s+Requirements", text, re.MULTILINE
    ):
        errors.append("Missing '## Requirements *(mandatory)*' section")

    if not re.search(
        r"^##\s+Success Criteria", text, re.MULTILINE
    ):
        errors.append("Missing '## Success Criteria *(mandatory)*' section")

    if not re.search(r"\*\*SC-\d+\*\*:", text):
        errors.append("No '**SC-NNN**:' success criteria found")

    if errors:
        raise GenerationError(
            "spec.md validation failed:\n  - " + "\n  - ".join(errors)
        )


def _validate_data_model_md(text: str) -> None:
    """Validate data-model.md matches the SpecKit data-model format."""
    errors: list[str] = []

    if not re.search(r"^#\s*Data Model:", text, re.MULTILINE):
        errors.append("Missing '# Data Model:' heading")

    if not re.search(r"^###?\s+\w+", text, re.MULTILINE):
        errors.append("No entity sections (## or ### headings) found")

    # Field table — must have Required column (not Constraints)
    if not re.search(r"Field\s*\|.*Type\s*\|.*Required", text):
        # Accept either Required or Constraints as the column name
        if not re.search(r"Field\s*\|.*Type\s*\|", text):
            errors.append(
                "No field tables found (expected: Field | Type | Required | Description)"
            )

    if not re.search(r"##\s+Relationships", text, re.MULTILINE):
        errors.append("Missing '## Relationships' section")

    if errors:
        raise GenerationError(
            "data-model.md validation failed:\n  - " + "\n  - ".join(errors)
        )


def _validate_http_api_md(text: str) -> None:
    """Validate http-api.md matches the SpecKit HTTP API contract format."""
    errors: list[str] = []

    if not re.search(r"^#\s*HTTP API Contract:", text, re.MULTILINE):
        if not re.search(r"^#\s+.+API", text, re.MULTILINE | re.IGNORECASE):
            errors.append("Missing '# HTTP API Contract:' heading")

    if not re.search(r"##\s+Authorization Matrix", text, re.MULTILINE):
        # Fallback: any authorization reference
        if not re.search(r"[Aa]uthoriz", text):
            errors.append("No Authorization Matrix section found")

    if not re.search(r"##\s+Authentication", text, re.MULTILINE):
        errors.append("Missing '## Authentication' section")

    # Check for endpoint sections with Implements references
    if not re.search(r"###\s+(GET|POST|PUT|DELETE|PATCH)\s+/", text, re.MULTILINE):
        errors.append(
            "No endpoint sections found (expected: ### GET /path)"
        )

    if errors:
        raise GenerationError(
            "http-api.md validation failed:\n  - " + "\n  - ".join(errors)
        )



def _slugify(text: str) -> str:
    """Convert text to a URL-friendly slug."""
    slug = text.lower().strip()
    slug = re.sub(r"[^a-z0-9\s-]", "", slug)
    slug = re.sub(r"[\s_]+", "-", slug)
    slug = re.sub(r"-+", "-", slug)
    return slug.strip("-")[:50]


def _derive_feature_id(description: str, output_base: Path) -> str:
    """Auto-number by scanning existing directories, then slugify."""
    output_base.mkdir(parents=True, exist_ok=True)
    existing = sorted(output_base.iterdir()) if output_base.is_dir() else []
    max_num = 0
    for d in existing:
        if d.is_dir():
            m = re.match(r"^(\d+)-", d.name)
            if m:
                max_num = max(max_num, int(m.group(1)))
    next_num = max_num + 1
    slug = _slugify(description.split(".")[0][:60])
    if not slug:
        slug = "feature"
    return f"{next_num:03d}-{slug}"



def _write_artefacts(
    feature_dir: Path,
    spec_md: str,
    data_model_md: str,
    http_api_md: str,
) -> None:
    """Write the three SpecKit artefacts to the feature directory."""
    feature_dir.mkdir(parents=True, exist_ok=True)
    (feature_dir / "spec.md").write_text(spec_md, encoding="utf-8")
    (feature_dir / "data-model.md").write_text(data_model_md, encoding="utf-8")
    contracts_dir = feature_dir / "contracts"
    contracts_dir.mkdir(parents=True, exist_ok=True)
    (contracts_dir / "http-api.md").write_text(http_api_md, encoding="utf-8")



def _generation_sha(
    description: str,
    config: GeneratorConfig,
    model: str,
) -> str:
    """SHA-256 over description + config + model + system prompts.

    Includes all three system prompts so a prompt change invalidates cache.
    """
    h = hashlib.sha256()
    h.update(("model=" + model + "\n").encode("utf-8"))
    h.update(b"description=")
    h.update(description.encode("utf-8"))
    h.update(b"\nconfig=")
    h.update(json.dumps(asdict(config), sort_keys=True).encode("utf-8"))
    h.update(b"\nsystem_prompt_spec=")
    h.update(_SPEC_SYSTEM_PROMPT.encode("utf-8"))
    h.update(b"\nsystem_prompt_dm=")
    h.update(_DATA_MODEL_SYSTEM_PROMPT.encode("utf-8"))
    h.update(b"\nsystem_prompt_api=")
    h.update(_HTTP_API_SYSTEM_PROMPT.encode("utf-8"))
    return h.hexdigest()
