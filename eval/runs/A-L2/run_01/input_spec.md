# Feature: Bank Transfer

## Functional Requirements
- **FR-001**: Authenticated users can initiate transfers between their own accounts and to third-party beneficiaries. Transfers must be validated against the sender's available balance before execution.
- **FR-002**: The system must enforce authorisation checks on all transfer endpoints, ensuring only the account owner or a delegated operator can submit a transfer request.
- **FR-003**: Every transfer attempt — successful or failed — must be recorded in an immutable audit log including timestamp, actor identity, amount, and outcome.
- **FR-004**: The transfer service must remain operational and accept requests during scheduled peak periods including end-of-month payroll runs and public holiday surges.
