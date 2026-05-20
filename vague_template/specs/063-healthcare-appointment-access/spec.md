# Feature Specification: Healthcare Appointment Access Control

**Feature Branch**: `063-healthcare-appointment-access`  
**Created**: 20 May 2026  
**Status**: Draft  
**Input**: User description: "Design a healthcare data rule where a doctor can only access a patient's records if there is an active appointment scheduled between them."

## User Scenarios & Testing

### User Story 1 - Doctor Access with Appointment (Priority: P1)

As a doctor, I want to access a patient's medical records when I have an active scheduled appointment with them, so that I can provide proper care.

**Why this priority**: Core functionality required to support the healthcare workflow.

**Independent Test**: Verify that a doctor associated with a patient in an active appointment can retrieve the patient's records.

**Acceptance Scenarios**:

1. **Given** a doctor has an active appointment with a patient, **When** the doctor requests to view the patient's records, **Then** the system grants access to the records.

---

### User Story 2 - Deny Access without Appointment (Priority: P2)

As a doctor, I should be denied access to a patient's medical records if I do not have an active scheduled appointment with them, to ensure patient data privacy.

**Why this priority**: Essential security/privacy requirement.

**Independent Test**: Verify that a doctor NOT associated with a patient in an active appointment is denied access to the patient's records.

**Acceptance Scenarios**:

1. **Given** a doctor does not have an active appointment with a patient, **When** the doctor requests to view the patient's records, **Then** the system denies access and provides an unauthorized error message.

---

### Edge Cases

- What happens when an appointment is scheduled for the future? (Requirement: Appointment must be 'active' - define as ongoing or starting within a reasonable buffer).
- What happens when an appointment has recently concluded? (Requirement: Access should terminate immediately upon appointment end).
- How does the system handle concurrent access requests?

## Requirements

### Functional Requirements

- **FR-001**: System MUST verify the active appointment status between a doctor and a patient before granting access to the patient's medical records.
- **FR-002**: System MUST deny record access if no active appointment is found between the requesting doctor and the target patient.
- **FR-003**: System MUST log all unauthorized attempts to access medical records.
- **FR-004**: System MUST define an "active appointment" as one currently in progress or within a defined time buffer (e.g., 15 minutes before start).

### Key Entities

- **Doctor**: Medical professional requesting access.
- **Patient**: Subject of the medical records.
- **Appointment**: Scheduled interaction between a doctor and a patient with a start and end time.
- **MedicalRecord**: Sensitive data belonging to a patient.

## Success Criteria

### Measurable Outcomes

- **SC-001**: 100% of unauthorized record access requests from doctors without active appointments are successfully blocked.
- **SC-002**: Authorized doctors successfully retrieve patient records within 0.5 seconds of request.
- **SC-003**: All denied access attempts are logged for auditing purposes.

## Assumptions

- An existing scheduling system provides the appointment data with verifiable start/end times.
- "Medical Records" are clearly defined as data that falls under this restriction.
- Active appointment validation is performed in real-time.

## Formal Requirements & Business KPI Mapping

```alloy
sig Doctor {}
sig Patient {}
sig MedicalRecord { owner: Patient }
sig Appointment {
    doctor: Doctor,
    patient: Patient,
    active: one Bool
}

pred CanAccess[d: Doctor, p: Patient, r: MedicalRecord] {
    some a: Appointment | 
        a.doctor = d and 
        a.patient = p and 
        a.active = True and
        r.owner = p
}

assert AccessControlRule {
    all d: Doctor, p: Patient, r: MedicalRecord |
        (no a: Appointment | a.doctor = d and a.patient = p and a.active = True)
        => not CanAccess[d, p, r]
}

check AccessControlRule for 5
```
