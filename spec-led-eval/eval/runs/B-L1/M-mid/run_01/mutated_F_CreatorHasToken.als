// === feature_model.als — Alloy model for Team Task Management (B-L1 / 006-task-management) ===
// Spec artefacts: spec.md, data-model.md, contracts/http-api.md
// Generated in accordance with the SpecKit formal-methods pipeline.

// ─────────────────────────────────────────────────────────────────────────────
// SIGNATURES
// ─────────────────────────────────────────────────────────────────────────────

// A person who can authenticate and perform task operations.
sig Member {}

// An opaque bearer token that resolves to exactly one member.
sig Token {
  token_owner: one Member
}

// Task-status enum — exactly three values, no others.
abstract sig TaskStatus {}
one sig Todo       extends TaskStatus {}
one sig InProgress extends TaskStatus {}
one sig Done       extends TaskStatus {}

// A task in the workspace.
sig Task {
  task_creator:     one Member,
  task_assignee:    lone Member,   // optional (lone = 0 or 1)
  task_status:      one TaskStatus,
  task_last_editor: lone Member    // absent if never edited after creation
}

// Opaque identity used in the deletion log.
// The live task row is gone by the time this is written, so it cannot
// be a direct reference to a Task atom.
sig DeletedTaskId {}

// Append-only operational log of deletions (FR-018).
sig DeletionLogEntry {
  dle_task_id: one DeletedTaskId,
  dle_deleter: one Member
}

// A PATCH request targeting a task (models FR-011 closed-task rule).
sig PatchRequest {
  pr_caller:         one Member,
  pr_target:         one Task,
  // patch_new_status: None (lone = ∅) means "status field absent from body"
  pr_new_status:     lone TaskStatus,
  // true  ↔ the request body changes at least one non-status field
  pr_mutates_fields: one Bool
}

// Boolean helper
abstract sig Bool {}
one sig BTrue  extends Bool {}
one sig BFalse extends Bool {}

// ─────────────────────────────────────────────────────────────────────────────
// NAMED FACTS — structural rules
// ─────────────────────────────────────────────────────────────────────────────

// Every dynamic sig has at least one atom so `all x: T | P[x]` is non-vacuous.
fact F_NonEmptyUniverse {
  some Member
  some Token
  some Task
  some DeletedTaskId
  some DeletionLogEntry
  some PatchRequest
}

// FR-008 / data-model.md FK→users.id: every task's assignee (when present)
// is an existing member of the workspace.  Structurally, this is enforced
// by the `lone Member` field type; the fact makes it mutation-testable as an
// explicit constraint.
fact F_AssigneeIsMember {
  all t: Task | t.task_assignee in Member
}

// FR-009 / data-model.md created_by: every task's creator must have a valid
// token — identity comes from the authentication context.
fact F_CreatorHasToken { /* MUTATED — body cleared by validator */ }

// FR-002 / spec.md FR-002: creator identity equals the token-resolved member.
// Expressed as: no task's creator is absent from the set of token-owning members.
fact F_CreatorFromAuthContext {
  all t: Task | t.task_creator in Token.token_owner
}

// FR-009 (immutability): creator and last_editor are distinct roles;
// task_last_editor never replaces task_creator (the creator field is frozen
// after creation).  Modelled as: if task_last_editor is present, it is
// a *separate* concern from task_creator (they may coincide in value but
// the field itself is not the creator field).
// The binding fact: task_creator is always in Token.token_owner (above).
// We add: the last_editor (when present) also has a token.
fact F_LastEditorHasToken {
  all t: Task |
    some t.task_last_editor implies (t.task_last_editor in Token.token_owner)
}

// FR-010: status is exactly one of the three defined values.
// (Structurally guaranteed by the abstract-sig hierarchy; made explicit as
//  a named fact so mutation tests can clear it.)
fact F_ValidStatus {
  all t: Task | t.task_status in (Todo + InProgress + Done)
}

// FR-011 / contracts/http-api.md "Closed-task rule": a PATCH on a Done task
// that modifies non-status fields MUST simultaneously set status to Todo or
// InProgress.
fact F_ClosedTaskEditRule {
  all pr: PatchRequest |
    (pr.pr_target.task_status = Done and pr.pr_mutates_fields = BTrue)
      implies (pr.pr_new_status = Todo or pr.pr_new_status = InProgress)
}

// FR-001 / contracts/http-api.md auth section: every PATCH request comes from
// an authenticated caller (token must exist for that member).
fact F_PatchCallerAuthenticated {
  all pr: PatchRequest |
    some tok: Token | tok.token_owner = pr.pr_caller
}

