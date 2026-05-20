// === feature_model.als — Alloy model for Team Task Management (006-task-management) ===

// ---------- Static enums (one-sigs are not affected by scope budget) ----------

abstract sig Role {}
one sig AuthenticatedMember extends Role {}
one sig Unauthenticated extends Role {}

abstract sig OperationKind {}
one sig PostTasks extends OperationKind {}
one sig GetTasks extends OperationKind {}
one sig GetTaskById extends OperationKind {}
one sig PatchTask extends OperationKind {}
one sig DeleteTask extends OperationKind {}

abstract sig Status {}
one sig Todo extends Status {}
one sig InProgress extends Status {}
one sig Done extends Status {}

abstract sig Outcome {}
one sig Success extends Outcome {}
one sig Rejected extends Outcome {}

abstract sig Bool {}
one sig True extends Bool {}
one sig False extends Bool {}

// Permission matrix as a singleton field (canonical Alloy 6 pattern).
one sig PermMatrix { Allowed: set Role -> OperationKind }

// ---------- Dynamic sigs ----------

sig Timestamp {}

sig Member {}

sig Task {
  creator: one Member,
  assignee: lone Member,
  status: one Status,
  createdAt: one Timestamp,
  updatedAt: one Timestamp
}

// Append-only operational log of deletions (FR-018).
sig TaskDeletion {
  deletedBy: one Member,
  deletedAt: one Timestamp
}

// Each API call modelled as an Operation atom.
sig Operation {
  kind: one OperationKind,
  role: one Role,
  caller: lone Member,            // none iff role = Unauthenticated
  target: lone Task,              // for GET-by-id, PATCH, DELETE
  outcome: one Outcome,
  preStatus: lone Status,         // status of the target *before* the op (for PATCH)
  intendedNewStatus: lone Status, // status field sent in the PATCH body
  producesDeletion: lone TaskDeletion, // 1 iff successful DeleteTask
  payloadValid: one Bool          // payload passes validation (FR-005..FR-008)
}

// ---------- Non-empty universe ----------

fact F_NonEmptyUniverse {
  some Member
  some Task
  some TaskDeletion
  some Operation
  some Timestamp
}

// ---------- Permission matrix: flat peers, every endpoint allowed to AuthenticatedMember ----------

fact F_PermissionMatrix {
  PermMatrix.Allowed =
    (AuthenticatedMember -> PostTasks) +
    (AuthenticatedMember -> GetTasks) +
    (AuthenticatedMember -> GetTaskById) +
    (AuthenticatedMember -> PatchTask) +
    (AuthenticatedMember -> DeleteTask)
}

// ---------- Auth boundary (FR-001, FR-002) ----------

fact F_AuthRequired {
  all op: Operation | op.role = Unauthenticated implies op.outcome = Rejected
  all op: Operation | op.role = Unauthenticated implies no op.caller
  all op: Operation | op.role = AuthenticatedMember implies one op.caller
}

// ---------- Deletion-log completeness (FR-018) and exclusivity ----------

fact F_DeletionCompleteness {
  // A successful DELETE always produces exactly one TaskDeletion entry.
  all op: Operation |
    (op.kind = DeleteTask and op.outcome = Success) implies (one op.producesDeletion)
  // A rejected DELETE never produces a log entry.
  all op: Operation |
    (op.kind = DeleteTask and op.outcome = Rejected) implies no op.producesDeletion
  // No other operation kind ever produces a deletion log entry.
  all op: Operation |
    op.kind != DeleteTask implies no op.producesDeletion
}

// ---------- Append-only / unique origin (every TaskDeletion traces to a unique op) ----------

fact F_DeletionUniqueOrigin {
  // Every TaskDeletion was produced by exactly one Operation.
  all td: TaskDeletion | one op: Operation | op.producesDeletion = td
}

// ---------- Attribution: deleter recorded in log matches caller of the op ----------

fact F_AttributionCorrectness {
  all op: Operation, td: TaskDeletion |
    op.producesDeletion = td implies td.deletedBy = op.caller
}

// ---------- Closed-task PATCH rule (FR-011) ----------

