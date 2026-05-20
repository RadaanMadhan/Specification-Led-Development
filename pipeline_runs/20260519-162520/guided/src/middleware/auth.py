"""
Authentication and authorization middleware.

PATTERN: AuthRequiredEverywhere — reject unauthenticated requests before business logic.
PATTERN: LeastPrivilege — enforce role-based permissions per operation.
PATTERN: NoInformationLeakage — return generic errors to prevent information disclosure.

Implements FR-010: Only authenticated users may perform operations.
"""

from __future__ import annotations

import uuid
from typing import Annotated

import structlog
from fastapi import Depends, HTTPException, Request, status
from jose import JWTError, jwt
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from src.config import settings
from src.domain.enums import AuthenticationStatus, OperationKind
from src.domain.invariants import InvariantViolation, check_auth_required
from src.domain.models import User
from src.domain.permissions import require_permission
from src.infrastructure.database import get_db

logger = structlog.get_logger()


def _extract_token(request: Request) -> str:
    """Extract Bearer token from Authorization header."""
    auth_header = request.headers.get("Authorization")
    if not auth_header or not auth_header.startswith("Bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing or invalid Authorization header.",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return auth_header[7:]


# PATTERN: AuthRequiredEverywhere — reject unauthenticated requests before business logic
async def get_current_user(
    request: Request,
    db: AsyncSession = Depends(get_db),
) -> User:
    """
    FastAPI dependency that authenticates the request and returns the current user.

    HARDENED: F_AuthRequiredEverywhere — only authenticated users proceed.
    """
    token = _extract_token(request)

    try:
        payload = jwt.decode(
            token,
            settings.jwt_secret_key,
            algorithms=[settings.jwt_algorithm],
        )
        user_id_str: str | None = payload.get("sub")
        if user_id_str is None:
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Invalid token: missing subject.",
            )
        user_id = uuid.UUID(user_id_str)
    except JWTError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired token.",
        )

    user = await db.get(User, user_id)
    if user is None:
        # PATTERN: NoInformationLeakage — generic 401, not "user not found"
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentication failed.",
        )

    # HARDENED: F_AuthRequiredEverywhere — verify user is authenticated
    try:
        check_auth_required(user)
    except InvariantViolation:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Account is locked or unauthenticated.",
        )

    return user


CurrentUser = Annotated[User, Depends(get_current_user)]


def require_role_permission(operation: OperationKind):
    """
    Return a FastAPI dependency that checks the user's roles against the
    permission matrix for the given operation.

    PATTERN: LeastPrivilege — only explicitly allowed role/operation pairs proceed.
    """

    async def _check(user: CurrentUser) -> User:
        try:
            require_permission(user.roles, operation)
        except InvariantViolation:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Insufficient permissions.",
            )
        return user

    return Depends(_check)
