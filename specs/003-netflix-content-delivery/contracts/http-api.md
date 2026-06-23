# HTTP API Contract: Netflix Content Delivery & Access Control

**Spec**: ../spec.md
**Data Model**: ../data-model.md
**Created**: 2026-05-14
**Base URL**: `/api/v1`

## Authentication

All endpoints require a valid Bearer token in the `Authorization` header. Requests without a valid token receive a `401 Unauthorized` response before any authorization or business logic runs (FR-001).

## Authorization Matrix

| Endpoint | subscriber | content_admin | support_admin |
|----------|-----------|---------------|---------------|
| GET /catalogue | Allow (filtered by tier + region) | Allow (all titles) | Allow (all titles) |
| POST /catalogue | Deny | Allow | Deny |
| PUT /catalogue/{id} | Deny | Allow | Deny |
| DELETE /catalogue/{id} | Deny | Allow | Deny |
| POST /stream/{titleId} | Allow (tier + region gated) | Deny | Deny |
| GET /users/{id}/history | Allow (own only) | Deny | Allow (any user) |
| GET /audit | Deny | Deny | Allow |

## Endpoints

### GET /catalogue

**Description**: Browse the content catalogue. Results are filtered by the caller's subscription tier and region for subscribers; admins see all titles.
**Implements**: FR-003, FR-004

**Request**:

| Parameter | Location | Type | Required | Description |
|-----------|----------|------|----------|-------------|
| Authorization | header | string (Bearer token) | Yes | Auth token |
| genre | query | string | No | Filter by genre |
| page | query | integer | No | Page number (default: 1) |
| per_page | query | integer | No | Items per page (default: 20, max: 100) |

**Response (200 OK)**:

```json
{
  "data": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "name": "Stranger Things",
      "genre": "Sci-Fi",
      "required_tier": "Basic",
      "regions": ["US", "GB", "DE"]
    }
  ],
  "pagination": {
    "page": 1,
    "per_page": 20,
    "total": 142,
    "total_pages": 8
  }
}
```

**Error Responses**:

| Status | Code | Description |
|--------|------|-------------|
| 401 | UNAUTHORIZED | Missing or invalid auth token |

---

### POST /catalogue

**Description**: Add a new title to the catalogue. Only content_admin role.
**Implements**: FR-005, FR-008, FR-010

**Request**:

| Parameter | Location | Type | Required | Description |
|-----------|----------|------|----------|-------------|
| Authorization | header | string (Bearer token) | Yes | Auth token (content_admin) |
| name | body | string | Yes | Title name (1-500 chars) |
| genre | body | string | Yes | Content genre |
| required_tier | body | enum | Yes | Minimum tier: Basic, Standard, or Premium |
| regions | body | array(string) | Yes | Region codes where available |

**Response (201 Created)**:

```json
{
  "id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "name": "New Documentary",
  "genre": "Documentary",
  "required_tier": "Standard",
  "regions": ["US", "GB"],
  "status": "active",
  "created_at": "2026-05-14T10:30:00Z"
}
```

**Error Responses**:

| Status | Code | Description |
|--------|------|-------------|
| 400 | INVALID_TITLE | Name missing or exceeds 500 characters |
| 400 | INVALID_REGIONS | Regions array is empty |
| 401 | UNAUTHORIZED | Missing or invalid auth token |
| 403 | FORBIDDEN | Caller is not content_admin |

---

### PUT /catalogue/{id}

**Description**: Update an existing catalogue title. Only content_admin role.
**Implements**: FR-005, FR-008, FR-010

**Request**:

| Parameter | Location | Type | Required | Description |
|-----------|----------|------|----------|-------------|
| Authorization | header | string (Bearer token) | Yes | Auth token (content_admin) |
| id | path | UUID | Yes | Title ID |
| name | body | string | No | Updated title name |
| genre | body | string | No | Updated genre |
| required_tier | body | enum | No | Updated minimum tier |
| regions | body | array(string) | No | Updated region codes |

**Response (200 OK)**:

```json
{
  "id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "name": "Updated Documentary",
  "genre": "Documentary",
  "required_tier": "Premium",
  "regions": ["US", "GB", "DE"],
  "status": "active",
  "updated_at": "2026-05-14T11:00:00Z"
}
```

**Error Responses**:

| Status | Code | Description |
|--------|------|-------------|
| 401 | UNAUTHORIZED | Missing or invalid auth token |
| 403 | FORBIDDEN | Caller is not content_admin |
| 404 | TITLE_NOT_FOUND | Title does not exist |

