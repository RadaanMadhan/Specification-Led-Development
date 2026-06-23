from __future__ import annotations

import threading
from abc import ABC, abstractmethod
from typing import Optional

from banking.domain.models import Transaction


class TransactionRepository(ABC):
    @abstractmethod
    def save(self, transaction: Transaction) -> Transaction:
        ...

    @abstractmethod
    def find_by_id(self, transaction_id: str) -> Optional[Transaction]:
        ...

    @abstractmethod
    def find_by_account(self, account_id: str) -> list[Transaction]:
        ...

    @abstractmethod
    def list_all(self) -> list[Transaction]:
        ...


class InMemoryTransactionRepository(TransactionRepository):
    def __init__(self) -> None:
        self._store: dict[str, Transaction] = {}
        self._lock = threading.Lock()

    def save(self, transaction: Transaction) -> Transaction:
        with self._lock:
            self._store[transaction.id] = transaction.model_copy()
        return transaction

    def find_by_id(self, transaction_id: str) -> Optional[Transaction]:
        with self._lock:
            txn = self._store.get(transaction_id)
            return txn.model_copy() if txn else None

    def find_by_account(self, account_id: str) -> list[Transaction]:
        with self._lock:
            return [
                t.model_copy()
                for t in self._store.values()
                if t.source_account_id == account_id
                or t.destination_account_id == account_id
            ]

    def list_all(self) -> list[Transaction]:
        with self._lock:
            return [t.model_copy() for t in self._store.values()]
