# Data Model: Netflix Content Delivery & Access Control

**Spec**: spec.md
**Created**: 2026-05-14

## Entities

### User

Represents a platform user (subscriber, content admin, or support admin).

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | UUID | Yes | Unique identifier |
| email | string(email) | Yes | User email address (unique) |
| role | enum(subscriber, content_admin, support_admin) | Yes | Exactly one role per user |
| subscription_tier | enum(Basic, Standard, Premium) | Yes (if subscriber) | Active subscription tier; null for non-subscribers |
| region | string(2) | Yes | ISO 3166-1 alpha-2 region code |
| created_at | datetime | Yes | Account creation timestamp |

**Validation Rules**:
- `email` must be unique across all users.
- Every user has exactly one `role`.
- `subscription_tier` is meaningful only for users with role `subscriber`.

---

### Title

A content item in the streaming catalogue.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | UUID | Yes | Unique identifier |
| name | string | Yes | Display title (1-500 characters) |
| genre | string | Yes | Content genre |
| required_tier | enum(Basic, Standard, Premium) | Yes | Minimum subscription tier required to stream |
| regions | set(string(2)) | Yes | Set of ISO 3166-1 alpha-2 region codes where available |
| status | enum(active, removed) | Yes | Whether the title is active in the catalogue |
| created_at | datetime | Yes | Catalogue addition timestamp |
| updated_at | datetime | Yes | Last modification timestamp |

**Validation Rules**:
- `name` must be 1-500 characters.
- `regions` must contain at least one region code.
- `required_tier` must be one of Basic, Standard, Premium.

---

### ViewingHistory

Records a subscriber streaming a specific title. Append-only from the subscriber's perspective (system creates entries; subscribers cannot modify or delete them).

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | UUID | Yes | Unique identifier |
| user_id | UUID (-> User.id) | Yes | The subscriber who streamed |
| title_id | UUID (-> Title.id) | Yes | The title that was streamed |
| started_at | datetime | Yes | When the stream began |

**Validation Rules**:
- `user_id` must reference an existing User with role `subscriber`.
- `title_id` must reference an existing, active Title.
- Each stream request produces exactly one ViewingHistory entry (FR-011).

---

### AuditEntry

An append-only record of a catalogue mutation. No UPDATE or DELETE operations are exposed on this entity for any role, including content_admin (FR-009).

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | UUID | Yes | Unique identifier |
| mutation_type | enum(create, update, delete) | Yes | The type of catalogue mutation |
| title_id | UUID (-> Title.id) | Yes | The title affected by the mutation |
| admin_id | UUID (-> User.id) | Yes | The admin who performed the mutation |
| timestamp | datetime | Yes | When the mutation was recorded |

**Validation Rules**:
- `admin_id` must reference a User with role `content_admin`.
- Each catalogue mutation produces exactly one AuditEntry (FR-008); UNIQUE(title_id, timestamp) per mutation.
- No UPDATE or DELETE on AuditEntry rows.

## Relationships

- **User** 1:N **ViewingHistory** (a subscriber has many viewing history entries)
- **Title** 1:N **ViewingHistory** (a title can be streamed many times)
- **User (content_admin)** 1:N **AuditEntry** (an admin authors many audit entries)
- **Title** 1:N **AuditEntry** (a title can have many audit entries over time)

## Indexes

- `User.email` (unique)
- `ViewingHistory.user_id` (for per-user history lookups)
- `ViewingHistory.title_id` (for per-title analytics)
- `AuditEntry.title_id` (for per-title audit trail)
- `AuditEntry.admin_id` (for per-admin audit trail)
