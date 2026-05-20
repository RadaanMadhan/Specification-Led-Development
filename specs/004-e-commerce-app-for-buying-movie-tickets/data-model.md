# Data Model: E-Commerce App for Buying Movie Tickets

**Spec**: spec.md
**Created**: 2026-05-14

## Entities

### User

Represents an authenticated customer who can browse movies, reserve seats, purchase tickets, and manage their orders. Authentication is handled externally via OAuth 2.0 / OpenID Connect; this entity stores the profile and links to all user activity.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | UUID | Yes | Unique identifier |
| email | string(email) | Yes | User's email address, used for notifications and account identification |
| name | string | Yes | User's display name |
| phoneNumber | string | No | User's phone number for SMS notifications |
| createdAt | datetime | Yes | Timestamp when the user account was created |
| updatedAt | datetime | Yes | Timestamp of the last profile update |

**Validation Rules**:
- `email` must be a valid email format and unique across all users.
- `name` must be between 1 and 255 characters.
- `phoneNumber`, if provided, must conform to E.164 international format.

---

### Movie

Represents a film in the catalog. Movies are browsable by users and are linked to one or more showtimes. A movie only appears in browse results if it has at least one future showtime.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | UUID | Yes | Unique identifier |
| title | string | Yes | Display title of the movie |
| synopsis | string | Yes | Full plot synopsis / description |
| genre | set(string) | Yes | One or more genre tags (e.g., Action, Comedy, Drama) |
| rating | string | Yes | Content rating (e.g., G, PG, PG-13, R) |
| runtime | integer | Yes | Runtime in minutes |
| posterUrl | string | Yes | URL to the movie poster image |
| cast | set(string) | No | List of principal cast member names |
| releaseDate | datetime | Yes | Theatrical release date |
| createdAt | datetime | Yes | Timestamp when the movie record was created |
| updatedAt | datetime | Yes | Timestamp of the last update to the movie record |

**Validation Rules**:
- `title` must be between 1 and 500 characters.
- `genre` must contain at least one value from a predefined genre vocabulary.
- `runtime` must be a positive integer greater than 0.
- `posterUrl` must be a valid URL.
- `releaseDate` must be a valid date.

---

### Cinema

Represents a physical theater location containing one or more screens. Cinemas are used for location-based filtering when browsing movies and showtimes.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | UUID | Yes | Unique identifier |
| name | string | Yes | Display name of the cinema |
| address | string | Yes | Full street address of the cinema |
| city | string | Yes | City where the cinema is located |
| state | string | No | State or province |
| postalCode | string | Yes | Postal / ZIP code |
| country | string | Yes | ISO 3166-1 alpha-2 country code |
| latitude | decimal | Yes | Geographic latitude for proximity searches |
| longitude | decimal | Yes | Geographic longitude for proximity searches |
| timezone | string | Yes | IANA timezone identifier (e.g., America/New_York) |
| createdAt | datetime | Yes | Timestamp when the cinema record was created |
| updatedAt | datetime | Yes | Timestamp of the last update to the cinema record |

**Validation Rules**:
- `name` must be between 1 and 255 characters.
- `latitude` must be between -90 and 90.
- `longitude` must be between -180 and 180.
- `country` must be a valid ISO 3166-1 alpha-2 code.
- `timezone` must be a valid IANA timezone string.

---

### Screen

Represents an individual auditorium within a cinema. Screens define the physical seat layout and capacity, and host showtimes. Seat layouts are pre-configured per screen and do not change between showtimes.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | UUID | Yes | Unique identifier |
| cinemaId | UUID (-> Cinema.id) | Yes | Foreign key to the parent cinema |
| name | string | Yes | Display name of the screen (e.g., "Screen 1", "IMAX Hall") |
| totalRows | integer | Yes | Number of seat rows in the layout |
| totalColumns | integer | Yes | Number of seat columns in the layout |
| capacity | integer | Yes | Total number of bookable seats |
| createdAt | datetime | Yes | Timestamp when the screen record was created |
| updatedAt | datetime | Yes | Timestamp of the last update to the screen record |

