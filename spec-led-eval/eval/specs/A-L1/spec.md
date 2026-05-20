# Feature Specification: Loan Application

**Feature Branch**: `003-loan-application`
**Created**: 2026-05-17
**Status**: Draft
**Input**: User description: "Build a loan application feature where customers can apply for personal loans and bank staff can approve or reject them."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Customer Submits a Personal Loan Application (Priority: P1)

A signed-in customer wants to borrow money for a personal need (e.g., home repair, debt consolidation). They open the loan application form, enter the amount they want to borrow, the repayment term they prefer, the purpose of the loan, and their employment and income details. They review a summary, confirm the information is accurate, and submit the application. They receive an on-screen confirmation with a reference number and an expectation of when they will hear back.

**Why this priority**: Without this story, no loans can enter the system; it is the minimum viable slice that delivers customer-facing value and creates the work item that bank staff later act on.

**Independent Test**: A test customer can open the application form, complete all required fields, submit it, and see a confirmation with a reference number. The submitted application is visible in the system as "Pending Review" and contains every value the customer entered.

**Acceptance Scenarios**:

1. **Given** a signed-in customer with no in-progress application, **When** they submit a completed application with valid amount, term, purpose, and income details, **Then** the system records the application with status "Pending Review", assigns a unique reference number, and shows the customer a confirmation containing that reference and an expected review timeframe.
2. **Given** a customer filling out the form, **When** they leave a required field blank or enter an invalid value (e.g., non-numeric income, amount outside the allowed range), **Then** the system prevents submission and shows a field-level message that names the field and explains what is required.
3. **Given** a customer who has already submitted an application that is still under review, **When** they try to submit another, **Then** the system blocks the new submission and tells them their existing application is still being reviewed, showing its reference number and status.

---

### User Story 2 - Bank Staff Reviews and Decides on an Application (Priority: P1)

A bank staff member responsible for personal loan decisions signs in, opens a queue of pending applications, picks one, and reviews all the information the customer submitted. They record a decision — approve or reject — and write a short reason. The customer is notified of the outcome, and the application moves out of the pending queue.

**Why this priority**: The feature only delivers business value if staff can actually act on submissions; an application that no one can decide on is not a loan product. This is the second indispensable half of the MVP.

**Independent Test**: With at least one application already in "Pending Review", a test staff user can open the queue, open the application, choose Approve (or Reject), enter a reason, and confirm. The application's status updates accordingly, the decision and reason are persisted with the staff member's identity and timestamp, and the customer can see the new status when they next view their application.

**Acceptance Scenarios**:

1. **Given** a staff member viewing an application in "Pending Review", **When** they choose "Approve" and submit a non-empty reason, **Then** the application's status changes to "Approved", the decision (with reason, decider identity, and timestamp) is recorded, the application leaves the pending queue, and the customer sees the new status and reason.
2. **Given** a staff member viewing an application in "Pending Review", **When** they choose "Reject" and submit a non-empty reason, **Then** the application's status changes to "Rejected" with the decision recorded as above, and the customer sees the rejection and reason.
3. **Given** a staff member who has already decided an application, **When** they reopen it, **Then** the decision, reason, decider identity, and timestamp are shown read-only and the approve/reject controls are disabled.
4. **Given** two staff members open the same pending application simultaneously, **When** the first submits a decision, **Then** the second is informed on submission attempt that the application is already decided, and their action is not applied.

---

### User Story 3 - Customer Tracks Application Status (Priority: P2)

A customer who has already submitted an application returns to the system to check progress. They open "My Applications" and see each application's reference number, submission date, current status, and — if decided — the decision reason and decision date.

**Why this priority**: This significantly improves customer experience and reduces inbound support contacts, but is not strictly required for the apply-and-decide loop to function. It can ship after P1 stories are live.

**Independent Test**: A customer with at least one submitted application can open the status view and see accurate status, reference number, submission date, and (once decided) decision details for each of their applications. Other customers' applications are not visible.

**Acceptance Scenarios**:

1. **Given** a customer with one or more submitted applications, **When** they open their application list, **Then** they see each of their own applications with reference number, submission date, current status, and (if decided) the decision and reason — and they cannot see any other customer's applications.
2. **Given** a customer whose application has just been decided, **When** they reload the status view, **Then** the new status and decision details are reflected.

---

### Edge Cases

