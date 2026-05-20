# Verification Pattern Catalogue

Curated checklist of structural correctness patterns for `spec-led-eval`'s
LLM-driven Alloy lifter. Plain English, not Alloy. The lifter passes this file
to the LLM along with the Speckit artefacts and asks: for each pattern that
applies to the feature, generate an Alloy predicate; then add any
feature-specific predicates that don't fit a pattern.

This file is the human-curated "menu of good ideas." It is not an Alloy
library. The actual Alloy is generated per-feature.

## How to use this file

Each pattern has:

- **name** — used as the Alloy predicate name (e.g., `pred LeastPrivilege { ... }`).
- **applies_to** — when the LLM should instantiate it (decided per-feature
  by reading the Speckit artefacts).
- **description** — what the pattern asserts.
- **anchor_to** — what to cite in the Alloy comment when generating the
  predicate so a human reviewer can trace it back to the spec.

## Patterns

### LeastPrivilege

- **applies_to**: features whose `contracts/` defines a per-role/per-endpoint
  authorisation matrix.
- **description**: For every (Role, Operation) cell where the matrix says
  "denied," no caller with that role can reach the operation. Conversely,
  every "allow" cell traces back to at least one functional requirement.
- **anchor_to**: contracts/http-api.md authorisation tables; the FR-NNN that
  grants each permission.

### PermissionCompleteness

- **applies_to**: features with a defined permission matrix.
- **description**: Every (Role × Operation) cell in the permission matrix has
  a defined verdict — allow, deny, or conditional. No undefined cells.
- **anchor_to**: contracts/ permission tables.

### PermissionGrounding

- **applies_to**: features with a permission matrix.
- **description**: Every "allow" entry in the permission matrix traces back
  to at least one explicit `FR-NNN` in `spec.md`. No silent grants.
- **anchor_to**: spec.md FRs, contracts/ permission tables.

### PrivilegeMonotonicity

- **applies_to**: features with a strict role hierarchy where higher roles
  are documented as supersets of lower ones (e.g., admin > auditor in
  read-side permissions).
- **description**: For any pair of roles where the spec implies a hierarchy,
  the higher role's permitted action set is a superset of the lower role's
  (in the dimensions the hierarchy applies to). Catches "admin can't do X
  but the user can" bugs.
- **anchor_to**: spec.md role descriptions, contracts/ permission tables.

### AuthRequiredEverywhere

- **applies_to**: features where the spec mandates authentication on every
  endpoint.
- **description**: Every Operation in the system rejects unauthenticated
  callers before any business logic runs. No path bypasses authentication.
- **anchor_to**: spec.md FR(s) on authentication; contracts/ auth section.

### AuditCompleteness

- **applies_to**: features that produce audit/journal entries for some class
  of operations.
- **description**: Every operation that the spec marks as audit-relevant
  produces exactly one audit entry, linked one-to-one to the operation it
  records. No duplicates, no missing entries.
- **anchor_to**: data-model.md UNIQUE constraints; spec.md FRs on auditing.

### AppendOnly

- **applies_to**: features with append-only artefacts (audit logs, event
  journals, transaction histories).
- **description**: For any artefact the spec marks append-only, no operation
  in the system mutates or deletes an existing entry through any role,
  including admin.
- **anchor_to**: spec.md FRs on append-only; data-model.md "no UPDATE/DELETE"
  notes; contracts/ "no PATCH/PUT/DELETE" notes.

### AttributionCorrectness

- **applies_to**: features where audit/journal entries record an initiator.
- **description**: Every audit entry's recorded initiator and recorded role
  match the actual initiator and role of the operation it records. No
  misattribution.
- **anchor_to**: data-model.md audit-entry fields; spec.md FRs on
  audit-record contents.

### OwnershipExclusivity

- **applies_to**: features with the concept of resource ownership
  (e.g., "each Account is owned by exactly one User").
- **description**: Every owned resource has exactly one owner principal.
  No orphans, no co-ownership unless the spec explicitly allows it.
- **anchor_to**: data-model.md ownership relations.

### OwnershipBasedAccess

- **applies_to**: features where a role's permission depends on resource
  ownership (e.g., "account_holder can read transfers involving accounts
  they own").
- **description**: For every "ownership-conditional" allow in the permission
  matrix, the access check resolves correctly through the ownership relation.
  A caller's access to a resource follows from a documented chain
  caller → owns → resource.
- **anchor_to**: spec.md FRs that define ownership-conditional permissions;
  data-model.md ownership relations.

### NoInformationLeakage

- **applies_to**: features where access denial responses must not reveal
  the existence of restricted resources.
- **description**: Where access is denied, the system's externally visible
  response shape (status code + body) does not distinguish "exists but
  caller can't see it" from "does not exist." The two are byte-identical
  to an outside observer.
- **anchor_to**: spec.md FRs on no-leakage; contracts/ status code rules.

### ConservationOfValue

- **applies_to**: features that move value/state between buckets
  (transfers, allocations, etc.).
- **description**: For every successful value-moving operation, the sum of
  the affected quantities before equals the sum after. No value created
  or destroyed mid-operation.
- **anchor_to**: spec.md FRs on transfer atomicity; data-model.md balance
  constraints.

### NoSelfMutation

- **applies_to**: features where a value-moving operation must have distinct
  source and destination (e.g., transfers).
- **description**: For every such operation, source ≠ destination. Enforced
  structurally, not just at the API layer.
- **anchor_to**: spec.md FRs on source/destination distinctness;
  data-model.md CHECK constraints.

### ValidationBeforeMutation

- **applies_to**: features where invalid requests must produce no
  side-effects.
- **description**: For every operation, a request that fails validation
  produces no row in any state-changing table — no transaction record, no
  audit entry, no balance change. Validation rejection is a no-op on state.
- **anchor_to**: spec.md FRs on validation; data-model.md atomicity contract.

### ConcurrencySafety

- **applies_to**: features that explicitly mention concurrent operation
  safety in their FRs.
- **description**: For any operation the spec marks as concurrency-safe,
  concurrent invocations cannot jointly produce a state that any single
  invocation would have rejected (e.g., negative balance, missing audit
  entry, duplicate audit entry).
- **anchor_to**: spec.md FRs on concurrency; data-model.md atomicity
  contract.

## Notes for the lifter

- The LLM decides which patterns apply by reading the Speckit artefacts.
  Not every pattern fits every feature.
- Every generated Alloy predicate carries an inline comment of the form
  `// PATTERN: <name>  ANCHOR: <spec citation>` so a human reviewer can
  validate the translation in seconds.
- Beyond the catalogue, the LLM is encouraged to add feature-specific
  predicates for invariants the catalogue doesn't cover. Each feature-
  specific predicate gets `// FEATURE-SPECIFIC  ANCHOR: <FR-NNN or text>`.
- Every FR-NNN in `spec.md` should be covered by at least one assertion,
  whether from a pattern or feature-specific. The lifter checks coverage
  and warns if any FR has no assertion.
