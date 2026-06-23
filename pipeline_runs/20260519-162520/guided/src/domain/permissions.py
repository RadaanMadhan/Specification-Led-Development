"""
Role-based permission matrix.

PATTERN: LeastPrivilege — only the explicitly allowed pairs exist.
PATTERN: PermissionCompleteness — every Role x OperationKind cell is defined.

Implements FR-007: LeastPrivilege enforcement via the authorization matrix
from contracts/http-api.md.
"""

from __future__ import annotations

from src.domain.enums import OperationKind, Role
from src.domain.invariants import InvariantViolation


# PATTERN: LeastPrivilege — define the exact set of allowed (role, operation) pairs
# PATTERN: PermissionCompleteness — exactly 12 allowed cells (5 customer + 7 admin)
_ALLOWED_PAIRS: frozenset[tuple[Role, OperationKind]] = frozenset(
    [
        # Customer: 5 allowed operations
        (Role.CUSTOMER, OperationKind.POST_TRANSFERS),
        (Role.CUSTOMER, OperationKind.GET_TRANSFER_BY_ID),
        (Role.CUSTOMER, OperationKind.GET_BALANCE),
        (Role.CUSTOMER, OperationKind.GET_TRANSACTIONS),
        (Role.CUSTOMER, OperationKind.POST_STEP_UP),
        # Admin: 7 allowed operations
        (Role.ADMIN, OperationKind.POST_TRANSFERS),
        (Role.ADMIN, OperationKind.GET_TRANSFER_BY_ID),
        (Role.ADMIN, OperationKind.POST_REVERSE),
        (Role.ADMIN, OperationKind.GET_BALANCE),
        (Role.ADMIN, OperationKind.GET_TRANSACTIONS),
        (Role.ADMIN, OperationKind.GET_AUDIT_ENTRIES),
        (Role.ADMIN, OperationKind.GET_AUDIT_VERIFY),
    ]
)

# Verify completeness at import time: exactly 12 allowed pairs
assert len(_ALLOWED_PAIRS) == 12, (
    f"F_PermissionCompleteness: expected 12 allowed pairs, got {len(_ALLOWED_PAIRS)}"
)


def is_operation_allowed(roles: list[str], operation: OperationKind) -> bool:
    """
    Check whether any of the user's roles permits the given operation.

    PATTERN: LeastPrivilege — reject unless explicitly allowed.
    """
    for role_str in roles:
        try:
            role = Role(role_str)
        except ValueError:
            continue
        if (role, operation) in _ALLOWED_PAIRS:
            return True
    return False


def require_permission(roles: list[str], operation: OperationKind) -> None:
    """
    Raise if the user lacks permission for the operation.

    PATTERN: LeastPrivilege — reject unauthenticated/unauthorized requests
    before business logic.
    """
    if not is_operation_allowed(roles, operation):
        raise InvariantViolation(
            "F_LeastPrivilege",
            f"None of roles {roles} is permitted to perform {operation.value}.",
        )
