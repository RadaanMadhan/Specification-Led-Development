# Feature Specification: Loan Application with Role-Based Workflow and Audit Trail

**Feature Branch**: `004-loan-application-rbac`
**Created**: 2026-05-17
**Status**: Draft
**Input**: User description: "Build a loan application feature for a retail bank. Authenticated customers can submit loan applications specifying the amount requested and the purpose. Loan officers can review pending applications and approve or reject them; only the loan officer assigned to an application can change its status. Compliance reviewers can read any application and its decision history but cannot modify it. Every status change must be recorded in an audit trail showing the actor, timestamp, and previous/new status."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Customer Submits a Loan Application (Priority: P1)

A signed-in retail-banking customer wants to apply for a loan. They open the loan application form, enter the amount they want to borrow and the purpose of the loan, review a summary, and submit. The system records the application as awaiting review and gives the customer a reference number and an expected review timeframe.

**Why this priority**: Without this story, no application can enter the system; it is the indispensable first slice and creates the work item that the rest of the workflow acts on.

**Independent Test**: A test customer can open the form, enter a valid amount and purpose, submit, and receive an on-screen confirmation with a reference number. The application appears in the system at status "Submitted" with the customer's identity, the entered amount and purpose, and a submission timestamp.

**Acceptance Scenarios**:

1. **Given** a signed-in customer with no in-flight application, **When** they submit the form with a valid amount and a non-empty purpose, **Then** the system records the application with status "Submitted", assigns a unique reference number, records an audit entry of type "submitted" (previous status: none, new status: Submitted, actor: the customer, timestamp: now), and shows the customer a confirmation with the reference and an expected review timeframe.
2. **Given** a customer filling out the form, **When** they leave the amount blank, enter a non-numeric amount, enter an amount outside the allowed range, or leave the purpose blank, **Then** the system blocks submission and shows a field-level message that names the field and explains what is required.
3. **Given** a customer who already has an application that has not yet been decided, **When** they try to submit another, **Then** the system blocks the new submission and tells them their existing application is still under review, showing its reference and current status.

---

### User Story 2 - Loan Officer Claims an Application and Decides It (Priority: P1)

A loan officer signs in, opens the queue of submitted (unassigned) applications, picks one to work on, and claims it — the application is now assigned to them. While reviewing, they see everything the customer submitted. They record an approve or reject decision together with a non-empty reason. The application moves out of the unassigned queue and into the "decided" state.

**Why this priority**: The feature only delivers value if applications can actually be decided, and the assignment-then-decide flow is the core workflow the user described. This is the second indispensable half of the MVP.

**Independent Test**: With at least one application at status "Submitted", a test loan-officer can open the queue, claim an application, see its status change to "Under Review" with themselves as the assigned officer, then submit Approve (or Reject) with a non-empty reason. The application moves to "Approved" (or "Rejected"), and exactly two new audit entries are appended: Submitted→Under Review (actor: claiming officer) and Under Review→Approved/Rejected (actor: assigned officer). A different officer attempting to act on the claimed application is refused.

**Acceptance Scenarios**:

1. **Given** a loan officer viewing the unassigned queue, **When** they claim an application at status "Submitted", **Then** the application's status changes to "Under Review", the assigned officer is set to the claimer, and an audit entry is appended (previous: Submitted, new: Under Review, actor: the claiming officer, timestamp: now).
2. **Given** an application at status "Under Review" assigned to officer A, **When** officer A submits a decision (Approve or Reject) with a non-empty reason, **Then** the application's status changes accordingly, the decision (with reason, decider identity, and timestamp) is recorded, and an audit entry is appended (previous: Under Review, new: Approved/Rejected, actor: officer A, timestamp: now).
3. **Given** an application at status "Under Review" assigned to officer A, **When** officer B (a different loan officer) attempts to decide it, **Then** the system refuses the action with a message stating only the assigned officer may act on it, the application's status is unchanged, and no audit entry is written.
4. **Given** two loan officers open the same application at status "Submitted" simultaneously, **When** both attempt to claim it, **Then** exactly one claim succeeds, the other officer is informed that the application is already assigned (and to whom), and the audit trail contains exactly one Submitted→Under Review entry for that application.
5. **Given** an application already at status "Approved" or "Rejected", **When** any loan officer (including the one who decided it) attempts to change its status, **Then** the system refuses the action and the status, decision, and audit trail are unchanged.
6. **Given** a loan officer attempts to submit a decision with an empty reason, **When** they submit, **Then** the system blocks the submission with a field-level message; no audit entry is written.

---

### User Story 3 - Compliance Reviewer Inspects Application and Decision History (Priority: P1)