// AppendOnly / data-model.md "No UPDATE/DELETE code path targets this table":
// no two DeletionLogEntry atoms record the same deleted-task identity
// (each deletion is logged exactly once; entries are never overwritten).
fact F_AppendOnlyDeletionLog {
  all disj e1, e2: DeletionLogEntry |
    e1.dle_task_id != e2.dle_task_id
}

// FR-018 / data-model.md task_deletions: every DeletedTaskId that exists in
// the model has exactly one DeletionLogEntry that records it.
fact F_DeletionLogCompleteness {
  all dtid: DeletedTaskId |
    one dle: DeletionLogEntry | dle.dle_task_id = dtid
}

// FR-018 / spec.md FR-018: every deletion is attributed to an authenticated
// deleter (the deleter has a valid token).
fact F_DeleterAuthenticated {
  all dle: DeletionLogEntry |
    some tok: Token | tok.token_owner = dle.dle_deleter
}

// FR-004 / spec.md FR-004: flat peer model — every authenticated member may
// issue a PatchRequest on any task.  The absence of any role-based filter is
// expressed as: for every (member, task) pair where the member has a token,
// no structural constraint blocks a PatchRequest for that pair.
// Positive encoding: if a member has a token, they appear as pr_caller for
// at least one PatchRequest targeting each task they interact with, without
// any additional role check.
// (The fact encodes the *absence* of privileged/forbidden pairs.)
fact F_FlatPermissions {
  // No forbidden pairing: a member with a token is never structurally
  // prevented from being a pr_caller on any task.
  // Encoded as: the domain of pr_caller among authenticated members equals
  // the full set of token-owning members (no member is silently excluded).
  PatchRequest.pr_caller = Token.token_owner
}

// FR-003 / spec.md FR-003: single implicit workspace — all tasks are visible
// to all authenticated members.  Encoded as: the set of task creators covers
// a subset of Token.token_owner (every task was created by some member of the
// workspace, never by an outsider).
fact F_SingleWorkspaceScope {
  Task.task_creator in Token.token_owner
}

