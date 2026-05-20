# Specification Quality Checklist: Clinician Access to Patient Medical Records (v1, narrow scope)

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-05-17
**Updated**: 2026-05-17 (after user accepted recommended defaults `Q1: A, Q2: A, Q3: A`)
**Feature**: [spec.md](../spec.md)

## ⚠ Governance Status — REVIEW STILL PENDING

The three clarifications are resolved (`Q1: A, Q2: A, Q3: A` — UK NHS, read-only, care-team membership). However, the **governance review block remains open**:

- [ ] **Product owner** sign-off on the deliberately narrow v1 scope.
- [ ] **Clinical-safety officer** sign-off on a DCB0129/0160 case that explicitly addresses the "care-team-only, no break-glass" safety implication (will fail-deny in genuine emergency-access scenarios — operational fallback must be confirmed sufficient).
- [ ] **Legal / privacy / IG** sign-off:
  - Article 9(2)(h) GDPR lawful-basis confirmation.
  - Caldicott-guardian sign-off.
  - Retention floor confirmation (8 yrs adult / until 25th birthday paediatric).
  - Audit-log surface confirmation (IG-readable; downstream patient-facing endpoint enabled by the audit data model).

**Do not invoke `/speckit-plan` until at minimum the clinical-safety review has happened.** The plan would otherwise bake in a design (care-team-only fail-deny, no break-glass) that the safety case may reject.

If the clinical-safety case rejects the no-break-glass model, **revisit Q3 and re-spec** — do not work around it during planning or implementation.

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Notes

- **Clarifications resolved** (user reply: "use the recommended defaults" → `Q1: A, Q2: A, Q3: A`):
  - **Q1 = A** (UK NHS) — Caldicott, DSPT, GDPR + DPA 2018, DCB0129/0160, NHS records retention. Article 9(2)(h) GDPR lawful basis. 8-year audit retention (until 25th birthday paediatric). Patient-rights audit visibility is enabled by the data model but the patient-facing endpoint is a separate downstream feature.
  - **Q2 = A** (read-only) — US2 (write user story from the parameterised draft) was **dropped entirely**. v1 has no amend / prescribe / note-write surface. A future feature with its own clinical-safety case may introduce writes.
  - **Q3 = A** (care-team membership) — No break-glass path in v1. The fail-deny safety implication is explicit and the clinical-safety case must validate the operational fallback.
- The introductory pre-flight notice was replaced with a shorter "v1 scope and governance notice" that captures the choices made and the review still required.
- The break-glass edge case was rewritten from "in scope only if Q3 = D" to an explicit "out of scope for v1" with a pointer to the operational fallback.
- FR-009 was simplified to remove the break-glass `justification` field (Q3 = A has no break-glass).
- FR-011 was scoped to IG-only; the patient-facing "view who accessed my record" endpoint was moved to Out of Scope with a cross-reference noting that this feature's audit data model must enable it.
- All 12 standard checklist items now pass. The governance-review block at the top of this file is unchecked and **must be addressed before planning**.
