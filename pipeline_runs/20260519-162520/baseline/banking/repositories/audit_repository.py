from __future__ import annotations

import threading
from abc import ABC, abstractmethod

from banking.domain.models import AuditEntry


class AuditRepository(ABC):
    """Append-only audit log storage."""

    @abstractmethod
    def append(self, entry: AuditEntry) -> AuditEntry:
        ...

    @abstractmethod
    def find_by_resource(self, resource_type: str, resource_id: str) -> list[AuditEntry]:
        ...

    @abstractmethod
    def find_by_actor(self, actor: str) -> list[AuditEntry]:
        ...

    @abstractmethod
    def list_all(self) -> list[AuditEntry]:
        ...


class InMemoryAuditRepository(AuditRepository):
    """Append-only in-memory audit log. Entries cannot be modified or deleted."""

    def __init__(self) -> None:
        self._entries: list[AuditEntry] = []
        self._lock = threading.Lock()

    def append(self, entry: AuditEntry) -> AuditEntry:
        with self._lock:
            self._entries.append(entry.model_copy())
        return entry

    def find_by_resource(self, resource_type: str, resource_id: str) -> list[AuditEntry]:
        with self._lock:
            return [
                e.model_copy()
                for e in self._entries
                if e.resource_type == resource_type and e.resource_id == resource_id
            ]

    def find_by_actor(self, actor: str) -> list[AuditEntry]:
        with self._lock:
            return [e.model_copy() for e in self._entries if e.actor == actor]

    def list_all(self) -> list[AuditEntry]:
        with self._lock:
            return [e.model_copy() for e in self._entries]
