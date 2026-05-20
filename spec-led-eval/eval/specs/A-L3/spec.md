# Feature Specification: FCA-Regulated Loan Application

**Feature Branch**: `005-fca-loan-applications`
**Created**: 2026-05-17
**Status**: Draft
**Input**: User description: "Build a loan application feature for a retail bank under FCA consumer credit regulation. Authenticated customers (role: applicant) can submit loan applications for amounts between £1,000 and £25,000 with a stated purpose drawn from a fixed list of categories. Each application is automatically assigned to one loan officer (role: officer) on submission. Only the assigned officer can change an application's status (pending → under_review → approved | rejected); applicants cannot modify an application after submission, and officers cannot self-approve their own applications. Compliance reviewers (role: auditor) have read-only access to any application and its full decision history but must not be able to modify any record. Every state transition must be written to an immutable audit log within 2 seconds of occurrence, capturing application_id, actor_id, actor_role, timestamp (UTC ISO 8601), previous_status, new_status, and a reason field. Audit log entries cannot be updated or deleted; logs must be retained for at least 6 years to satisfy FCA SYSC record-keeping rules. All API endpoints must require OAuth 2.0 bearer authentication; unauthenticated requests must be rejected with HTTP 401 before any business logic runs. The system must enforce that the response to GET /applications/{id} for two applications belonging to different applicants is byte-equivalent to outsiders, preventing information leakage about other customers' applications. Available endpoints: POST /applications, GET /applications/{id}, PATCH /applications/{id}/status, GET /applications/{id}/audit."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Applicant Submits a Loan Application (Priority: P1)

An authenticated retail-banking customer (role: **applicant**) wants to borrow a personal loan. They open the application form, enter the amount they want to borrow (between £1,000 and £25,000) and pick a purpose from a fixed list (home improvement, debt consolidation, vehicle, education, medical, wedding, holiday, business, other). They submit. The system records the application at status `pending`, automatically assigns one available loan officer to it, and writes the first audit entry — `(none) → pending` — within 2 seconds of submission. The applicant receives an application identifier they can quote later.

**Why this priority**: Without this story, no applications enter the system; it is the indispensable first slice and the trigger for the rest of the workflow (auto-assignment, audit log).

**Independent Test**: A test applicant with a valid OAuth bearer token can `POST /applications` with a valid amount and a purpose from the allowed list and receive a `201 Created` response containing the new application identifier. Inspecting the system shows: the application at status `pending`, an `assigned_officer_id` set, and exactly one audit entry with `previous_status = (none)` and `new_status = pending`, all within 2 seconds of submission.

**Acceptance Scenarios**:

