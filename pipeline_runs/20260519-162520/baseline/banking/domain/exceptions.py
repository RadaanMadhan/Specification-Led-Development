class BankingError(Exception):
    """Base exception for banking operations."""


class AccountNotFoundError(BankingError):
    def __init__(self, account_id: str) -> None:
        self.account_id = account_id
        super().__init__(f"Account not found: {account_id}")


class InsufficientFundsError(BankingError):
    def __init__(self, account_id: str, available: str, requested: str) -> None:
        self.account_id = account_id
        self.available = available
        self.requested = requested
        super().__init__(
            f"Insufficient funds in account {account_id}: "
            f"available={available}, requested={requested}"
        )


class SelfTransferError(BankingError):
    def __init__(self, account_id: str) -> None:
        self.account_id = account_id
        super().__init__(f"Cannot transfer to the same account: {account_id}")


class AccountFrozenError(BankingError):
    def __init__(self, account_id: str) -> None:
        self.account_id = account_id
        super().__init__(f"Account is frozen: {account_id}")


class CurrencyMismatchError(BankingError):
    def __init__(self, source_currency: str, dest_currency: str) -> None:
        self.source_currency = source_currency
        self.dest_currency = dest_currency
        super().__init__(
            f"Currency mismatch: source={source_currency}, destination={dest_currency}"
        )


class UnauthorizedError(BankingError):
    def __init__(self, message: str = "Authentication required") -> None:
        super().__init__(message)