A compliance reviewer signs in, opens any application by reference (or by listing), and reviews every value the customer submitted, the current status, the decision (if any) and its reason, the identity of the assigned/deciding loan officer, and the full audit trail of status changes. They cannot make changes to anything: no claim, no decision, no edits, no deletions.

**Why this priority**: Read-only oversight is one of the three actor types the user described, and it is what makes the audit trail useful to anyone outside the loan-officer flow. Without it, the audit log exists but isn't usable for compliance, defeating its purpose.

**Independent Test**: A test compliance-reviewer user can list applications, open any specific application (regardless of customer or assigned officer), and see the application data, current status, decision, and full audit trail. Every attempt to write — claim, decide, edit a field, delete an audit entry — is refused.

**Acceptance Scenarios**:

1. **Given** a compliance reviewer signed in, **When** they list applications without filters, **Then** they see every application in the system regardless of customer or assigned officer, with reference, customer identity, amount, purpose, current status, and assigned officer (if any).
2. **Given** a compliance reviewer signed in, **When** they open an application by reference, **Then** they see all customer-submitted values, current status, assigned officer (if any), decision and reason (if decided), and the full audit trail of status changes ordered chronologically.
3. **Given** a compliance reviewer signed in, **When** they attempt to claim, decide, edit any field, or delete any audit entry on any application, **Then** every such attempt is refused and no data is modified.

---

### User Story 4 - Customer Tracks Their Own Application (Priority: P2)

A customer who has submitted an application returns to check on it. They open "My Applications" and see, for each of their own applications, the reference, submission date, current status (Submitted, Under Review, Approved, or Rejected), and — if decided — the decision and reason.

**Why this priority**: Improves customer experience and reduces support contacts, but is not strictly required for the apply-and-decide loop to function. Can ship after the P1 stories.

**Independent Test**: A customer with one or more submitted applications can open their list and see accurate status and (for decided applications) decision details for each. Other customers' applications are not visible. The customer cannot see which loan officer is assigned (officer identity is internal).

**Acceptance Scenarios**:

1. **Given** a customer with one or more applications, **When** they open their list, **Then** they see each of their own applications with reference, submission date, current status, and (if decided) decision and reason — and they cannot see any other customer's applications.
2. **Given** a customer viewing their application, **When** the assigned officer is set or changed, **Then** the customer does **not** see the officer's identity (it is not exposed to customers, only to compliance and to the officers themselves).

---

### Edge Cases

- Two loan officers attempt to claim the same submitted application at virtually the same time; only one claim succeeds; the other officer's attempt is refused with a clear message; exactly one Submitted→Under Review audit entry exists.
- A loan officer claims an application but then becomes unavailable (illness, vacation) before deciding it; customer-visible status remains "Under Review" indefinitely. Reassignment by a manager is **out of scope for v1** (see Assumptions): an operational support process is required to reset the application to "Submitted" outside this feature.
- A loan officer attempts to decide an application that is not currently at "Under Review" (e.g., still "Submitted" because no one claimed it, or already "Approved"/"Rejected"); the action is refused with a message naming the current status; no audit entry is written.
- A different loan officer than the assigned one attempts to act on an "Under Review" application; the action is refused; no audit entry is written.
- A compliance reviewer's request reaches the system through any write-style action (submit, claim, decide, edit); every such request is refused at the role layer before any business logic runs.
- A customer attempts to submit a second application while one is still in flight (Submitted or Under Review); the submission is refused with a message naming the in-flight application's reference and status.
- A customer attempts to view an application by reference that belongs to a different customer; the response is the same as for a non-existent reference (no existence leak).
- The system loses connectivity to its persistence layer mid-decision; on retry, the application's status, decision, and audit trail remain consistent — either the decision was recorded with its audit entry, or neither was, never one without the other.
- An attacker presents an unauthenticated or invalid credential; every endpoint refuses the request at the authentication boundary, with no information about which applications or users exist.

## Requirements *(mandatory)*

### Functional Requirements

#### Authentication and roles

- **FR-001**: The system MUST identify the caller on every request via the bank's existing authentication mechanism and assign them exactly one of three roles: `customer`, `loan_officer`, or `compliance_reviewer`. Requests that cannot be authenticated MUST be refused before any business logic runs.
- **FR-002**: The system MUST allow `customer`-role users to submit loan applications, view their own applications, and view the status, decision, and reason on their own applications. Customers MUST NOT be able to perform any other action.
- **FR-003**: The system MUST allow `loan_officer`-role users to list submitted (unassigned) applications, claim a submitted application, view any application they have claimed, and submit a decision on any application they have claimed. Loan officers MUST NOT be able to submit applications as a customer, decide applications they have not claimed, or modify already-decided applications.
- **FR-004**: The system MUST allow `compliance_reviewer`-role users to list every application in the system, view any application's full details, and view any application's full audit trail. Compliance reviewers MUST NOT be able to submit, claim, decide, or modify anything.