---

### DELETE /catalogue/{id}

**Description**: Remove a title from the catalogue (sets status to removed). Only content_admin role.
**Implements**: FR-005, FR-008, FR-010

**Request**:

| Parameter | Location | Type | Required | Description |
|-----------|----------|------|----------|-------------|
| Authorization | header | string (Bearer token) | Yes | Auth token (content_admin) |
| id | path | UUID | Yes | Title ID |

**Response (200 OK)**:

```json
{
  "id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "status": "removed",
  "updated_at": "2026-05-14T12:00:00Z"
}
```

**Error Responses**:

| Status | Code | Description |
|--------|------|-------------|
| 401 | UNAUTHORIZED | Missing or invalid auth token |
| 403 | FORBIDDEN | Caller is not content_admin |
| 404 | TITLE_NOT_FOUND | Title does not exist |

---

### POST /stream/{titleId}

**Description**: Initiate a stream for a title. Checks subscription tier and region. Creates a ViewingHistory entry on success.
**Implements**: FR-003, FR-004, FR-011, FR-012

**Request**:

| Parameter | Location | Type | Required | Description |
|-----------|----------|------|----------|-------------|
| Authorization | header | string (Bearer token) | Yes | Auth token (subscriber) |
| titleId | path | UUID | Yes | Title to stream |

**Response (200 OK)**:

```json
{
  "stream_url": "https://cdn.example.com/stream/f47ac10b",
  "title": "Stranger Things",
  "viewing_history_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "started_at": "2026-05-14T14:00:00Z"
}
```

**Error Responses**:

| Status | Code | Description |
|--------|------|-------------|
| 401 | UNAUTHORIZED | Missing or invalid auth token |
| 403 | TIER_INSUFFICIENT | Subscriber's tier is below the title's required tier |
| 403 | REGION_RESTRICTED | Title is not available in subscriber's region |
| 403 | FORBIDDEN | Caller is not a subscriber |
| 404 | TITLE_NOT_FOUND | Title does not exist or is removed |

---

### GET /users/{id}/history

**Description**: Retrieve viewing history for a user. Subscribers can only view their own; support_admins can view any user's history.
**Implements**: FR-006, FR-007, FR-013

**Request**:

| Parameter | Location | Type | Required | Description |
|-----------|----------|------|----------|-------------|
| Authorization | header | string (Bearer token) | Yes | Auth token |
| id | path | UUID | Yes | User ID |
| page | query | integer | No | Page number (default: 1) |
| per_page | query | integer | No | Items per page (default: 20, max: 100) |

**Response (200 OK)**:

```json
{
  "data": [
    {
      "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
      "title_id": "550e8400-e29b-41d4-a716-446655440000",
      "title_name": "Stranger Things",
      "started_at": "2026-05-14T14:00:00Z"
    }
  ],
  "pagination": {
    "page": 1,
    "per_page": 20,
    "total": 47,
    "total_pages": 3
  }
}
```

**Error Responses**:

| Status | Code | Description |
|--------|------|-------------|
| 401 | UNAUTHORIZED | Missing or invalid auth token |
| 404 | NOT_FOUND | User not found or caller is a subscriber requesting another user's history (FR-013: must not distinguish "not found" from "not yours") |

---

### GET /audit

**Description**: Retrieve the catalogue mutation audit log. Only support_admin role.
**Implements**: FR-007, FR-009

**Request**:

| Parameter | Location | Type | Required | Description |
|-----------|----------|------|----------|-------------|
| Authorization | header | string (Bearer token) | Yes | Auth token (support_admin) |
| page | query | integer | No | Page number (default: 1) |
| per_page | query | integer | No | Items per page (default: 20, max: 100) |

**Response (200 OK)**:

```json
{
  "data": [
    {
      "id": "b2c3d4e5-f6a7-8901-bcde-f12345678901",
      "mutation_type": "create",
      "title_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
      "admin_id": "c3d4e5f6-a7b8-9012-cdef-123456789012",
      "timestamp": "2026-05-14T10:30:00Z"
    }
  ],
  "pagination": {
    "page": 1,
    "per_page": 20,
    "total": 5,
    "total_pages": 1
  }
}
```

**Error Responses**:

| Status | Code | Description |
|--------|------|-------------|
| 401 | UNAUTHORIZED | Missing or invalid auth token |
| 403 | FORBIDDEN | Caller is not support_admin |