**Validation Rules**:
- `name` must be between 1 and 100 characters.
- `totalRows` must be a positive integer greater than 0.
- `totalColumns` must be a positive integer greater than 0.
- `capacity` must be a positive integer and must not exceed `totalRows * totalColumns`.
- `cinemaId` must reference an existing Cinema.

---

### SeatTemplate

Represents the fixed layout definition of a physical seat within a screen. This is the static seat configuration that does not change per showtime. Per-showtime seat availability is tracked in ShowtimeSeat.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | UUID | Yes | Unique identifier |
| screenId | UUID (-> Screen.id) | Yes | Foreign key to the parent screen |
| row | string | Yes | Row label (e.g., "A", "B", "C") |
| column | integer | Yes | Column number within the row |
| category | enum(standard, premium, accessible) | Yes | Seat category determining pricing and accessibility |
| isActive | boolean | Yes | Whether the seat is bookable (false for blocked/non-existent positions) |

**Validation Rules**:
- The combination of `screenId`, `row`, and `column` must be unique.
- `column` must be a positive integer.
- `row` must be a non-empty string of at most 5 characters.
- Each screen's count of active SeatTemplates must equal the screen's `capacity`.

---

### Showtime

Represents a specific screening of a movie on a screen at a given date and time. Showtimes connect movies to physical screens and define pricing. Associated ShowtimeSeat records track per-seat availability for the screening.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | UUID | Yes | Unique identifier |
| movieId | UUID (-> Movie.id) | Yes | Foreign key to the movie being screened |
| screenId | UUID (-> Screen.id) | Yes | Foreign key to the screen hosting this showtime |
| startTime | datetime | Yes | Scheduled start time of the screening |
| endTime | datetime | Yes | Scheduled end time of the screening |
| priceStandard | decimal | Yes | Ticket price for standard category seats (in local currency) |
| pricePremium | decimal | Yes | Ticket price for premium category seats |
| priceAccessible | decimal | Yes | Ticket price for accessible category seats |
| currency | string | Yes | ISO 4217 currency code (e.g., USD, EUR) |
| status | enum(scheduled, cancelled) | Yes | Current status of the showtime |
| createdAt | datetime | Yes | Timestamp when the showtime was created |
| updatedAt | datetime | Yes | Timestamp of the last update |

**Validation Rules**:
- `endTime` must be after `startTime`.
- `startTime` must be in the future at the time of creation.
- Showtimes for the same screen must not have overlapping `startTime`–`endTime` windows.
- `priceStandard`, `pricePremium`, and `priceAccessible` must be non-negative decimals with at most 2 decimal places.
- `currency` must be a valid ISO 4217 code.
- `movieId` must reference an existing Movie.
- `screenId` must reference an existing Screen.

---

### ShowtimeSeat

Represents the availability state of a specific seat for a specific showtime. Created from SeatTemplate when a showtime is scheduled. Tracks real-time status transitions (available → locked → sold) and enforces the no-double-booking invariant.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | UUID | Yes | Unique identifier |
| showtimeId | UUID (-> Showtime.id) | Yes | Foreign key to the showtime |
| seatTemplateId | UUID (-> SeatTemplate.id) | Yes | Foreign key to the seat template defining the physical seat |
| status | enum(available, locked, sold) | Yes | Current booking status of this seat for this showtime |
| heldByUserId | UUID (-> User.id) | No | User who currently holds a lock on this seat; null if not locked |
| lockExpiresAt | datetime | No | Timestamp when the temporary lock expires; null if not locked |
| version | integer | Yes | Optimistic concurrency control version for atomic seat lock operations |

**Validation Rules**:
- The combination of `showtimeId` and `seatTemplateId` must be unique (each physical seat appears exactly once per showtime).
- When `status` is `locked`, both `heldByUserId` and `lockExpiresAt` must be non-null.
- When `status` is `available`, both `heldByUserId` and `lockExpiresAt` must be null.
- When `status` is `sold`, `heldByUserId` must be null and `lockExpiresAt` must be null.
- At most one user may hold a lock on a seat for a given showtime (enforced by atomic version-checked updates).
- `version` starts at 0 and is incremented on every status change.

---

### Reservation

