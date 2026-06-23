from __future__ import annotations

from decimal import Decimal

from fastapi.testclient import TestClient


class TestAccountAPI:
    def test_create_account(self, client: TestClient) -> None:
        resp = client.post(
            "/api/v1/accounts",
            json={"owner": "Alice", "initial_balance": "1000.00"},
        )
        assert resp.status_code == 201
        data = resp.json()
        assert data["owner"] == "Alice"
        assert Decimal(data["balance"]) == Decimal("1000.00")
        assert data["is_frozen"] is False

    def test_get_account(self, client: TestClient) -> None:
        create_resp = client.post(
            "/api/v1/accounts",
            json={"owner": "Alice", "initial_balance": "500.00"},
        )
        account_id = create_resp.json()["id"]

        resp = client.get(f"/api/v1/accounts/{account_id}")
        assert resp.status_code == 200
        assert resp.json()["owner"] == "Alice"

    def test_get_nonexistent_account(self, client: TestClient) -> None:
        resp = client.get("/api/v1/accounts/nonexistent")
        assert resp.status_code == 404

    def test_list_accounts(self, client: TestClient) -> None:
        client.post("/api/v1/accounts", json={"owner": "Alice"})
        client.post("/api/v1/accounts", json={"owner": "Bob"})
        resp = client.get("/api/v1/accounts")
        assert resp.status_code == 200
        assert len(resp.json()) == 2

    def test_freeze_account(self, client: TestClient) -> None:
        create_resp = client.post(
            "/api/v1/accounts",
            json={"owner": "Alice", "initial_balance": "1000.00"},
        )
        account_id = create_resp.json()["id"]

        resp = client.post(
            f"/api/v1/accounts/{account_id}/freeze",
            json={"actor": "Admin"},
        )
        assert resp.status_code == 200
        assert resp.json()["is_frozen"] is True

    def test_unfreeze_account(self, client: TestClient) -> None:
        create_resp = client.post(
            "/api/v1/accounts",
            json={"owner": "Alice", "initial_balance": "1000.00"},
        )
        account_id = create_resp.json()["id"]

        client.post(f"/api/v1/accounts/{account_id}/freeze", json={"actor": "Admin"})
        resp = client.post(
            f"/api/v1/accounts/{account_id}/unfreeze",
            json={"actor": "Admin"},
        )
        assert resp.status_code == 200
        assert resp.json()["is_frozen"] is False


class TestTransferAPI:
    def _create_two_accounts(self, client: TestClient) -> tuple[str, str]:
        r1 = client.post(
            "/api/v1/accounts",
            json={"owner": "Alice", "initial_balance": "1000.00"},
        )
        r2 = client.post(
            "/api/v1/accounts",
            json={"owner": "Bob", "initial_balance": "500.00"},
        )
        return r1.json()["id"], r2.json()["id"]

    def test_successful_transfer(self, client: TestClient) -> None:
        src_id, dst_id = self._create_two_accounts(client)

        resp = client.post(
            "/api/v1/transfers",
            json={
                "source_account_id": src_id,
                "destination_account_id": dst_id,
                "amount": "200.00",
                "initiated_by": "Alice",
            },
        )
        assert resp.status_code == 201
        data = resp.json()
        assert data["status"] == "completed"
        assert Decimal(data["amount"]) == Decimal("200.00")

        # Verify balances
        src = client.get(f"/api/v1/accounts/{src_id}").json()
        dst = client.get(f"/api/v1/accounts/{dst_id}").json()
        assert Decimal(src["balance"]) == Decimal("800.00")
        assert Decimal(dst["balance"]) == Decimal("700.00")

    def test_transfer_insufficient_funds(self, client: TestClient) -> None:
        src_id, dst_id = self._create_two_accounts(client)

        resp = client.post(
            "/api/v1/transfers",
            json={
                "source_account_id": src_id,
                "destination_account_id": dst_id,
                "amount": "5000.00",
                "initiated_by": "Alice",
            },
        )
        assert resp.status_code == 422

    def test_transfer_self_rejected(self, client: TestClient) -> None:
        r = client.post(
            "/api/v1/accounts",
            json={"owner": "Alice", "initial_balance": "1000.00"},
        )
        acct_id = r.json()["id"]

        resp = client.post(
            "/api/v1/transfers",
            json={
                "source_account_id": acct_id,
                "destination_account_id": acct_id,
                "amount": "100.00",
                "initiated_by": "Alice",
            },
        )
        assert resp.status_code == 400

    def test_transfer_frozen_account_rejected(self, client: TestClient) -> None:
        src_id, dst_id = self._create_two_accounts(client)
        client.post(f"/api/v1/accounts/{src_id}/freeze", json={"actor": "Admin"})

        resp = client.post(
            "/api/v1/transfers",
            json={
                "source_account_id": src_id,
                "destination_account_id": dst_id,
                "amount": "100.00",
                "initiated_by": "Alice",
            },
        )
        assert resp.status_code == 403

    def test_list_account_transactions(self, client: TestClient) -> None:
        src_id, dst_id = self._create_two_accounts(client)
        client.post(
            "/api/v1/transfers",
            json={
                "source_account_id": src_id,
                "destination_account_id": dst_id,
                "amount": "100.00",
                "initiated_by": "Alice",
            },
        )

        resp = client.get(f"/api/v1/accounts/{src_id}/transactions")
        assert resp.status_code == 200
        assert len(resp.json()) == 1


class TestAuditAPI:
    def test_audit_log_populated(self, client: TestClient) -> None:
        client.post(
            "/api/v1/accounts",
            json={"owner": "Alice", "initial_balance": "1000.00"},
        )
        resp = client.get("/api/v1/audit")
        assert resp.status_code == 200
        entries = resp.json()
        assert len(entries) >= 1
        assert entries[0]["action"] == "account_created"
        assert entries[0]["actor"] == "Alice"

    def test_audit_trail_for_resource(self, client: TestClient) -> None:
        create_resp = client.post(
            "/api/v1/accounts",
            json={"owner": "Alice", "initial_balance": "500.00"},
        )
        account_id = create_resp.json()["id"]

        resp = client.get(f"/api/v1/audit/account/{account_id}")
        assert resp.status_code == 200
        entries = resp.json()
        assert len(entries) == 1
        assert entries[0]["resource_id"] == account_id

    def test_transfer_generates_audit_entries(self, client: TestClient) -> None:
        r1 = client.post(
            "/api/v1/accounts",
            json={"owner": "Alice", "initial_balance": "1000.00"},
        )
        r2 = client.post(
            "/api/v1/accounts",
            json={"owner": "Bob", "initial_balance": "0.00"},
        )
        src_id, dst_id = r1.json()["id"], r2.json()["id"]

        txn_resp = client.post(
            "/api/v1/transfers",
            json={
                "source_account_id": src_id,
                "destination_account_id": dst_id,
                "amount": "300.00",
                "initiated_by": "Alice",
            },
        )
        txn_id = txn_resp.json()["id"]

        resp = client.get(f"/api/v1/audit/transaction/{txn_id}")
        assert resp.status_code == 200
        entries = resp.json()
        actions = [e["action"] for e in entries]
        assert "transfer_initiated" in actions
        assert "transfer_completed" in actions
        # All entries attributed to initiator
        assert all(e["actor"] == "Alice" for e in entries)