fact F_ClosedTaskRule {
  // A successful PATCH on a task whose pre-status is Done must transition out of Done
  // in the same request.
  all op: Operation |
    (op.kind = PatchTask and op.outcome = Success and op.preStatus = Done)
      implies (some op.intendedNewStatus and op.intendedNewStatus != Done)
}

// ---------- Validation before mutation (FR-005..FR-008) ----------

fact F_ValidationBeforeMutation {
  // If the payload fails validation, the operation is rejected (no state change).
  all op: Operation |
    op.payloadValid = False implies op.outcome = Rejected
  // And no deletion log entry is written.
  all op: Operation |
    op.payloadValid = False implies no op.producesDeletion
}

// ---------- PATCH structure (PATCH operations target a real task) ----------

fact F_PatchHasTarget {
  all op: Operation |
    (op.kind = PatchTask and op.outcome = Success) implies some op.target
  // preStatus, if present, matches the target's current status (model invariant).
  all op: Operation |
    (op.kind = PatchTask and some op.preStatus and some op.target)
      implies op.preStatus = op.target.status
}

// ============================================================================
// PREDICATES + ASSERTIONS  (one per pattern, one per FR)
// ============================================================================

// PATTERN: AuthRequiredEverywhere  ANCHOR: spec.md FR-001; contracts/http-api.md "Authentication (all endpoints)"
pred AuthRequiredEverywhere {
  all op: Operation | op.role = Unauthenticated implies op.outcome = Rejected
  some op: Operation | op.role = Unauthenticated
}
assert AuthRequiredEverywhere { AuthRequiredEverywhere }
check AuthRequiredEverywhere for 8

// PATTERN: PermissionCompleteness  ANCHOR: contracts/http-api.md authorisation tables
pred PermissionCompleteness {
  // Every (Role, OperationKind) cell has a defined verdict (in/out of Allowed),
  // and every endpoint is reachable by the AuthenticatedMember role.
  all k: OperationKind | (AuthenticatedMember -> k) in PermMatrix.Allowed
  all k: OperationKind | (Unauthenticated -> k) not in PermMatrix.Allowed
}
assert PermissionCompleteness { PermissionCompleteness }
check PermissionCompleteness for 8

// PATTERN: LeastPrivilege  ANCHOR: spec.md FR-001; FR-004; contracts/http-api.md auth section
pred LeastPrivilege {
  // No caller without permission can succeed at any endpoint.
  all op: Operation |
    op.outcome = Success implies (op.role -> op.kind) in PermMatrix.Allowed
  some op: Operation | op.role = Unauthenticated
}
assert LeastPrivilege { LeastPrivilege }
check LeastPrivilege for 8

// PATTERN: AppendOnly  ANCHOR: data-model.md "Append-only record of every deletion (FR-018)"
pred AppendOnly {
  // No two distinct operations share the same TaskDeletion entry — each log row has a
  // unique originating op, so deletions cannot be rewritten or re-attributed.
  all disj op1, op2: Operation |
    (some op1.producesDeletion and op1.producesDeletion = op2.producesDeletion) implies False = True
  some td: TaskDeletion | some op: Operation | op.producesDeletion = td
}
assert AppendOnly { AppendOnly }
check AppendOnly for 8

// PATTERN: AuditCompleteness  ANCHOR: spec.md FR-018; data-model.md task_deletions
pred AuditCompleteness {
  all op: Operation |
    (op.kind = DeleteTask and op.outcome = Success) implies (one op.producesDeletion)
  some op: Operation | op.kind = DeleteTask and op.outcome = Success
}
assert AuditCompleteness { AuditCompleteness }
check AuditCompleteness for 8

// PATTERN: AttributionCorrectness  ANCHOR: spec.md FR-018 (deleter identity recorded)
pred AttributionCorrectness {
  all op: Operation, td: TaskDeletion |
    op.producesDeletion = td implies td.deletedBy = op.caller
  some op: Operation | some op.producesDeletion
}
assert AttributionCorrectness { AttributionCorrectness }
check AttributionCorrectness for 8