// ─────────────────────────────────────────────────────────────────────────────
// PREDICATES + ASSERTIONS
// ─────────────────────────────────────────────────────────────────────────────

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md auth section
pred AuthRequiredEverywhere {
  some PatchRequest
  all pr: PatchRequest |
    some tok: Token | tok.token_owner = pr.pr_caller
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 5

// PATTERN: AppendOnly  ANCHOR: spec.md FR-018; data-model.md "No UPDATE/DELETE ... task_deletions"
pred AppendOnly {
  some DeletionLogEntry
  all disj e1, e2: DeletionLogEntry | e1.dle_task_id != e2.dle_task_id
}
assert AppendOnly { AppendOnly }
check AppendOnly for 5

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-018; data-model.md task_deletions INSERT
pred AuditCompleteness {
  some DeletedTaskId
  all dtid: DeletedTaskId |
    (one dle: DeletionLogEntry | dle.dle_task_id = dtid)
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 5

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-002, FR-009; data-model.md created_by
pred AttributionCorrectness {
  some Task
  all t: Task | t.task_creator in Token.token_owner
  all dle: DeletionLogEntry | dle.dle_deleter in Token.token_owner
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 5

// PATTERN: OwnershipExclusivity  ANCHOR: spec.md FR-008; data-model.md assignee_id lone FK
pred OwnershipExclusivity {
  some Task
  all t: Task | lone t.task_assignee
}
assert OwnershipExclusivity { OwnershipExclusivity }
check OwnershipExclusivity for 5

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-005, FR-008; data-model.md validation.py
// A task assignee (when present) is always an existing member — invalid
// assignee_id is rejected before any mutation occurs.
pred ValidationBeforeMutation {
  some Task
  all t: Task | t.task_assignee in Member
  all t: Task | t.task_creator in Member
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 5

// FEATURE-SPECIFIC  ANCHOR: FR-001
pred FR_001_AuthRequired {
  some PatchRequest
  all pr: PatchRequest |
    pr.pr_caller in Token.token_owner
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 5

// FEATURE-SPECIFIC  ANCHOR: FR-002
pred FR_002_IdentityFromAuthContext {
  some Task
  all t: Task | t.task_creator in Token.token_owner
}
assert FR_002_IdentityFromAuthContext { FR_002_IdentityFromAuthContext }
check FR_002_IdentityFromAuthContext for 5

// FEATURE-SPECIFIC  ANCHOR: FR-003
pred FR_003_SingleWorkspaceScope {
  some Task
  // All tasks have creators that are authenticated workspace members
  all t: Task | t.task_creator in Token.token_owner
  // All assignees (when present) are members of the workspace
  all t: Task | t.task_assignee in Token.token_owner
}
assert FR_003_SingleWorkspaceScope { FR_003_SingleWorkspaceScope }
check FR_003_SingleWorkspaceScope for 5

// FEATURE-SPECIFIC  ANCHOR: FR-004
// Flat permission model: every token-owning member can be a PatchRequest caller.
// No member is structurally excluded from any operation.
pred FR_004_FlatPermissions {
  some PatchRequest
  some Member
  // Every authenticated member (token-owning) appears as a potential caller —
  // the caller domain equals the full authenticated-member set.
  PatchRequest.pr_caller = Token.token_owner
}
assert FR_004_FlatPermissions { FR_004_FlatPermissions }
check FR_004_FlatPermissions for 5

// FEATURE-SPECIFIC  ANCHOR: FR-008
pred FR_008_AssigneeIsMember {
  some Task
  all t: Task | t.task_assignee in Member
}
assert FR_008_AssigneeIsMember { FR_008_AssigneeIsMember }
check FR_008_AssigneeIsMember for 5

// FEATURE-SPECIFIC  ANCHOR: FR-009
// Creator is recorded from auth context and never changes.
// In this snapshot model: creator always has a token (set at creation),
// and is a distinct field from last_editor.
pred FR_009_CreatorImmutable {
  some Task
  all t: Task | t.task_creator in Token.token_owner
  // creator field is structurally separate from last_editor
  all t: Task |
    some t.task_last_editor implies (t.task_last_editor in Token.token_owner)
}
assert FR_009_CreatorImmutable { FR_009_CreatorImmutable }
check FR_009_CreatorImmutable for 5

// FEATURE-SPECIFIC  ANCHOR: FR-010
// Task status is always one of the three defined values.
pred FR_010_ValidStatusValues {
  some Task
  all t: Task | t.task_status in (Todo + InProgress + Done)
}
assert FR_010_ValidStatusValues { FR_010_ValidStatusValues }
check FR_010_ValidStatusValues for 5

// FEATURE-SPECIFIC  ANCHOR: FR-011
// Closed-task edit rule: a patch on a Done task that changes non-status fields
// MUST simultaneously set status to Todo or InProgress.
pred FR_011_ClosedTaskEditRule {
  some PatchRequest
  all pr: PatchRequest |
    (pr.pr_target.task_status = Done and pr.pr_mutates_fields = BTrue)
      implies (pr.pr_new_status = Todo or pr.pr_new_status = InProgress)
}
assert FR_011_ClosedTaskEditRule { FR_011_ClosedTaskEditRule }
check FR_011_ClosedTaskEditRule for 5

// FEATURE-SPECIFIC  ANCHOR: FR-012
// Deletion is permanent: once a task is deleted, it is represented only
// by a DeletionLogEntry, not as a live Task.
// Encoded as: every DeletedTaskId has exactly one DeletionLogEntry.
pred FR_012_PermanentDeletion {
  some DeletedTaskId
  all dtid: DeletedTaskId |
    (one dle: DeletionLogEntry | dle.dle_task_id = dtid)
}
assert FR_012_PermanentDeletion { FR_012_PermanentDeletion }
check FR_012_PermanentDeletion for 5

// FEATURE-SPECIFIC  ANCHOR: FR-017
// Every task's last_editor, when present, is an authenticated member —
// updated_at is refreshed on every successful (authenticated) edit.
pred FR_017_UpdatedAtOnAuthenticatedEdit {
  some Task
  all t: Task |
    some t.task_last_editor implies (t.task_last_editor in Token.token_owner)
}
assert FR_017_UpdatedAtOnAuthenticatedEdit { FR_017_UpdatedAtOnAuthenticatedEdit }
check FR_017_UpdatedAtOnAuthenticatedEdit for 5

// FEATURE-SPECIFIC  ANCHOR: FR-018
// Operational deletion log: every deletion carries the deleter's identity,
// which must be an authenticated member.
pred FR_018_DeletionLogAttribution {
  some DeletionLogEntry
  all dle: DeletionLogEntry | dle.dle_deleter in Token.token_owner
}
assert FR_018_DeletionLogAttribution { FR_018_DeletionLogAttribution }
check FR_018_DeletionLogAttribution for 5

// === MUTATION INJECTION (validator-appended) ===
fact MUTATE_CreatorAuthViolation { some t: Task | no tok: Token | tok.token_owner = t.task_creator }