1. **Given** an authenticated applicant, **When** they `POST /applications` with `amount_minor` ∈ [100000, 2500000] and `purpose` ∈ {fixed category list}, **Then** the system creates the application at status `pending`, assigns one officer (different from the applicant, see US2 acceptance #4), writes one audit entry within 2 s capturing `application_id`, `actor_id` (the applicant), `actor_role` (`applicant`), `timestamp` (UTC ISO 8601), `previous_status` (null), `new_status` (`pending`), and a reason (`"Application submitted"`), and returns `201 Created` with the application identifier.
2. **Given** an authenticated applicant, **When** they `POST /applications` with `amount_minor` outside [100000, 2500000], a `purpose` not in the fixed list, or a missing field, **Then** the system returns `400` with a field-level error envelope, **does not** create an application, and **does not** write any audit entry.
3. **Given** an applicant who already has an application at status `pending` or `under_review`, **When** they submit another, **Then** the system returns `409 has_in_flight_application` naming the existing application's identifier and status, **does not** create a second application, and **does not** write any audit entry.
4. **Given** an unauthenticated request (no `Authorization: Bearer …` header, or invalid token), **When** the system receives `POST /applications`, **Then** the system returns `401 unauthenticated` **before any business logic runs**, including before request body parsing has any effect on application state, and **does not** write any audit entry.

---

### User Story 2 - Officer Reviews and Decides an Assigned Application (Priority: P1)

An authenticated bank employee (role: **officer**) signs in. They see the applications assigned to them. They open one, switch it from `pending` to `under_review` (recording why they are starting review), examine the applicant's submission, and finally transition it to `approved` or `rejected` with a non-empty reason. Each transition is written to the audit log within 2 seconds. An officer cannot decide an application that lists them as the applicant: the system prevents self-approval/self-rejection.

**Why this priority**: The feature only delivers value if assigned applications can actually be decided, and the no-self-approval rule is the conflict-of-interest control the FCA framing requires. Both are MVP-indispensable.

**Independent Test**: With at least one application assigned to a test officer, that officer can `PATCH /applications/{id}/status` with `{"status":"under_review","reason":"…"}` and receive `200 OK`; the application's status transitions, a new audit entry is appended within 2 s with `previous_status="pending"`, `new_status="under_review"`, `actor_role="officer"`. They can then `PATCH` again with `{"status":"approved","reason":"…"}` (or `"rejected"`) and the application reaches the terminal state with a second audit entry. A different officer attempting the same `PATCH` is refused; an officer attempting to `PATCH` an application where they are the applicant is refused; an applicant attempting any `PATCH` is refused.

**Acceptance Scenarios**:

1. **Given** an application at status `pending` assigned to officer A, **When** officer A `PATCH /applications/{id}/status` with `{"status":"under_review","reason":"Picked up for review"}`, **Then** the system transitions the application to `under_review`, writes one audit entry within 2 s (`previous_status="pending"`, `new_status="under_review"`, `actor_id=A`, `actor_role="officer"`, `reason="Picked up for review"`), and returns `200 OK`.
2. **Given** an application at status `under_review` assigned to officer A, **When** officer A `PATCH` with `{"status":"approved","reason":"Income covers requested amount"}` (or `rejected`), **Then** the system transitions to the terminal status, writes one audit entry within 2 s, and returns `200 OK`.
3. **Given** an application at status `pending` or `under_review` assigned to officer A, **When** officer B (a different officer) `PATCH`es it, **Then** the system returns `403 not_assigned_officer`, the application's state is unchanged, and **no** audit entry is written.
4. **Given** an application submitted by user U (who happens to hold the `officer` role on a separate workflow login), **When** the auto-assignment algorithm runs on submission, **Then** the assigned officer MUST be a user other than U; if no other officer is available, the application enters status `pending` with `assigned_officer_id = null` and the system records a system-actor audit entry indicating "no eligible officer" (see Edge Cases).
5. **Given** an application at status `under_review` assigned to officer A, **When** officer A `PATCH`es it with `{"status":"approved","reason":"…"}` **and** A is also the applicant on that application, **Then** the system returns `403 self_decision_forbidden`, the application's state is unchanged, and **no** audit entry is written.
6. **Given** any `PATCH` request, **When** the `reason` field is missing or empty, **Then** the system returns `400 validation_error` listing `reason`, the application's state is unchanged, and **no** audit entry is written.
7. **Given** an application at status `approved` or `rejected`, **When** any officer (including the assigned one) `PATCH`es its status, **Then** the system returns `409 already_decided`, the application's state is unchanged, and **no** audit entry is written.
8. **Given** any `PATCH` attempting a transition that is not in the allowed set ({`pending` → `under_review`, `under_review` → `approved`, `under_review` → `rejected`}), **When** received, **Then** the system returns `409 invalid_transition`, the application's state is unchanged, and **no** audit entry is written.

---

### User Story 3 - Auditor (Compliance) Inspects an Application and Its Full Audit Trail (Priority: P1)

An authenticated compliance reviewer (role: **auditor**) needs to inspect an application — its current data, current status, and full decision history — for a regulatory review under FCA SYSC. They can `GET` any application and `GET` its full audit log. Every attempt to modify any record (`POST` a new application, `PATCH` a status, or any operation that would alter audit entries) is refused.

**Why this priority**: The 6-year retention and audit-inspection right is the regulatory raison-d'être of this feature; without an enforceable read-only auditor role, the audit log exists but cannot be officially relied on for compliance.

**Independent Test**: A test auditor user with a valid token can `GET /applications/{id}` for any application in the system and receive the full record (applicant, amount, purpose, status, assigned officer, decision reason where applicable). They can `GET /applications/{id}/audit` and receive every transition in chronological order with all required fields. Every write attempt (`POST /applications`, `PATCH /applications/{id}/status`) is refused with `403`, and **no** audit entry is written for the refused attempt.

**Acceptance Scenarios**:

1. **Given** an authenticated auditor, **When** they `GET /applications/{id}` for any application, **Then** the system returns `200 OK` with the application's full record including the applicant identifier, the assigned officer identifier, the current status, the submission timestamp, and (if decided) the decision and reason.
2. **Given** an authenticated auditor, **When** they `GET /applications/{id}/audit`, **Then** the system returns `200 OK` with every audit entry for the application in chronological order, each entry containing `application_id`, `actor_id`, `actor_role`, `timestamp` (UTC ISO 8601), `previous_status`, `new_status`, and `reason`.
3. **Given** an authenticated auditor, **When** they `POST /applications` or `PATCH /applications/{id}/status`, **Then** the system returns `403 permission_denied`, no application is created or modified, and no audit entry is written.

---

### User Story 4 - Applicant Tracks Their Own Application (Priority: P2)

An applicant returns to check the status of an application they submitted. They `GET /applications/{id}` for their own application and see the current status (`pending`, `under_review`, `approved`, `rejected`), the submission details they entered, and — if decided — the decision and the officer's reason. They cannot see the identity of the assigned officer (officer identity is internal to bank staff and auditors).

**Why this priority**: Materially improves applicant experience and reduces support contact, but is not strictly required for the submit-assign-decide loop to function. Can ship after the three P1 stories.

**Independent Test**: An applicant who has submitted one application can `GET /applications/{id}` for that application and receive a `200 OK` showing current status and (if decided) decision and reason. The response does not include any officer-identifying field. A `GET` to another applicant's application returns the byte-equivalent unauthorised-access response (see US5 invariant).

**Acceptance Scenarios**:

1. **Given** an authenticated applicant who submitted application `X`, **When** they `GET /applications/X`, **Then** the system returns `200 OK` showing `id`, `amount_minor`, `purpose`, `status`, `submitted_at`, `decision_reason` (if decided), `decided_at` (if decided), and **no** officer-identifying field.
2. **Given** an authenticated applicant whose application has been decided, **When** they `GET` it, **Then** the response includes `status` ∈ {`approved`, `rejected`} and a non-empty `decision_reason`.

---

### User Story 5 - Byte-Equivalent Unauthorised Access (Privacy Invariant) (Priority: P1)

An authenticated applicant attempts to `GET /applications/{id}` for an application that is **not** theirs. The system must respond identically — same status code, same body bytes — whether `{id}` refers to (a) a real application belonging to a different applicant, (b) a real application that simply hasn't been shared with this caller, or (c) an entirely non-existent identifier. This makes it impossible for an outsider to learn whether another customer's application exists.

**Why this priority**: This is the regulatory privacy guarantee the user description elevates to first-class status. Without it, an attacker can enumerate identifiers and tell whether targeted customers have applied. FCA Principle 6 (customer interest), GDPR data-minimisation, and the user description all require this property.

**Independent Test**: With three applications in the system — `X` (owned by Alice), `Y` (owned by Bob), `Z` (a fabricated identifier of valid shape that has never existed) — Alice's `GET /applications/Y` and Alice's `GET /applications/Z` must produce byte-identical responses: same HTTP status code, same response body bytes (no `Date`/`X-Request-Id`-style headers in the comparison; only the status line and body). The same property must hold for any non-owner caller across any pair of identifiers.

**Acceptance Scenarios**:

1. **Given** an authenticated applicant Alice owning application `X`, an authenticated applicant Bob owning application `Y`, and a fabricated identifier `Z` that has never existed, **When** Alice `GET`s `Y` and Alice `GET`s `Z`, **Then** both responses have the same HTTP status code and the same body bytes.
2. **Given** the same setup, **When** Alice `GET`s `X`, **Then** she receives `200 OK` with the full record — this is not in scope for byte-equivalence (the invariant binds only **unauthorised** access).
3. **Given** any caller without the `auditor` or assigned-`officer` privilege for an application, **When** they `GET` that application, **Then** the response is byte-identical to a `GET` for a non-existent identifier.

---

### Edge Cases

- **No eligible officer at submission time** (all other officers are unavailable, or the applicant is the only `officer` user): the application is created at status `pending` with `assigned_officer_id = null`; the initial audit entry records a system actor (`actor_id="system"`, `actor_role="system"`) with reason `"Submitted; no eligible officer available — assignment deferred"`; an operational re-assignment step (out of scope for this feature) must run before any officer can `PATCH` the application. This guarantees no applicant has their own application self-assigned to them.
- **Audit-write SLA at the boundary**: the system MUST commit the audit entry within 2 seconds of the state transition. If the write would exceed 2 s, the transition itself MUST roll back and the request MUST return `503 audit_unavailable`; no half-state is ever exposed. This preserves the invariant that every observable state change has a corresponding audit entry.
- **Token expiry mid-request**: a token that is valid at request arrival but expires before the handler completes is treated as valid for the duration of the in-flight request; per-request OAuth validation happens once, at the boundary, before any business logic. A subsequent request with the same expired token gets `401`.
- **PATCH with a status payload identical to the current status** (e.g., `under_review → under_review`): treated as `409 invalid_transition` (the allowed-transitions set has no self-loop); no audit entry is written.
- **PATCH skipping a stage** (e.g., `pending → approved`): treated as `409 invalid_transition`; no audit entry; the only legal first move out of `pending` is `under_review`.
- **Multiple concurrent PATCHes by the assigned officer on the same application** (e.g., two browser tabs): exactly one succeeds; the other receives `409 invalid_transition` or `409 already_decided` depending on the resulting current state, and writes no audit entry.
- **Auditor attempts to modify an audit entry directly** (e.g., crafted request to alter or delete a row): not exposed by any endpoint; structurally impossible at the storage layer (append-only). Any attempt that reaches the system is refused at the role layer with `403 permission_denied`.
- **Storage-layer corruption attempt on the audit log** (e.g., an operator's manual SQL update): out of scope at the API surface but the audit log MUST be designed so that an operational `UPDATE` or `DELETE` is detectable on subsequent read (see FR-018).

## Requirements *(mandatory)*

### Functional Requirements

#### Authentication, authorisation, and roles

- **FR-001**: All API endpoints (`POST /applications`, `GET /applications/{id}`, `PATCH /applications/{id}/status`, `GET /applications/{id}/audit`) MUST require an OAuth 2.0 bearer token in the `Authorization: Bearer <token>` header. Requests missing the header, malformed, or carrying an invalid/expired token MUST be rejected with HTTP `401 unauthenticated` **before** any request body parsing or business logic runs, and MUST NOT cause any audit log entry to be written.
- **FR-002**: The system MUST resolve every authenticated request to exactly one of three roles: `applicant`, `officer`, `auditor`. A user MAY hold the `applicant` role in addition to one of `officer` or `auditor` (e.g., a bank employee may also be a customer), but never simultaneously `officer` and `auditor`.
- **FR-003**: The system MUST allow `applicant`-role callers to submit new applications, view applications they themselves submitted, and view nothing else. They MUST NOT be able to `PATCH` any application's status, view another applicant's application, or view any audit log.
- **FR-004**: The system MUST allow `officer`-role callers to view any application assigned to them and to `PATCH` the status of any application assigned to them, subject to the no-self-approval rule (FR-013) and the allowed transitions (FR-009). They MUST NOT be able to submit applications via this feature, view applications not assigned to them (unless they additionally hold a role with broader read access), modify the audit log, or `PATCH` an application that lists them as the applicant.
- **FR-005**: The system MUST allow `auditor`-role callers to `GET` any application and any application's full audit log. They MUST NOT be able to `POST` a new application, `PATCH` any application's status, or modify any audit entry.

#### Applicant submission

- **FR-006**: The system MUST allow an authenticated applicant to submit an application capturing the requested amount and the purpose. The applicant's identity MUST be taken from the OAuth token's resolved user, never from the submitted payload.
- **FR-007**: The amount MUST be an integer in minor units (pence) within the inclusive range [£1,000, £25,000] (i.e., 100000 ≤ amount_minor ≤ 2500000). The purpose MUST be one of a fixed list of nine categories: `home_improvement`, `debt_consolidation`, `vehicle`, `education`, `medical`, `wedding`, `holiday`, `business`, `other`. Any value outside these constraints MUST cause the submission to be rejected with `400 validation_error`.
- **FR-008**: The system MUST prevent an applicant from having more than one application in flight (status `pending` or `under_review`) at the same time; a second submission while one is in flight MUST be refused with `409 has_in_flight_application`, naming the existing application's identifier and current status.

#### Status state machine and assignment

- **FR-009**: An application's status MUST belong to the set {`pending`, `under_review`, `approved`, `rejected`}. The only allowed transitions are: `(none) → pending` (on submission), `pending → under_review`, `under_review → approved`, `under_review → rejected`. Any other transition attempt MUST be refused with `409 invalid_transition` and MUST NOT write an audit entry.
- **FR-010**: On successful submission, the system MUST automatically assign exactly one `officer`-role user as the application's assigned officer. The assignment MUST be deterministic given the system's officer roster and prior assignment history (see Assumptions: round-robin among active officers, excluding the applicant). The assignment MUST be recorded atomically with the application's creation, so an application is never observed in a state with an `officer` field that is yet to be populated and an audit entry that has already been written.
- **FR-011**: The auto-assignment algorithm MUST exclude any officer who is the same user as the applicant (no self-assignment). If no eligible officer is available, the application MUST be created with `assigned_officer_id = null` and the initial audit entry MUST record a system actor noting "no eligible officer available; assignment deferred"; the application's status remains `pending` until an operational re-assignment process (out of scope for this feature) assigns one.
- **FR-012**: Only the assigned officer of an application MAY change its status. An attempt to `PATCH /applications/{id}/status` by anyone other than the assigned officer (including a different officer, an applicant, or an auditor) MUST be refused with `403 not_assigned_officer` (for officers) or `403 permission_denied` (for non-officer roles), MUST NOT change application state, and MUST NOT write an audit entry.
- **FR-013**: An officer MUST NOT be able to act as a deciding officer on an application where they themselves are the applicant (no self-approval, no self-rejection, no self-`under_review`). If such a `PATCH` attempt occurs, the system MUST refuse it with `403 self_decision_forbidden`, MUST NOT change application state, and MUST NOT write an audit entry. This rule applies even if the auto-assignment algorithm somehow assigned them to themselves (which FR-011 prevents); FR-013 is a defence-in-depth check at decision time.
- **FR-014**: Every `PATCH /applications/{id}/status` request MUST include a non-empty `reason` field describing why the transition is being made. A missing or empty reason MUST cause the request to be refused with `400 validation_error`, MUST NOT change application state, and MUST NOT write an audit entry.
- **FR-015**: Once an application reaches status `approved` or `rejected`, no further status changes are permitted. Any subsequent `PATCH` attempt MUST be refused with `409 already_decided`, MUST NOT change application state, and MUST NOT write an audit entry.

#### Audit log

- **FR-016**: The system MUST record an audit entry for every state transition on every application. Each entry MUST contain the following fields: `application_id` (string), `actor_id` (string; the user causing the transition, or `"system"` for system-initiated entries), `actor_role` (one of `applicant`, `officer`, `auditor`, `system`), `timestamp` (UTC, ISO 8601 with millisecond precision and explicit `Z` suffix), `previous_status` (one of `pending`, `under_review`, `approved`, `rejected`, or `null` for the initial submission entry), `new_status` (one of `pending`, `under_review`, `approved`, `rejected`), and `reason` (non-empty string).
- **FR-017**: The audit entry for any successful state transition MUST be durably persisted (committed to storage that survives process restart) within **2 seconds** of the transition being applied to the application's state. If the audit write would exceed 2 seconds, the transition itself MUST roll back and the request MUST return `503 audit_unavailable`; the application's state MUST be left unchanged and no partial audit entry MUST be visible to any reader. This guarantees the invariant that every observable state change has a corresponding audit entry.
- **FR-018**: The audit log MUST be immutable: there MUST be no API endpoint, role, or code path that can update or delete an existing audit entry. The storage of audit entries MUST be designed such that an out-of-band modification (e.g., a manual database `UPDATE`) is detectable on subsequent read (for example, by a per-entry signature/hash or by a chained-hash log structure). The exact mechanism is left to implementation, but the property — that operational tampering with an existing entry is detectable on read — MUST hold.
- **FR-019**: The audit log MUST retain every entry for at least 6 years from the date the entry was written, to satisfy FCA SYSC record-keeping rules. No public action MUST be able to delete an entry within that window.

#### Privacy invariant — byte-equivalent outsider response

- **FR-020**: For any caller without legitimate access to a given application (i.e., not the application's applicant, not the application's assigned officer, and not any user with the `auditor` role), a `GET /applications/{id}` MUST produce a response whose HTTP status code and response body bytes are identical to the response that the same caller would receive for `GET /applications/{nonexistent-id}` for any well-formed `{id}` that does not refer to an existing application. The comparison covers HTTP status and body bytes; per-request headers that cannot be made identical without losing functionality (e.g., `Date`, `Content-Length` if and only if it derives from the identical body) are out of scope of the byte-equivalence requirement.
- **FR-021**: The response that satisfies FR-020 MUST also be byte-equivalent to the response produced by a `GET` for an application that exists but is owned by a different applicant. Specifically, no information (including response size, response timing within reasonable jitter, error code, or message) MUST allow an outsider to distinguish between "this id refers to a real application I don't own" and "this id refers to no application".
- **FR-022**: The system MUST NOT leak through the `POST /applications` response, or any other endpoint's response, the existence or content of any application belonging to a different applicant. (E.g., the duplicate-detection response on `POST` exposes only the requesting applicant's own existing-in-flight identifier, never anyone else's.)

#### Auditor-only read on audit endpoint

- **FR-023**: The `GET /applications/{id}/audit` endpoint MUST be accessible to callers with role `auditor` for any `{id}`, and MUST NOT be accessible to any other role; a non-auditor caller MUST receive a response that is byte-equivalent to a `GET` for a non-existent application (i.e., the same response as FR-020 for `{id}` lookups), so that the audit endpoint does not leak the existence of applications to non-auditors.

#### Immutability of applicant-submitted data after submission

- **FR-024**: Once an application is submitted, the applicant MUST NOT be able to modify any of its fields (amount, purpose, etc.) through any endpoint of this feature. The only post-submission state change is via the officer's `PATCH` to the status field. Any applicant-initiated modification attempt MUST be refused with `403 permission_denied`.

### Key Entities *(include if feature involves data)*

- **Applicant**: A retail-banking customer who can apply for a loan. Has an identity. Can hold at most one in-flight application (status `pending` or `under_review`) at any time.
- **Officer**: A bank employee authorised to decide loan applications. Has an identity. Can be assigned applications and can move them through the allowed status transitions, subject to FR-013 (no self-approval).
- **Auditor**: A compliance reviewer with read-only access across every application and every audit entry. Cannot modify anything.
- **LoanApplication**: A single loan request. Holds the applicant's identity, the requested amount (in pence), the chosen purpose category, the current status, the submission timestamp, the assigned officer's identity (nullable only in the "no eligible officer" edge case), and — if decided — the decision and reason.
- **AuditEntry**: An immutable, append-only record of one state transition on one application. Holds `application_id`, `actor_id`, `actor_role`, `timestamp` (UTC ISO 8601), `previous_status` (nullable for the initial entry), `new_status`, and `reason`. Designed so out-of-band modification is detectable on read (FR-018).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: At least 95% of submitted applications are persisted at status `pending` with their initial audit entry written within 2 seconds of the `POST /applications` response being sent.
- **SC-002**: At least 99% of status-changing `PATCH` requests that pass authentication and authorisation have their resulting audit entry durably persisted within 2 seconds of the transition; the remaining ≤1% must roll back the transition and return `503` rather than expose any state without an audit entry. **Zero** observable state changes ever lack a corresponding audit entry.
- **SC-003**: Across all decided applications, 100% of audit entries contain non-empty `application_id`, `actor_id`, `actor_role`, `timestamp` (valid UTC ISO 8601), `previous_status`, `new_status`, and `reason`.
- **SC-004**: **Zero** occurrences in production where an applicant's response distinguishes between (a) an application that exists but belongs to another applicant and (b) a non-existent application. Verified by automated probes that randomly pair real and fabricated identifiers and assert byte-equivalence of the responses.
- **SC-005**: **Zero** occurrences in production where an officer successfully decides an application that does not list them as the assigned officer.
- **SC-006**: **Zero** occurrences in production where an officer successfully decides an application that lists them as the applicant (no self-approval).
- **SC-007**: **Zero** occurrences in production where an auditor's request modifies any application or audit entry.
- **SC-008**: **Zero** occurrences in production where a successful state transition has no audit entry, or where an audit entry exists without a corresponding successful transition. (Tested by reconciling audit log against application status history nightly.)
- **SC-009**: **Zero** occurrences in production where an audit entry, once written, is observed to be updated or deleted by any code path within 6 years; tamper-detection probe on read returns "intact" for 100% of audit entries.
- **SC-010**: **Zero** requests reach business logic without successful OAuth 2.0 bearer authentication (measured by request-trace audit: every business-logic span has a matching upstream auth-pass span).
- **SC-011**: At least 90% of decisions on applications that have reached `under_review` are recorded within 2 business days of submission.

## Assumptions

- **Authentication mechanism**: OAuth 2.0 bearer tokens are issued and validated by the bank's existing identity provider (out of scope for this feature). This feature consumes tokens and uses the resolved user identity plus a single role claim (`applicant` | `officer` | `auditor`); token rotation, refresh flows, sign-in UI, and consent screens are out of scope.
- **Role assignment**: Roles are assigned by the bank's existing identity governance process. A user holds exactly one of `officer` or `auditor` at a time (mutually exclusive bank-staff roles), but may additionally hold `applicant` (e.g., a bank employee who is also a personal customer). The system reads the role claim from the token and does not manage role assignment.
- **Auto-assignment algorithm**: The default algorithm is **round-robin** over the active officer roster, persisted across requests so that the next submission goes to the officer who has waited longest for an assignment. The applicant themselves is excluded from the candidate pool (FR-011). Alternative algorithms (load-balanced by current open queue, tier-based, manual assignment) are out of scope for v1; the algorithm is documented as a system property so it can be replaced without changing the spec's invariants.
- **Officer roster**: The set of users with role `officer` is read from the same identity system; this feature does not manage which users are officers.
- **Purpose categories**: The fixed list is `home_improvement`, `debt_consolidation`, `vehicle`, `education`, `medical`, `wedding`, `holiday`, `business`, `other`. The list reflects common UK retail-bank personal-loan categories; the business may add or remove categories later, but doing so is a spec-level change because it expands the contract.
- **Amount currency**: GBP only. Amounts are stored and transmitted in pence (integer minor units). Multi-currency support is out of scope.
- **Application identifier shape**: Application identifiers are opaque strings of fixed shape (UUID4-like, but the exact shape is a design decision). Identifiers are NOT human-readable references in v1.
- **Reason length and content**: `reason` on transitions is a free-text string of 1–1000 characters; no specific format is required. Officers and applicants are expected to write a meaningful sentence per bank-internal training; this feature does not enforce content beyond non-emptiness and length.
- **Time source**: All timestamps are produced by the system clock, normalised to UTC and serialised in ISO 8601 with millisecond precision and explicit `Z` suffix.
- **Notifications**: Notifying applicants of status changes (email, SMS, push) is **out of scope**. Applicants learn status by polling `GET /applications/{id}` (US4).
- **Withdrawal / cancellation by the applicant**: **Out of scope** for v1. An applicant who wants to cancel must contact support; operational tooling outside this feature can adjust state if needed.
- **Manager / supervisor role above officers**: **Out of scope**. There is no in-product reassignment of an `under_review` application; if the assigned officer is unavailable, operational tooling resets the application to `pending` with `assigned_officer_id = null` outside this feature.
- **Retention enforcement**: The 6-year retention requirement is satisfied by the absence of any DELETE code path against the audit log (FR-018, FR-019). Real retention-policy scheduling beyond 6 years (legal hold, lawful-basis exemptions, etc.) is operational policy outside this feature.
- **FCA SYSC interpretation**: The 6-year retention figure reflects the standard SYSC schedule for consumer-credit records. A change in FCA guidance materially affects FR-019 and would be addressed by a spec amendment.
- **Audit-write SLA mechanism**: The 2-second SLA is satisfied by writing the audit entry in the same atomic operation as the state transition, so that either both are visible or neither is. The SLA also constrains the system to fail fast (`503`) rather than persist a state change with a deferred audit write.

## Out of Scope

The following are explicitly **not** part of this feature and live behind existing bank tooling or future features:

- OAuth 2.0 token issuance, validation server, refresh, revocation, and sign-in UI.
- Identity governance: assigning the `applicant`, `officer`, or `auditor` role to a user.
- Pricing (interest rate, APR), monthly-repayment calculation, creditworthiness scoring, KYC, anti-money-laundering checks, sanctions screening.
- Document upload by the applicant.
- Customer-initiated withdrawal / cancellation of an application.
- Manager / supervisor role above officers; in-product reassignment of an `under_review` application.
- Editing applicant-submitted fields (amount, purpose) after submission.
- Multi-currency support.
- Notification delivery channels (email, SMS, push).
- Human-readable / "ticket-style" reference numbers in v1 (identifiers are opaque).
- A bulk audit-export endpoint for regulator handovers (point queries by application identifier only in v1).
- Pagination and search across applications for officer/auditor productivity (single-`GET`-by-id only in v1).