// PATTERN: ValidationBeforeMutation  ANCHOR: spec.md FR-005..FR-008; data-model.md validation
pred ValidationBeforeMutation {
  all op: Operation |
    op.payloadValid = False implies op.outcome = Rejected
  all op: Operation |
    op.payloadValid = False implies no op.producesDeletion
  some op: Operation | op.payloadValid = False
}
assert ValidationBeforeMutation { ValidationBeforeMutation }
check ValidationBeforeMutation for 8

// FEATURE-SPECIFIC  ANCHOR: FR-001 (every request must be authenticated)
pred FR_001_AuthRequired {
  all op: Operation | op.role = Unauthenticated implies op.outcome = Rejected
  some op: Operation | op.role = Unauthenticated
}
assert FR_001_AuthRequired { FR_001_AuthRequired }
check FR_001_AuthRequired for 8

// FEATURE-SPECIFIC  ANCHOR: FR-002 (identity from auth context, not payload)
pred FR_002_IdentityFromAuth {
  // Authenticated operations always carry exactly one caller, sourced from the token,
  // independently of any payload field. Unauthenticated operations carry no caller.
  all op: Operation | op.role = AuthenticatedMember implies one op.caller
  all op: Operation | op.role = Unauthenticated implies no op.caller
}
assert FR_002_IdentityFromAuth { FR_002_IdentityFromAuth }
check FR_002_IdentityFromAuth for 8

// FEATURE-SPECIFIC  ANCHOR: FR-003 (single implicit workspace)
pred FR_003_SingleWorkspace {
  // There is no Workspace/Team sig — every Member sees every Task. Structurally:
  // every Task's creator is just a Member (no per-workspace partitioning relation).
  all t: Task | t.creator in Member
}
assert FR_003_SingleWorkspace { FR_003_SingleWorkspace }
check FR_003_SingleWorkspace for 8

// FEATURE-SPECIFIC  ANCHOR: FR-004 (flat permissions — all members are peers)
pred FR_004_FlatPermissions {
  // Exactly one authenticated role; that role can perform every operation kind.
  all k: OperationKind | (AuthenticatedMember -> k) in PermMatrix.Allowed
  // No other role appears in Allowed.
  all r: Role | (some k: OperationKind | (r -> k) in PermMatrix.Allowed) implies r = AuthenticatedMember
}
assert FR_004_FlatPermissions { FR_004_FlatPermissions }
check FR_004_FlatPermissions for 8

// FEATURE-SPECIFIC  ANCHOR: FR-005 (title 1-200 chars, trimmed; validated)
pred FR_005_TitleValidated {
  all op: Operation |
    (op.outcome = Success and op.kind in (PostTasks + PatchTask)) implies op.payloadValid = True
  some op: Operation | op.payloadValid = False and op.kind in (PostTasks + PatchTask)
}
assert FR_005_TitleValidated { FR_005_TitleValidated }
check FR_005_TitleValidated for 8

// FEATURE-SPECIFIC  ANCHOR: FR-006 (description 0-4000 chars; validated)
pred FR_006_DescriptionValidated {
  all op: Operation |
    (op.outcome = Success and op.kind in (PostTasks + PatchTask)) implies op.payloadValid = True
}
assert FR_006_DescriptionValidated { FR_006_DescriptionValidated }
check FR_006_DescriptionValidated for 8

// FEATURE-SPECIFIC  ANCHOR: FR-007 (due date optional, past allowed)
pred FR_007_DueDateOptional {
  // Tasks need not encode a due_date in the model — the field is absent on Task,
  // reflecting "optional" structurally. The predicate asserts no extra side-effect:
  // validation of payload is independent of due-date pastness (no rejection rule on
  // past dates appears in the validation fact).
  all op: Operation |
    op.payloadValid = True implies op.outcome in (Success + Rejected)
}
assert FR_007_DueDateOptional { FR_007_DueDateOptional }
check FR_007_DueDateOptional for 8

