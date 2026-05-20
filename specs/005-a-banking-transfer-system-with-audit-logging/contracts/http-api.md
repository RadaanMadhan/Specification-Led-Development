# HTTP API Contract: Banking Transfer System with Audit Logging

**Spec**: ../spec.md
**Data Model**: ../data-model.md
**Created**: 2026-05-18
**Base URL**: `/api/v1`

## Authentication

All endpoints require a valid Bearer token issued by the external identity provider (IdP). The token must be passed in the `Authorization` header. The system verifies the token, extracts the caller's `userId` and `roles`, and confirms `authenticationStatus = AUTHENTICATED` before processing any request. Users with `authenticationStatus` of `UNAUTHENTICATED` or `LOCKED` are rejected. See FR-010 for the fail-closed audit constraint that applies across all state-changing endpoints.

## Authorization Matrix

| Endpoint | CUSTOMER | ADMIN |
|----------|----------|-------|
| POST /transfers | Allow (own accounts only) | Allow (any accounts) |
| GET /transfers/{transactionId} | Allow (own transfers only) | Allow (any transfer) |
| POST /transfers/{transactionId}/reverse | Deny | Allow (within reversal window) |
| GET /accounts/{accountId}/balance | Allow (own accounts only) | Allow (any account) |
| GET /accounts/{accountId}/transactions | Allow (own accounts only) | Allow (any account) |
| GET /audit-entries | Deny | Allow |
| GET /audit-entries/verify | Deny | Allow |
| POST /transfers/{transactionId}/step-up | Allow (own pending step-up only) | Deny |

## Endpoints

### POST /transfers

**Description**: Initiate a fund transfer from a source account to a destination account. The system validates sufficient funds, enforces daily transfer limits, evaluates fraud risk, atomically debits the source and credits the destination, and creates audit log entries for every lifecycle event. If fraud risk triggers a step-up authentication requirement, the transfer is held in `INITIATED` status and a step-up challenge is returned. The transfer fails closed if audit logging is unavailable.
**Implements**: FR-001, FR-002, FR-003, FR-004, FR-005, FR-006, FR-007, FR-010

**Request**:

| Parameter | Location | Type | Required | Description |
|-----------|----------|------|----------|-------------|
| Authorization | header | string (Bearer token) | Yes | Auth token identifying the caller |
| sourceAccountId | body | UUID | Yes | Account ID to debit |
| destinationAccountId | body | UUID | Yes | Account ID to credit |
| amount | body | integer | Yes | Transfer amount in minor units (cents); must be > 0 |
| currency | body | string | Yes | ISO 4217 currency code (e.g., `USD`); must match both accounts |

**Response (201 Created)**: