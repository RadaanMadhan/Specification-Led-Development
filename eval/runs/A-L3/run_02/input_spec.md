# Feature: Bank Transfer

## Functional Requirements
- **FR-001**: Authenticated users can initiate GBP transfers between their own accounts and to pre-approved third-party beneficiaries. The system must validate available balance, apply daily transfer limits (max £50,000 per user per day), and complete execution within 3 seconds under normal load. Transfers exceeding £10,000 must trigger a secondary confirmation step.
- **FR-002**: All transfer API endpoints must enforce OAuth 2.0 bearer token authentication and role-based authorisation. Unauthenticated or unauthorised requests must return HTTP 403 within 200ms. Authentication coverage must be 100% across all endpoints with zero bypass routes.
- **FR-003**: Every transfer event must be written to an append-only audit log within 5 seconds of occurrence. Log entries must include: event_id, user_id, source_account, destination_account, amount, currency, timestamp (UTC), and outcome. Logs must be retained for a minimum of 7 years to satisfy FCA compliance requirements.
- **FR-004**: The transfer service must achieve 99.9% uptime measured monthly. Recovery Time Objective (RTO) is 15 minutes and Recovery Point Objective (RPO) is 1 minute. The system must sustain 500 concurrent transfer requests without latency degradation beyond the p99 threshold of 2 seconds.
