# Feature Specification: Hotel Booking Maintenance Restriction

**Feature Branch**: `022-hotel-booking-restrictions`  
**Created**: 2026-05-19  
**Status**: Draft  
**Input**: User description: "A hotel booking system where a room cannot be booked if it is marked as 'Under Maintenance' or 'Needs Cleaning'."

## User Scenarios & Testing

### User Story 1 - Prevent Booking of Unavailable Room (Priority: P1)

As a hotel guest, I want to be prevented from booking a room that is unavailable for use, so that I don't book a room that isn't ready.

**Why this priority**: This is the core requirement to prevent booking invalid rooms.

**Independent Test**: Attempt to book a room explicitly marked as 'Under Maintenance' and verify the booking is rejected.

**Acceptance Scenarios**:

1. **Given** a room is marked 'Under Maintenance', **When** a guest attempts to book it, **Then** the system rejects the booking.
2. **Given** a room is marked 'Needs Cleaning', **When** a guest attempts to book it, **Then** the system rejects the booking.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Prevent bookings of unavailable rooms | `fact { all b: Booking | b.room.status = Available }` | Analytics on failed booking attempts for unavailable rooms |

---

### User Story 2 - Display Room Availability Status (Priority: P2)

As a hotel guest, I want to see the availability status of a room, so that I can make informed decisions.

**Why this priority**: Enhances the user experience by providing transparency about why a room cannot be booked.

**Independent Test**: View room listings and verify that rooms have a visible 'Status' indicator.

**Acceptance Scenarios**:

1. **Given** a room is 'Under Maintenance', **When** the guest views room details, **Then** the status 'Under Maintenance' is displayed.
2. **Given** a room is 'Needs Cleaning', **When** the guest views room details, **Then** the status 'Needs Cleaning' is displayed.

**Formal Requirements & KPI Mapping**:
| Business Goal (KPI) | Formal Constraint (Alloy Concept) | Measurement Strategy |
| :--- | :--- | :--- |
| Improve user transparency | `assert { all r: Room | r.status in Status }` | UI interaction logging for room details page |

---

## Requirements

### Functional Requirements

- **FR-001**: System MUST restrict room booking if the status is 'Under Maintenance'.
- **FR-002**: System MUST restrict room booking if the status is 'Needs Cleaning'.
- **FR-003**: System MUST provide a clear message to the guest explaining why the booking was rejected (e.g., "Room not available at this time").
- **FR-004**: System MUST display the current status of each room to the guest.

### Key Entities

- **Room**: Represents a physical room in the hotel. Attributes: roomNumber, status ('Available', 'Under Maintenance', 'Needs Cleaning').
- **Booking**: Represents a reservation. Attributes: guestName, roomNumber, dates.

## Success Criteria

### Measurable Outcomes

- **SC-001**: 0% of bookings are successfully made for rooms marked as 'Under Maintenance' or 'Needs Cleaning'.
- **SC-002**: 100% of room listing pages correctly display the status of the room.
- **SC-003**: Guests receive an immediate error message when attempting to book an unavailable room.

## Assumptions

- 'Available' is the only status that allows a new booking.
- Room status management (setting to 'Under Maintenance' etc.) is handled by a separate module (out of scope for this feature).
- Existing booking API will be updated to include the status check.

## Formal Requirements & Business KPI Mapping
```alloy
sig Room {
    status: one Status
}

abstract sig Status {}
one sig Available, UnderMaintenance, NeedsCleaning extends Status {}

sig Booking {
    room: one Room
}

fact NoBookingForUnavailableRoom {
    all b: Booking | b.room.status = Available
}
```