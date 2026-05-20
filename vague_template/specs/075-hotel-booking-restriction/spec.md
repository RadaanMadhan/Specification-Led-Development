# Feature Specification: Hotel Booking Restriction

**Feature Branch**: `075-hotel-booking-restriction`  
**Created**: 20 May 2026  
**Status**: Draft  
**Input**: User description: "A hotel booking system where a room cannot be booked if it is marked as 'Under Maintenance' or 'Needs Cleaning'."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Prevent Booking of Unavailable Rooms (Priority: P1)

As a hotel guest, I want to be unable to book a room that is currently unavailable due to maintenance or cleaning, so that I only book rooms that are ready for stay.

**Why this priority**: This is the core functional constraint requested by the user.

**Independent Test**: Attempt to book a room with status 'Under Maintenance' or 'Needs Cleaning'. The system should reject the booking attempt.

**Acceptance Scenarios**:

1. **Given** a room has status 'Under Maintenance', **When** a guest attempts to book the room, **Then** the booking is rejected and the user receives a message indicating the room is unavailable.
2. **Given** a room has status 'Needs Cleaning', **When** a guest attempts to book the room, **Then** the booking is rejected and the user receives a message indicating the room is unavailable.
3. **Given** a room has status 'Available', **When** a guest attempts to book the room, **Then** the booking is accepted.

---

### User Story 2 - Staff Updates Room Status (Priority: P2)

As hotel staff, I want to update the status of a room to 'Under Maintenance' or 'Needs Cleaning', so that guests cannot book rooms that are not ready.

**Why this priority**: Necessary to ensure the system can enforce the restriction.

**Independent Test**: Staff member changes a room's status and verifies that the system prevents booking.

**Acceptance Scenarios**:

1. **Given** a room is 'Available', **When** staff updates the status to 'Under Maintenance', **Then** the room is no longer bookable by guests.
2. **Given** a room is 'Booked' and then checked out, **When** staff updates the status to 'Needs Cleaning', **Then** the room is no longer bookable by guests until the status is changed to 'Available'.

---

### Edge Cases

- What happens if the room status changes *while* a booking is being processed?
- How does the system handle booking attempts for rooms that don't exist?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST maintain the following statuses for each room: 'Available', 'Under Maintenance', 'Needs Cleaning', 'Booked'.
- **FR-002**: System MUST prevent any booking attempt if the room status is 'Under Maintenance'.
- **FR-003**: System MUST prevent any booking attempt if the room status is 'Needs Cleaning'.
- **FR-004**: System MUST allow hotel staff to update a room's status.

### Key Entities

- **Room**: Represents a physical room in the hotel. Attributes include room identifier and current status.
- **Booking**: Represents a reservation of a room. Linked to a specific room.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100% of booking attempts for rooms marked 'Under Maintenance' are rejected by the system.
- **SC-002**: 100% of booking attempts for rooms marked 'Needs Cleaning' are rejected by the system.
- **SC-003**: Authorized staff can successfully update room status within 5 seconds.

## Assumptions

- Room management (status updates) is performed by authorized hotel staff.
- Existing authentication system will be used to distinguish guests and hotel staff.
- Room booking system is the primary system managing room availability.

## Formal Requirements & Business KPI Mapping

```alloy
// Define Room Statuses
abstract sig Status {}
one sig Available, UnderMaintenance, NeedsCleaning, Booked extends Status {}

// Define Room
sig Room {
    var status: one Status
}

// Define Booking
sig Booking {
    room: one Room
}

// Constraint: A booking can only exist if the room is Available
fact BookingConstraint {
    all b: Booking | b.room.status = Available
}
```
