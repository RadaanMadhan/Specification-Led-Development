# Feature: Clinical Record Access

## Functional Requirements
- **FR-001**: Authorised clinicians can retrieve and view patient records including medical history, prescriptions, and diagnostic results. Access is granted based on the clinician's role and their verified care relationship with the patient.
- **FR-002**: The system must enforce role-based access control so that only clinicians with an active care relationship can access a patient's full record. Administrative staff may access demographic data only. All access control decisions must be logged.
- **FR-003**: The clinical records service must maintain high availability as unplanned downtime directly impacts patient care. The system must support graceful degradation so that read access to existing records remains possible even if write operations are temporarily unavailable.
- **FR-004**: Every record access event must be captured in a tamper-evident audit trail including the clinician identity, patient identifier, record type accessed, timestamp, and access method (direct or delegated). Audit logs must be available for regulatory inspection.