#### Customer submission

- **FR-005**: The system MUST allow an authenticated customer to submit a loan application capturing at minimum: the requested amount and the loan purpose. The customer's identity MUST be taken from the authentication context, not from the submitted payload.
- **FR-006**: The system MUST validate each application at submission time and refuse it with field-level messages if any required field is missing, if the amount is non-numeric, if the amount is outside the allowed range, or if the purpose is empty or longer than the permitted length.
- **FR-007**: The allowed personal loan amount range MUST be £1,000 to £25,000 inclusive, and the purpose MUST be a non-empty string of at most 500 characters. (See Assumptions.)
- **FR-008**: The system MUST prevent a customer from having more than one application in flight (status "Submitted" or "Under Review") at the same time; an attempt to submit a second such application MUST be refused with a message naming the existing application's reference and status.
- **FR-009**: On successful submission, the system MUST assign each application a unique, human-readable reference number, set its status to "Submitted", record the submission timestamp and the submitting customer's identity, and append an audit entry recording the submission.

#### Loan officer workflow (assignment and decision)

- **FR-010**: The system MUST present authorised loan officers with a queue of all applications currently at status "Submitted" (unassigned), showing for each: reference, customer name, requested amount, purpose, and submission date, ordered oldest first by default.
- **FR-011**: The system MUST allow an authorised loan officer to claim any application at status "Submitted"; on successful claim, the application's status MUST change to "Under Review", the assigned officer MUST be set to the claimer, and an audit entry MUST be appended recording the Submitted→Under Review transition.
- **FR-012**: The system MUST ensure that an application can be claimed by exactly one loan officer; concurrent claim attempts on the same submitted application MUST resolve such that only the first attempt succeeds and all subsequent attempts on that application are refused with a message naming the current assigned officer.
- **FR-013**: The system MUST allow an authorised loan officer to record a decision of "Approved" or "Rejected" on any application currently at status "Under Review" **only if** they are the application's assigned officer; an attempt to decide by anyone else (including another loan officer) MUST be refused with no state change.
- **FR-014**: The system MUST require a non-empty reason on every decision (both Approved and Rejected); a decision attempt without a reason MUST be refused with a field-level message and MUST NOT change application state.
- **FR-015**: On successful decision, the system MUST persist the decision, the reason, the deciding officer's identity, and the decision timestamp; the application's status MUST change to "Approved" or "Rejected" accordingly; and an audit entry MUST be appended recording the Under Review→Approved (or →Rejected) transition.
- **FR-016**: The system MUST prevent any further status changes (re-decision, un-claim, edits) once an application reaches "Approved" or "Rejected"; such attempts MUST be refused and the audit trail MUST NOT be appended to.

#### Audit trail

- **FR-017**: The system MUST record an audit entry for every status change on every application, including: actor identity (the user whose action caused the transition), timestamp, previous status (or "(none)" for the initial submission), and new status.
- **FR-018**: The audit trail MUST be append-only: no public action MUST modify or delete an existing audit entry. The audit entries for one application MUST be retrievable in chronological order.
- **FR-019**: For any application at any status, the audit trail MUST contain exactly one entry per status change actually applied — never zero (a status change without an audit entry) and never more than one (duplicate entries for the same applied change).

#### Customer visibility and read access

- **FR-020**: The system MUST allow an authenticated customer to list and view **only their own** applications and their decision/status, and MUST NOT expose any other customer's applications or any other customer's data.
- **FR-021**: The system MUST NOT expose the identity of an application's assigned/deciding loan officer to the customer who submitted it; officer identity is visible only to loan officers themselves (on their own claimed applications) and to compliance reviewers (on any application).

#### Compliance and data retention

- **FR-022**: The system MUST keep submitted applications, decisions, and audit entries for at least 6 years from the date of decision (or from the date of submission if not yet decided), to meet industry-standard financial record-keeping expectations.
- **FR-023**: The system MUST present a single read interface to compliance reviewers that exposes every application's full data, decision, and audit trail without granting any write capability whatsoever; the compliance role MUST be enforced at the action level, not only at the UI level.

### Key Entities *(include if feature involves data)*