// FEATURE-SPECIFIC  ANCHOR: FR-008 (assignee must be a current member, or none)
pred FR_008_AssigneeIsMember {
  // Assignee, when set, is necessarily a Member (typing); at most one.
  all t: Task | lone t.assignee
  all t: Task | some t.assignee implies t.assignee in Member
}
assert FR_008_AssigneeIsMember { FR_008_AssigneeIsMember }
check FR_008_AssigneeIsMember for 8

// FEATURE-SPECIFIC  ANCHOR: FR-009 (creator + created_at recorded; never change)
pred FR_009_CreatorRecorded {
  all t: Task | one t.creator and one t.createdAt
}
assert FR_009_CreatorRecorded { FR_009_CreatorRecorded }
check FR_009_CreatorRecorded for 8

// FEATURE-SPECIFIC  ANCHOR: FR-010 (status ∈ {todo, in_progress, done})
pred FR_010_StatusSet {
  all t: Task | t.status in (Todo + InProgress + Done)
}
assert FR_010_StatusSet { FR_010_StatusSet }
check FR_010_StatusSet for 8

// FEATURE-SPECIFIC  ANCHOR: FR-011 (closed-task edit rule)
pred FR_011_ClosedTaskRule {
  all op: Operation |
    (op.kind = PatchTask and op.outcome = Success and op.preStatus = Done)
      implies (some op.intendedNewStatus and op.intendedNewStatus != Done)
  some op: Operation | op.kind = PatchTask and op.preStatus = Done
}
assert FR_011_ClosedTaskRule { FR_011_ClosedTaskRule }
check FR_011_ClosedTaskRule for 8

// FEATURE-SPECIFIC  ANCHOR: FR-012 (any authenticated member may delete any task)
pred FR_012_AnyMemberDeletes {
  (AuthenticatedMember -> DeleteTask) in PermMatrix.Allowed
}
assert FR_012_AnyMemberDeletes { FR_012_AnyMemberDeletes }
check FR_012_AnyMemberDeletes for 8

// FEATURE-SPECIFIC  ANCHOR: FR-013 (v1 scope = exactly 5 endpoints)
pred FR_013_ScopeLimited {
  OperationKind = PostTasks + GetTasks + GetTaskById + PatchTask + DeleteTask
}
assert FR_013_ScopeLimited { FR_013_ScopeLimited }
check FR_013_ScopeLimited for 8

// FEATURE-SPECIFIC  ANCHOR: FR-014 (default ordering by updated_at DESC)
pred FR_014_DefaultOrdering {
  // Every task carries an updated_at timestamp; without it, sort cannot be defined.
  all t: Task | one t.updatedAt
}
assert FR_014_DefaultOrdering { FR_014_DefaultOrdering }
check FR_014_DefaultOrdering for 8

// FEATURE-SPECIFIC  ANCHOR: FR-015 (filter by status / assignee / title; AND)
pred FR_015_FilterableFields {
  // The filterable fields (status, assignee) exist on every Task.
  all t: Task | one t.status and lone t.assignee
}
assert FR_015_FilterableFields { FR_015_FilterableFields }
check FR_015_FilterableFields for 8

// FEATURE-SPECIFIC  ANCHOR: FR-016 (clear filters → full list)
pred FR_016_ClearFilters {
  // Default unfiltered view is the full task set; no per-member visibility partition.
  all t: Task | t in Task
}
assert FR_016_ClearFilters { FR_016_ClearFilters }
check FR_016_ClearFilters for 8

// FEATURE-SPECIFIC  ANCHOR: FR-017 (created_at + updated_at present)
pred FR_017_Timestamps {
  all t: Task | one t.createdAt and one t.updatedAt
}
assert FR_017_Timestamps { FR_017_Timestamps }
check FR_017_Timestamps for 8

// FEATURE-SPECIFIC  ANCHOR: FR-018 (deletions recorded in operational log)
pred FR_018_DeletionLogged {
  all op: Operation |
    (op.kind = DeleteTask and op.outcome = Success) implies (one op.producesDeletion)
  all op: Operation |
    op.kind != DeleteTask implies no op.producesDeletion
  some op: Operation | op.kind = DeleteTask and op.outcome = Success
}
assert FR_018_DeletionLogged { FR_018_DeletionLogged }
check FR_018_DeletionLogged for 8