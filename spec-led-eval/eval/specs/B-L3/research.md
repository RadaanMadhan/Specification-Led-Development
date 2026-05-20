# Research: Multi-Tenant Task Management with Per-Task Sharing and Audit

**Branch**: `008-task-sharing` | **Date**: 2026-05-17

The spec has no remaining `[NEEDS CLARIFICATION]` markers — the three clarifications resolved to Q1 = A (owner-controlled indefinite shares), Q2 = A (field-name-list `diff_summary`), Q3 = B (sharee can view + edit, no delete, no onward share). 008 is the most invariant-rich feature in this repo — it picks up byte-equivalent cross-tenant isolation and an OAuth 2.0 introspection seam from 005, an audit log from 005/007, a two-tier role model with an extra "sharee" relation, and adds two new dimensions on top: **per-task sharing as a first-class concept** and **an explicit performance target** (200 req/s @ p99 ≤ 300 ms per workspace).

This document records the design decisions, focusing on the new tensions:

1. **The 1-second audit SLA vs the 200 req/s performance target** under stdlib SQLite — does it work?
2. **Per-task sharing inside the existing PATCH endpoint** (no new endpoint per the description's exhaustive list).
3. **The per-event audit semantics**: one PATCH can produce multiple audit entries, all in the same transaction.
4. **The byte-equivalent invariant extended to `PATCH`, `DELETE`, and the audit endpoint** — a wider surface than 005, which only pinned `GET` body bytes.

## HTTP server: stdlib `http.server` (ThreadingHTTPServer)

**Decision**: As in every prior feature. `http.server.ThreadingHTTPServer` + dispatch in `server.py`.

**Rationale**: Constitution I. Five JSON endpoints. The performance target (200 req/s, p99 ≤ 300 ms) makes a framework choice more interesting — but adding a framework wouldn't change the bottleneck, which is the single-writer SQLite connection (see "Performance" below). Sticking with the stdlib pattern keeps Constitution I satisfied and keeps the deployment story trivial.

## Storage: stdlib `sqlite3` with WAL mode and tuned PRAGMAs

**Decision**: SQLite via `sqlite3`. File-backed in production-style runs; `:memory:` in tests. Schema and all SQL in `store.py`. Connection opened with the following PRAGMAs after creation:

- `PRAGMA journal_mode = WAL;` — concurrent readers + serialized writers; readers do not block each other or the writer.
- `PRAGMA synchronous = NORMAL;` — faster commits than FULL while keeping crash-consistency for the WAL.
- `PRAGMA temp_store = MEMORY;` — small wins on sort/intermediate work.
- `PRAGMA mmap_size = 134217728;` (128 MB) — page cache via mmap.

The connection is opened with `timeout=0.8` (800 ms) so that contended writes fail fast within the 1-second audit SLA budget (FR-018), leaving ~200 ms of headroom for response serialisation.

**Rationale**: WAL is the key change vs prior features (which used the default rollback journal). Under our workload (60% reads, 40% writes), the WAL gives concurrent readers full throughput while serialising writers — exactly the mix we need for SC-010. The 800 ms connection timeout maps directly to FR-018: if a `BEGIN IMMEDIATE … COMMIT` cannot get the write lock within 800 ms, we treat that as SLA-breach and roll back with `503 audit_unavailable`.

Tables: `users`, `teams`, `tokens` (auth stub), `tasks`, `task_shares` (junction: `task_id, sharee_user_id`), `audit_entries`. The junction table is preferred over a JSON `shared_with` column on `tasks` because (a) we need to query "is user X a sharee on task Y?" on the hot read path — an index on `(task_id, sharee_user_id)` is O(1), versus a JSON scan; and (b) the audit-emitting code can diff the old vs new share set via simple SQL set-difference.

**Alternatives considered**:
- **Default rollback journal**: blocks readers during writes. Rejected — the 60% reads at 200 req/s require concurrent reads.
- **PostgreSQL**: would trivialise SC-010 but adds a non-stdlib dependency. Rejected on Constitution I; the spec explicitly puts performance targeting on the design, not on the storage choice; we accept that stdlib SQLite is on the edge of the target and document the implication (see "Performance" below).
- **`shared_with` as a JSON column on `tasks`**: simpler schema but worse for the diff-on-PATCH operation. Rejected.

## Authentication: OAuth 2.0 bearer with stub introspector

**Decision**: As in feature 005, every request authenticates via `Authorization: Bearer <token>` resolved through a `TokenIntrospector` Protocol whose v1 implementation is a `StubIntrospector` over a seeded `tokens` table. The introspection result is the authoritative source of `user_id`, `team_id`, and `role` (FR-002, FR-002a).

```python
class TokenIntrospector(Protocol):
    def introspect(self, token: str) -> AuthenticatedCaller | None: ...

@dataclass(frozen=True)
class AuthenticatedCaller:
    user_id: str
    team_id: str
    role: Role             # 'member' or 'team_admin'
    token_expires_at: datetime
```

**Rationale**: The spec is firm that `team_id` and `role` come from the introspected token, never from the request payload (FR-002, SC-006). The Protocol-with-stub pattern from 005 satisfies that contract at v1 and stays drop-in-compatible with a real RFC 7662 introspection endpoint.

**Where 401 happens**: in `server.py`'s dispatch, before the request is routed to a handler. Tested by `test_oauth.py` injecting forged payloads and asserting that the resolved `team_id`/`role` comes from the token and not the body (SC-006 probe).

## Authorisation: predicate-based with three caller-relationship classes

**Decision**: A single `permissions.is_allowed(caller, action, task)` function consults an explicit table. The interesting bit is that the caller's "relationship to the task" — owner, sharee, team_admin, neither — is computed once and fed in:

```python
def relationship(caller: AuthenticatedCaller, task: Task) -> Relationship:
    if caller.team_id != task.team_id:
        return Relationship.OUTSIDER     # cross-team → byte-equivalent 404
    if caller.user_id == task.owner_id:
        return Relationship.OWNER
    if caller.user_id in task.shared_with:
        return Relationship.SHAREE
    if caller.role == Role.TEAM_ADMIN:
        return Relationship.TEAM_ADMIN
    return Relationship.IN_TEAM_NONE     # in-team-but-no-access → byte-equivalent 404
```

Permission matrix (action × relationship):

| Action                              | OUTSIDER | IN_TEAM_NONE | SHAREE | TEAM_ADMIN | OWNER |
|-------------------------------------|----------|--------------|--------|------------|-------|
| `create_task`                       | n/a      | ✅ (becomes owner) | n/a | ✅      | n/a   |
| `view_task`                         | 404      | 404          | ✅      | ✅          | ✅     |
| `edit_task` (any field except `shared_with`/`owner_id`/`team_id`) | 404 | 404 | ✅ | ✅      | ✅     |
| `change_shared_with`                | 404      | 404          | ❌ (400 validation_error on `shared_with`) | ❌ (400 validation_error) | ✅ |
| `delete_task`                       | 404      | 404          | 404 (byte-equivalent — Q3 = B) | ✅ | ✅ |
| `view_audit`                        | 404      | 404          | ✅      | ✅          | ✅     |

**Why 404 for sharee `DELETE` and not 403**: The spec's FR-014 byte-equivalence applies whenever the caller "does not have the read-or-act permission". A sharee can `GET` the task but cannot `DELETE` it; the question is whether `DELETE` should return 403 (revealing the task exists) or 404 (consistent with the byte-equivalent envelope). The spec resolves it to 404 (FR-014 + FR-011): the sharee already knows the task exists via `GET`, so the 404 on `DELETE` doesn't actually hide anything they didn't already know — but it does keep the contract uniform across endpoints and removes a 403 code path. Tested by `test_byte_equivalence.py`.

## Per-task sharing via `PATCH /tasks/{id}` (no new endpoint)

**Decision**: The user description's five-endpoint list is exhaustive. Sharing is exposed by treating `shared_with` as a regular field on the task that is settable via `PATCH /tasks/{id}` — with the catch that only the owner may set it (FR-010, Q1 = A).

The PATCH body accepts `shared_with: list[user_id]` — the full new set (not a delta). The service layer diffs the old vs new set and emits one `shared` audit entry per added user_id and one `unshared` entry per removed user_id (FR-013, FR-015).

**Why a list, not a delta**: It's idempotent — sending the same list twice produces no audit entries (no diff). It's easier to reason about than `add` / `remove` operations. The client always knows the full intended state and sends it.

**Single-PATCH multi-event audit semantics**: A PATCH that changes both a field and the share list produces multiple audit entries: one `edited` (with the field-name-list `diff_summary`) plus one `shared`/`unshared` per affected sharee. All entries are written in the same `BEGIN IMMEDIATE … COMMIT` block as the task UPDATE; if any one of them cannot be persisted within the 800 ms write-lock budget, the whole transaction rolls back with `503 audit_unavailable` (FR-018).

## Cross-team isolation: a single response helper with `Content-Length` pinning

**Decision**: A canonical `responses.not_found_response()` returns:

```http
HTTP/1.1 404 Not Found
Content-Type: application/json; charset=utf-8
Content-Length: 53

{"error":"not_found","message":"No such task."}
```

Every code path that returns a "you can't see this" 404 uses this single helper — `GET`, `PATCH`, `DELETE`, `GET …/audit` — and the body, `Content-Type`, and `Content-Length` are identical. This is a stricter byte-equivalence guarantee than feature 005 (which pinned `GET` 404s only) or 007 (which pinned status+body but not Content-Length).

**Test design**: `test_byte_equivalence.py` constructs identifier quadruples `(own-team-task, cross-team-task, fabricated-id, sharee-on-DELETE)` and for each of four endpoints (`GET`, `PATCH`, `DELETE`, `GET …/audit`) asserts that the unauthorised cases all produce identical `(status, content_type, content_length, body_bytes)` tuples.

**What we deliberately do not protect against**: response timing variance. The unauthorised-read path takes the same code path (a single `SELECT` filtered on `team_id`) for both "doesn't exist" and "in another team", so timing variance is bounded to one DB hit. Constant-time response is out of scope for v1; documented as future work if the threat model requires it.

## 1-second audit SLA strategy

**Decision**: The audit entries are inserted in the same `BEGIN IMMEDIATE … COMMIT` transaction as the task mutation. The SQLite connection is opened with `timeout=0.8` (800 ms). Under contention, `BEGIN IMMEDIATE` or `COMMIT` will block for up to 800 ms then raise `sqlite3.OperationalError`; we catch that and return `503 audit_unavailable`. The transaction is rolled back automatically by SQLite.

```text
Total budget: 1000 ms
├─ Auth (token introspection):    ~5 ms typical, ~50 ms worst case
├─ Permission check + load task:  ~5 ms (indexed)
├─ Validation + diff computation: ~1 ms
├─ Write lock acquisition + INSERT(s) + COMMIT: up to 800 ms (the connection timeout)
└─ Response serialisation + send: ~50 ms
                            Total: ~860 ms typical max
```

**Why 800 ms and not 900 ms**: leaves ~200 ms of headroom for the rest of the request. Empirically, SQLite COMMITs to a local SSD complete in <5 ms under no contention, so 800 ms is generous for contention only.

**Measurement**: `test_audit_sla.py` holds the write lock in another thread for 1.5 s, fires a PATCH, and asserts (a) `503 audit_unavailable`, (b) task state unchanged, (c) zero audit entries written.

## Performance target (200 req/s @ p99 ≤ 300 ms): can stdlib SQLite hit it?

**Decision**: Yes, on a developer machine, with the PRAGMAs above and careful index design. Honest analysis:

- **60% GETs (= 120 req/s)** — single-row PK lookup via `SELECT * FROM tasks WHERE id = ? AND team_id = ?`. WAL mode means these don't contend with writes. SQLite serves single-row PK lookups at ~10,000+ req/s on a developer machine. **Not the bottleneck.**
- **5% audit GETs (= 10 req/s)** — `SELECT * FROM audit_entries WHERE task_id = ? AND team_id = ? ORDER BY id`. Indexed by `(task_id, occurred_at, id)`. Same story. **Not the bottleneck.**
- **20% PATCHes (= 40 req/s)** — these acquire the write lock. Each PATCH includes (a) one task UPDATE, (b) 1–N audit INSERTs (typically 1). Under WAL, a write transaction takes ~1–5 ms; 40 req/s of writes is comfortably within capacity (theoretical max ~200–1000 writes/s).
- **10% POSTs (= 20 req/s)** — similar to PATCH; one INSERT into `tasks` + one INSERT into `audit_entries`. **Not the bottleneck.**
- **5% DELETEs (= 10 req/s)** — one INSERT into `audit_entries` + one DELETE from `tasks` (cascading via the FK or via explicit delete from `task_shares` first). Comfortable.

**Aggregate write load**: ~70 req/s (PATCH + POST + DELETE), each holding the write lock for 1–5 ms. Total write-lock occupation: 70–350 ms/sec. Plenty of headroom.

**p99 latency**: under no contention, every request completes in <50 ms. p99 ≤ 300 ms allows for a worst-case contention burst of ~250 ms — well above the 5–10 ms typical write transaction, so even N writers stacked behind one writer all finish within the p99 budget.

**Caveats and what this means in production**:
- This is a single-process, single-connection model. Scaling beyond ~1 workspace at 200 req/s by adding processes would mean sharing the SQLite file across processes, which works under WAL but doesn't scale linearly.
- A real production deployment of 008 should use a real RDBMS (PostgreSQL). The plan keeps the storage layer behind `store.py` so the swap is mechanical.
- The PoC's load test (`test_performance.py`) is a smoke test, not a real benchmark; it asserts the design isn't catastrophically slow rather than proving SC-010 at production scale.

**Alternatives considered**:
- **No WAL**: tested informally on a previous feature — readers blocking on writers tanks the GET p99. Rejected.
- **Separate connection per request**: SQLite supports it but the per-connection overhead (open, PRAGMAs, close) dominates the budget. Single shared connection + `threading.Lock` is the standard stdlib pattern.

## `actor_role` snapshot vs live lookup

**Decision**: Snapshot. The audit entry stores `actor_role` as it was at the time of the change (FR-016). If a user's role is later changed (member → team_admin or vice versa), the historical audit entries do not retroactively shift.

**Why**: The audit log is the source of truth for "what happened". A subsequent role change shouldn't rewrite history.

**Implementation**: at INSERT time the role is taken from the `AuthenticatedCaller` (which was sourced from the OAuth introspection at the start of the request) — not re-queried from the `team_memberships`/`users` tables. There's no `users.role` column anyway in 008 because role is per-OAuth-token, not per-user.

## diff_summary format details (Q2 = A)

**Decision**: Comma-separated string of field names with explicit canonical ordering (FR-016). Canonical order:

```text
title, description, due_date, status, shared_with
```

For `created`, only fields actually supplied (i.e., distinguishable from absent) are listed. For `edited`, only fields whose values **changed** are listed. For `deleted`, `diff_summary = ""` (empty). For `shared`/`unshared`, `diff_summary = "sharee=<user_id>"`.

**No pre-edit values stored**: Q2 = A explicitly excludes them. The audit log answers "who changed which field when", not "what was the old value".

**Why canonical ordering**: makes audit-entry comparisons in tests deterministic and the UI rendering consistent.

## Project layout: `src/task_sharing/` package

**Decision**: New top-level package `src/task_sharing/` parallel to the existing six. Tests under `tests/task_sharing/`.

**Rationale**: 008's invariant set is distinct enough that sharing a package with 007 would entangle them (different visibility model, different audit semantics, different perf SLA). Re-confirms the case for a future `src/_common/` extraction: this is the **seventh** near-identical-shape package, and the duplication is now uncomfortable. The plan continues to flag it as overdue.

## What is intentionally NOT researched

These are out of scope per the spec's Out of Scope and Assumptions:

- OAuth 2.0 token issuance / refresh / revocation.
- Tamper-detectable audit log (chained-hash). For that pattern, see feature 005.
- Forensic pre-edit-value reconstruction (Q2 = A excludes it).
- Multi-team membership; cross-team sharing; group/link sharing.
- Listing / search / pagination across tasks (no `GET /tasks` in v1).
- Notifications, comments, attachments, tags, priorities, subtasks, time tracking, recurring tasks.
- Production-scale performance beyond the developer-machine smoke test (real RDBMS is recommended for production).
- Constant-time response (timing-side-channel defence).
- Member onboarding and sign-in flows.