- **Customer**: A retail-banking user who can apply for a loan. Has an identity, a name, and a history of their own applications. Cannot hold more than one in-flight application at a time.
- **Loan Officer**: A bank employee authorised to review and decide loan applications. Has an identity. Can claim submitted applications and decide ones they have claimed; cannot act on other officers' assignments.
- **Compliance Reviewer**: A bank employee authorised to read but never modify any application, decision, or audit entry across the entire system.
- **Loan Application**: A single request for a loan. Holds the customer's identity, the requested amount, the purpose, a unique reference, a current status (Submitted, Under Review, Approved, Rejected), a submission timestamp, and — once claimed — the assigned loan officer's identity.
- **Decision**: The outcome recorded by the assigned loan officer against an application. Holds the decision type (Approved or Rejected), the reason, the deciding officer's identity, and the decision timestamp. At most one decision exists per application.
- **Audit Entry**: An append-only record of a single status change on an application. Holds the actor's identity, the timestamp, the previous status (or none for initial submission), and the new status. Multiple entries exist per application across its lifecycle.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: At least 90% of customers who start the application form can submit it successfully in under 5 minutes (the form has only two fields plus confirmation; if customers can't get through it in 5 min, the form itself is the problem).
- **SC-002**: At least 95% of submitted applications receive a decision within 2 business days of submission.
- **SC-003**: 100% of decided applications have an associated non-empty reason, deciding officer identity, and decision timestamp recorded.
- **SC-004**: Zero cases occur in production where a customer can view another customer's application, and zero cases occur where a customer can perform a non-customer action (claim, decide, view audit trail).
- **SC-005**: Zero cases occur in production where a loan officer successfully decides an application that is not currently assigned to them.
- **SC-006**: Zero cases occur in production where two distinct claim outcomes exist for the same application (i.e., the "one assigned officer per application" invariant never breaks, even under concurrent claim attempts).
- **SC-007**: 100% of status changes on every application appear in that application's audit trail, with no audit entry missing the actor, timestamp, previous status, or new status; and zero audit entries exist for a status change that did not actually occur.
- **SC-008**: Zero cases occur in production where a compliance reviewer's request successfully modifies any application, decision, or audit entry.
- **SC-009**: A compliance reviewer can locate any application by reference and view its full decision and audit history in under 1 minute.

## Assumptions

- Customers, loan officers, and compliance reviewers are already authenticated through the bank's existing identity systems; this feature does not introduce new sign-up or sign-in flows. The bank's identity system provides the caller's identity and exactly one of the three roles per user on every request.
- A user has exactly one role; "loan officer who is also a customer of the bank for an unrelated product" is out of scope — a single account does not hold two roles in this feature's surface.
- **Assignment model is self-assignment (claim/pickup)**: a loan officer claims an unassigned application from the queue, and from then on only they can decide it. Manager-assigned, round-robin, or auto-assignment is **out of scope for v1**.
- **Reassignment / handoff is out of scope for v1**: once an application is at "Under Review" with officer A, there is no in-product way to reassign it to officer B. An operational support process can reset an application to "Submitted" outside this feature if an officer becomes unavailable.
- **Customer-initiated withdrawal is out of scope for v1**: a customer who wishes to withdraw an in-flight application must contact support, who can update the application via operational tooling.
- **Document upload (proof of income, ID, etc.) is out of scope for v1**: only the two structured fields (amount, purpose) are captured. Loan officers and compliance reviewers may rely on existing bank tooling outside this feature for additional customer data.
- **Pricing, APR, monthly repayment calculation, and creditworthiness scoring are out of scope**; loan officers decide based on the submitted information and existing bank tooling outside this feature.
- The amount range (£1,000–£25,000) and the 500-character purpose limit are reasonable defaults for a UK retail-bank personal loan; the business may tune these later without changing the shape of the feature.
- The customer-visible status set is exactly four values: **Submitted**, **Under Review**, **Approved**, **Rejected**. No "Withdrawn", no "Cancelled", no "On Hold" in v1.
- "Status change" in the audit-trail requirement covers all four observable transitions in this feature: (none)→Submitted, Submitted→Under Review, Under Review→Approved, Under Review→Rejected. No other transitions are reachable in v1.
- Record retention of 6 years aligns with standard UK financial record-keeping expectations and is used as the default in the absence of a stricter internal policy.

## Out of Scope

The following are explicitly **not** part of this feature and live behind the existing bank tooling or future features:

- Pricing, interest rate, APR, monthly-repayment schedule.
- Automated creditworthiness scoring.
- Document upload by the customer.
- Customer-initiated withdrawal of an in-flight application.
- Reassignment of an "Under Review" application from one loan officer to another.
- A manager / supervisor role above loan officers.
- Notification delivery channels (email, SMS, push) — customers learn of status by checking "My Applications" (US4); a separate notification feature can be added later.
- Editing customer-submitted fields after submission.