A temporary hold on one or more seats for a specific showtime, created when a user selects seats. The reservation has a configurable TTL (default 10 minutes). It is either converted into an order upon successful payment, or expires and releases the held seats.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | UUID | Yes | Unique identifier |
| userId | UUID (-> User.id) | Yes | Foreign key to the user who made the reservation |
| showtimeId | UUID (-> Showtime.id) | Yes | Foreign key to the showtime |
| reservationToken | string | Yes | Unique opaque token returned to the client for checkout reference |
| status | enum(active, expired, converted) | Yes | Current lifecycle state of the reservation |
| expiresAt | datetime | Yes | Timestamp when the reservation TTL expires and seats are released |
| createdAt | datetime | Yes | Timestamp when the reservation was created |
| updatedAt | datetime | Yes | Timestamp of the last status update |

**Validation Rules**:
- `reservationToken` must be globally unique.
- `expiresAt` must be after `createdAt`.
- A reservation must reference at least one ReservationSeat.
- A user may have at most one `active` reservation per showtime at any given time.
- Status transitions: `active` → `converted` (on successful payment), `active` → `expired` (on TTL expiry). No other transitions are allowed.

---

### ReservationSeat

Join entity linking a reservation to the specific showtime seats it holds. Enables the atomic all-or-nothing seat locking invariant.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | UUID | Yes | Unique identifier |
| reservationId | UUID (-> Reservation.id) | Yes | Foreign key to the parent reservation |
| showtimeSeatId | UUID (-> ShowtimeSeat.id) | Yes | Foreign key to the specific showtime seat being held |

**Validation Rules**:
- The combination of `reservationId` and `showtimeSeatId` must be unique.
- A `showtimeSeatId` may appear in at most one active reservation at any time.
- All `showtimeSeatId` values in a reservation must belong to the same showtime as the reservation's `showtimeId`.

---

### Order

A confirmed purchase representing a completed transaction. Created upon successful payment processing, converting a reservation into permanent tickets. Supports status transitions for cancellation and refund workflows.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | UUID | Yes | Unique identifier |
| userId | UUID (-> User.id) | Yes | Foreign key to the purchasing user |
| reservationId | UUID (-> Reservation.id) | Yes | Foreign key to the originating reservation |
| showtimeId | UUID (-> Showtime.id) | Yes | Foreign key to the showtime (denormalized for query efficiency) |
| totalAmount | decimal | Yes | Total price paid for all tickets in this order |
| currency | string | Yes | ISO 4217 currency code |
| status | enum(confirmed, cancelled, refunded, payment_failed) | Yes | Current order lifecycle state |
| paymentGatewayTransactionId | string | No | External transaction ID from the payment gateway |
| idempotencyKey | string | Yes | Client-provided idempotency key to prevent duplicate payment processing |
| refundAmount | decimal | No | Amount refunded, if applicable |
| refundedAt | datetime | No | Timestamp of the refund, if applicable |
| createdAt | datetime | Yes | Timestamp when the order was created |
| updatedAt | datetime | Yes | Timestamp of the last status update |

**Validation Rules**:
- `totalAmount` must be a positive decimal with at most 2 decimal places.
- `currency` must be a valid ISO 4217 code and must match the showtime's currency.
- `idempotencyKey` must be globally unique.
- `reservationId` must reference a reservation with status `converted` (after order creation).
- `refundAmount`, if set, must be non-negative and must not exceed `totalAmount`.
- Status transitions: `confirmed` → `cancelled`, `confirmed` → `refunded`, `payment_failed` is terminal. No transition from `cancelled` or `refunded`.
- Each `reservationId` may be referenced by at most one order with status `confirmed`.

---

### Ticket

An individual entry pass within an order, corresponding to one seat for one showtime. Each ticket carries a unique QR code payload for cinema gate validation.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | UUID | Yes | Unique identifier |
| orderId | UUID (-> Order.id) | Yes | Foreign key to the parent order |
| showtimeSeatId | UUID (-> ShowtimeSeat.id) | Yes | Foreign key to the specific showtime seat |
| price | decimal | Yes | Price paid for this individual ticket |
| qrCodePayload | string | No | Encoded QR code data containing ticket ID, showtime, cinema, and seat info |
| status | enum(valid, used, cancelled) | Yes | Current ticket lifecycle state |
| createdAt | datetime | Yes | Timestamp when the ticket was generated |
| updatedAt | datetime | Yes | Timestamp of the last status update |