- A customer abandons the application form partway through; the in-progress data is discarded (no partial application enters the queue) and no reference number is issued.
- A customer enters an income that is clearly inconsistent (e.g., zero income with a high loan amount); the system still accepts the application but staff see all entered values during review and can reject with a reason.
- A staff member submits a decision with an empty reason; submission is blocked with a field-level message — a reason is mandatory for both approve and reject.
- A pending application becomes "stale" because the customer wants to withdraw it; customer-initiated withdrawal is out of scope for v1 (see Assumptions) — the customer is told to contact support.
- The customer is signed out (session expired) when they press submit; the partially entered data is not lost on the device, and the customer is prompted to sign in again and resubmit.
- A staff member loses connectivity mid-decision; on retry, if the application was already decided by them or another staff member, the system surfaces the existing decision rather than recording a duplicate.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST allow an authenticated customer to start, complete, and submit a personal loan application capturing at minimum: requested amount, repayment term, loan purpose, employment status, employer name (when employed), gross annual income, and contact preference.
- **FR-002**: The system MUST validate each application field at submission time and reject the submission with field-level messages when any required field is missing, when the amount is outside the allowed range, when the term is outside the allowed set of options, or when numeric fields contain non-numeric values.
- **FR-003**: The allowed personal loan amount range MUST be £1,000 to £25,000 inclusive, and the allowed repayment terms MUST be 12, 24, 36, 48, or 60 months. (See Assumptions.)
- **FR-004**: On successful submission, the system MUST assign each application a unique, human-readable reference number, record the submission timestamp and the submitting customer's identity, and set the application status to "Pending Review".
- **FR-005**: The system MUST prevent a customer from having more than one application in "Pending Review" at the same time; an attempt to submit a second is rejected with a message naming the existing application's reference.
- **FR-006**: The system MUST show the customer a confirmation screen on successful submission, including the reference number and an indication that they will hear back within the published review timeframe.
- **FR-007**: The system MUST present authorised bank staff with a queue of all applications in "Pending Review", showing for each: reference number, customer name, requested amount, term, and submission date, ordered oldest first by default.
- **FR-008**: The system MUST allow authorised bank staff to open any application from the queue and view every value the customer entered, along with submission timestamp and the customer's contact details.
- **FR-009**: The system MUST allow authorised bank staff to record a decision of either "Approved" or "Rejected" on any application currently in "Pending Review", and MUST require a non-empty reason to accompany the decision.
- **FR-010**: On decision submission, the system MUST persist the decision, the reason, the deciding staff member's identity, and the decision timestamp; the application status MUST change to "Approved" or "Rejected" accordingly and the application MUST no longer appear in the pending queue.
- **FR-011**: The system MUST prevent any further decision changes on an application that has already reached "Approved" or "Rejected" status; reopening such an application MUST show the decision details read-only.
- **FR-012**: The system MUST resolve concurrent decisions on the same application such that only the first submitted decision is recorded; subsequent decision attempts on the same application MUST be rejected with a message indicating the application is already decided.
- **FR-013**: The system MUST allow an authenticated customer to view a list of their own applications and the details and current status of each, and MUST NOT expose any other customer's applications to them.
- **FR-014**: The system MUST notify the customer when their application's status changes from "Pending Review" to "Approved" or "Rejected", using the customer's recorded contact preference (in-app at minimum; email if the customer's contact preference is email).
- **FR-015**: The system MUST restrict the decision actions (approve, reject, queue access, application detail access) to users with the bank-staff role; customers MUST NOT be able to access these actions or views.
- **FR-016**: The system MUST keep an audit record of every status change on an application (submission, approval, rejection), including who performed it and when, in a form that authorised staff can inspect.
- **FR-017**: The system MUST retain submitted applications and their decisions for at least 6 years from the date of decision, to meet industry-standard financial record-keeping expectations.

### Key Entities *(include if feature involves data)*

- **Customer**: The party applying for a loan. Has an identity, a name, a contact preference, and a history of applications. Can hold at most one "Pending Review" application at a time.
- **Bank Staff Member**: An employee authorised to review and decide on loan applications. Has an identity and the bank-staff role.
- **Loan Application**: A single request for a personal loan. Holds the customer's identity, the requested amount, the repayment term, the loan purpose, the employment and income details captured at submission, a unique reference number, a current status (Pending Review, Approved, Rejected), and the submission timestamp.
- **Decision**: The outcome recorded by a staff member against a loan application. Holds the decision type (Approved or Rejected), the reason, the deciding staff member's identity, and the decision timestamp. At most one decision exists per application.
- **Audit Entry**: A record of a status-changing event on an application (submitted, approved, rejected). Holds the event type, actor identity, and timestamp; entries are append-only.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: At least 90% of customers who start the application form can submit it successfully (without abandoning) in under 8 minutes.
- **SC-002**: At least 95% of submitted applications receive a decision within 2 business days of submission.
- **SC-003**: 100% of decided applications have an associated non-empty reason, decider identity, and decision timestamp recorded.
- **SC-004**: Zero cases occur in production where a customer can view another customer's application, and zero cases occur where a customer can make a decision (approve/reject) on any application.
- **SC-005**: Zero applications can reach a state of having two recorded decisions, even under concurrent decision attempts by multiple staff members.
- **SC-006**: At least 80% of customers report (via post-decision survey) that they were kept clearly informed about their application's status.

## Assumptions

- Customers are already authenticated through the bank's existing customer identity system; this feature does not introduce new sign-up or sign-in flows.
- Bank staff are already authenticated through the bank's existing internal identity system, and a "bank-staff" role already exists or can be assigned to the relevant users.
- The amount range (£1,000–£25,000) and the term options (12/24/36/48/60 months) reflect typical UK personal loan parameters and are used as reasonable defaults; the business may tune these later without changing the shape of the feature.
- Pricing (interest rate, APR, monthly repayment calculation) and any creditworthiness scoring are **out of scope** for this feature; staff make decisions based on submitted information and existing bank tooling outside this feature.
- Document upload (e.g., proof of income, ID documents) is **out of scope** for v1; only structured form data is captured.
- Customer-initiated withdrawal of a submitted application is **out of scope** for v1; customers wishing to withdraw must contact support, who can update the application's status through existing operational tooling.
- Notification to the customer on decision uses the bank's existing notification mechanisms (in-app and email); this feature does not build a new notification channel.
- A customer can hold multiple decided (Approved or Rejected) applications over time; the "one in flight" restriction applies only to applications in "Pending Review".
- Record retention of 6 years aligns with standard UK financial record-keeping expectations and is used as the default in the absence of a stricter internal policy.
