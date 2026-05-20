# Feature Specification: Doctor-Patient Data Access

**Feature Branch**: `010-doctor-patient-access`  
**Created**: 2026-05-19  
**Status**: Draft  
**Input**: User description: "Design a healthcare data rule where a doctor can only access a patient's records if there is an active appointment scheduled between them."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Doctor accessing patient records (Priority: P1)

A doctor attempts to view a patient's medical records. If they have an active, scheduled appointment with the patient, access is granted.

**Why this priority**: Core functionality; ensures privacy and compliance with data access policies.

**Independent Test**: Login as a doctor with a scheduled appointment for a specific patient, then attempt to access that patient's records. Verify access is granted. Then, log in as a doctor *without* an appointment, verify access is denied.

**Acceptance Scenarios**:

1. **Given** a doctor has an active, scheduled appointment with a patient, **When** the doctor attempts to view the patient's records, **Then** access is granted.
2. **Given** a doctor does not have an active, scheduled appointment with a patient, **When** the doctor attempts to view the patient's records, **Then** access is denied and a notification/error is shown.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Ensure HIPAA compliance / Data privacy | `fact { all d: Doctor, p: Patient | d.canAccess(p) iff (some a: Appointment | a.doctor = d and a.patient = p and a.isActive) }` | Telemetry on unauthorized access attempts |

---

### Edge Cases

- What happens when an appointment is cancelled or finished? (Access should be revoked)
- Emergency access override is deferred and out of scope for this release.
- How does the system handle concurrent appointment scheduling/cancellation?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST verify the existence of an active appointment before granting access to patient records.
- **FR-002**: System MUST revoke access to patient records immediately when an appointment is no longer active (cancelled or completed).
- **FR-003**: System MUST provide an error message to doctors when access is denied due to no active appointment.
- **FR-004**: System MUST log all attempts (authorized and unauthorized) to access patient records.

### Key Entities

- **Doctor**: Medical professional requesting access.
- **Patient**: Individual whose records are being accessed.
- **Appointment**: Scheduled meeting between a Doctor and a Patient.
- **Record**: Clinical data/information belonging to a Patient.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of unauthorized access attempts to patient records by doctors without an active appointment are blocked.
- **SC-002**: 100% of authorized access requests by doctors with an active appointment are granted within 500ms.
- **SC-003**: All access attempts (granted or denied) are logged within 1 second of the action.

## Assumptions

- "Active appointment" is defined as an appointment that is scheduled in the future or currently ongoing, and has not been cancelled.
- Existing authentication/authorization systems will identify the doctor and patient roles.
- Access to patient records implies viewing their electronic health record (EHR).

## Formal Requirements & Business KPI Mapping

```alloy
sig Doctor {}
sig Patient {}
sig Appointment {
    doctor: one Doctor,
    patient: one Patient,
    isActive: one Bool
}
enum Bool { True, False }

pred canAccess[d: Doctor, p: Patient, apps: set Appointment] {
    some a: apps | a.doctor = d and a.patient = p and a.isActive = True
}

assert AccessControlRule {
    all d: Doctor, p: Patient, apps: set Appointment |
        (d -> p in canAccess) iff (some a: apps | a.doctor = d and a.patient = p and a.isActive = True)
}
```
