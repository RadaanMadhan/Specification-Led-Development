from __future__ import annotations

from banking.domain.models import AuditAction, AuditEntry
from banking.repositories.audit_repository import AuditRepository


class AuditService:
    def __init__(self, audit_repo: AuditRepository) -> None:
        self._audit_repo = audit_repo

    def log(
        self,
        action: AuditAction,
        actor: str,
        resource_type: str,
        resource_id: str,
        details: dict | None = None,
    ) -> AuditEntry:
        entry = AuditEntry(
            action=action,
            actor=actor,
            resource_type=resource_type,
            resource_id=resource_id,
            details=details or {},
        )
        return self._audit_repo.append(entry)

    def get_audit_trail(self, resource_type: str, resource_id: str) -> list[AuditEntry]:
        return self._audit_repo.find_by_resource(resource_type, resource_id)

    def get_actor_history(self, actor: str) -> list[AuditEntry]:
        return self._audit_repo.find_by_actor(actor)

    def get_full_log(self) -> list[AuditEntry]:
        return self._audit_repo.list_all()
