from __future__ import annotations

import threading
from abc import ABC, abstractmethod
from typing import Optional

from banking.domain.models import Account


class AccountRepository(ABC):
    @abstractmethod
    def save(self, account: Account) -> Account:
        ...

    @abstractmethod
    def find_by_id(self, account_id: str) -> Optional[Account]:
        ...

    @abstractmethod
    def find_by_owner(self, owner: str) -> list[Account]:
        ...

    @abstractmethod
    def list_all(self) -> list[Account]:
        ...


class InMemoryAccountRepository(AccountRepository):
    def __init__(self) -> None:
        self._store: dict[str, Account] = {}
        self._lock = threading.Lock()

    def save(self, account: Account) -> Account:
        with self._lock:
            self._store[account.id] = account.model_copy()
        return account

    def find_by_id(self, account_id: str) -> Optional[Account]:
        with self._lock:
            acct = self._store.get(account_id)
            return acct.model_copy() if acct else None

    def find_by_owner(self, owner: str) -> list[Account]:
        with self._lock:
            return [
                a.model_copy() for a in self._store.values() if a.owner == owner
            ]

    def list_all(self) -> list[Account]:
        with self._lock:
            return [a.model_copy() for a in self._store.values()]
