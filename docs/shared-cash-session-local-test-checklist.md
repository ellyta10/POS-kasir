# Shared Cash Session — Local Test Checklist (No Supabase Branch)

## Safety boundary
- This checklist is for source review and local/static tests only.
- Do not run migrations or write queries against the production Supabase project.
- Do not deploy or merge this branch.
- No isolated database is available, so database concurrency, RLS, RPC authorization, and real checkout integration remain unverified.

## Source-level checks
- [ ] `POSCashSessionsRepository.current` no longer depends on the signed-in user's ID once the shared-session implementation is safely completed.
- [ ] Admin and Cashier use the same store/session scope; role checks remain in the database RPCs.
- [ ] Open-session creation is concurrency-safe at the database level (not just disabled in the UI).
- [ ] Checkout, close, and summary RPCs authorize the user's role and store/session scope, not session ownership.
- [ ] All transactions—cash and non-cash—are associated with the session through a durable relationship.
- [ ] Cash reconciliation includes only physical cash movements and approved cash adjustments.
- [ ] Existing idempotency, stock deduction, HPP snapshots, active-bill cleanup, void reversal, and audit logging remain intact.
- [ ] Legacy duplicate open sessions are detected and never silently merged.

## Manual regression matrix (must run in an isolated database before release)

| Scenario | Expected result |
|---|---|
| Admin opens session; Cashier refreshes | Cashier sees the same open session |
| Cashier opens session; Admin refreshes | Admin sees the same open session |
| Two users open at nearly the same time | Exactly one open session exists |
| Cash checkout | One transaction, one payment, one cash movement, stock deducted once |
| QRIS / debit / Gojek / Grab checkout | Sale appears in session totals; physical cash balance does not increase |
| Retry the same checkout request | No duplicate transaction, payment, stock deduction, or cash movement |
| Cash-in / cash-out adjustment | Expected cash follows the existing movement sign conventions |
| Cashier attempts to close shared session | Allowed only if the approved role policy says so; all checkout is blocked after close |
| Void today's transaction as Cashier | Existing same-day rule is preserved, with correct cash reversal |
| Void a previous-day transaction as Cashier | Rejected; Admin-only restriction preserved |
| Cashier opens Reports / Audit Logs | Existing Admin-only UI and server-side permissions remain enforced |
| Existing active bill / inventory / HPP / audit history | Data remains intact and usable |

## Checks possible without a database
1. Review diffs and ensure the only touched files are the intended cash-session files, tests, and documentation.
2. Run JavaScript syntax checks with a local Node.js installation where applicable.
3. Verify SQL migration syntax with a PostgreSQL parser or disposable local PostgreSQL instance.
4. Run unit tests with mocked Supabase query/RPC calls.
5. Review the final migration manually for lock scope, transaction boundaries, grants, RLS, and legacy-session handling.

## Release gate
Do not mark this feature ready based only on a frontend build or mocked tests. The shared-session behavior changes financial state and requires the isolated-database matrix above, especially concurrency, multi-role authorization, and cash/non-cash reconciliation.