**Validation Rules**:
- `price` must be a non-negative decimal with at most 2 decimal places.
- `qrCodePayload`, when present, must be unique across all tickets.
- Status transitions: `valid` → `used` (at cinema entry), `valid` → `cancelled` (on order cancellation). No transition from `used` or `cancelled`.
- Each `showtimeSeatId` may be referenced by at most one ticket with status `valid` or `used`.
- An order's tickets' `price` values must sum to the order's `totalAmount`.

---

## Relationships

- **Cinema** 1:N **Screen** (a cinema contains one or more screens/auditoriums)
- **Screen** 1:N **SeatTemplate** (a screen defines its physical seat layout via seat templates)
- **Screen** 1:N **Showtime** (a screen hosts many showtimes over time)
- **Movie** 1:N **Showtime** (a movie is screened across many showtimes)
- **Showtime** 1:N **ShowtimeSeat** (a showtime has one seat record per physical seat in the screen)
- **SeatTemplate** 1:N **ShowtimeSeat** (a physical seat template has one ShowtimeSeat per showtime it participates in)
- **User** 1:N **Reservation** (a user can create many reservations over time)
- **Showtime** 1:N **Reservation** (a showtime can have many concurrent reservations from different users)
- **Reservation** 1:N **ReservationSeat** (a reservation holds one or more seats)
- **ShowtimeSeat** 1:N **ReservationSeat** (a showtime seat may appear in reservation history, but at most one active reservation)
- **User** 1:N **Order** (a user can have many orders)
- **Reservation** 1:1 **Order** (a reservation converts into at most one confirmed order)
- **Showtime** 1:N **Order** (a showtime can have many orders from different users)
- **Order** 1:N **Ticket** (an order contains one or more tickets)
- **ShowtimeSeat** 1:1 **Ticket** (a sold showtime seat corresponds to exactly one valid/used ticket)

## Indexes

- `User.email` (unique; login and account lookup)
- `Movie.genre` (filtering movies by genre in browse queries)
- `Movie.releaseDate` (sorting and filtering by release date)
- `Cinema.latitude, Cinema.longitude` (geospatial index for proximity-based cinema search)
- `Cinema.city` (filtering cinemas by city)
- `Screen.cinemaId` (lookup of screens belonging to a cinema)
- `SeatTemplate.screenId` (lookup of seat layout for a screen)
- `Showtime.movieId` (lookup of all showtimes for a movie)
- `Showtime.screenId` (lookup of all showtimes on a screen; overlap detection)
- `Showtime.startTime` (filtering and sorting showtimes by date/time)
- `Showtime.movieId, Showtime.startTime` (composite; filtered showtime queries for a specific movie by date)
- `ShowtimeSeat.showtimeId, ShowtimeSeat.status` (composite; fast retrieval of available/locked/sold seats for a showtime's seat map)
- `ShowtimeSeat.showtimeId, ShowtimeSeat.seatTemplateId` (unique composite; enforces one record per seat per showtime)
- `ShowtimeSeat.status, ShowtimeSeat.lockExpiresAt` (composite; batch expiry job to find and release expired locks)
- `Reservation.userId` (lookup of a user's reservations)
- `Reservation.showtimeId, Reservation.status` (composite; active reservation lookup per showtime)
- `Reservation.reservationToken` (unique; token-based reservation lookup at checkout)
- `Reservation.expiresAt, Reservation.status` (composite; TTL expiry job to find active reservations past their deadline)
- `ReservationSeat.reservationId` (lookup of seats in a reservation)
- `ReservationSeat.showtimeSeatId` (lookup/uniqueness check for active holds on a seat)
- `Order.userId, Order.createdAt` (composite; user order history sorted by date)
- `Order.showtimeId` (lookup of all orders for a showtime; reconciliation)
- `Order.reservationId` (unique; reservation-to-order lookup)
- `Order.idempotencyKey` (unique; duplicate payment prevention)
- `Order.status` (filtering orders by status for reporting and reconciliation)
- `Ticket.orderId` (lookup of all tickets in an order)
- `Ticket.showtimeSeatId` (uniqueness enforcement and seat-to-ticket lookup)
- `Ticket.qrCodePayload` (unique; QR code validation at cinema entry)