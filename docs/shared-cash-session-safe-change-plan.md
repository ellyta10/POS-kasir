# Shared Cash Session — Safe Change Plan

## Target behavior
One active cash session for the restaurant. Admin and Cashier accounts read and use the same session. The opening balance is entered once; any authorized user can close the session, subject to the agreed operational rule.

## Current blockers confirmed in source
- `cash_sessions.user_id` is required and `one_open_cash_session_per_user_idx` allows one open session per user, not one per restaurant.
- `POSCashSessionsRepository.current(client, userId)` filters by `user_id`.
- `open_cash_session` finds an open session by the current user's id.
- `close_cash_session`, `get_cash_session_summary`, and `checkout_atomic` validate that the session belongs to the current user.
- `get_cash_session_summary` calculates total sales and transaction count by the current user's cashier email, so it will not reliably summarize a shared session.
- `transactions` links to the session indirectly through `cash_movements`; only cash sales create cash movements. Non-cash sales still need to be included in overall sales and transaction counts.

## Safe implementation approach
1. Do not change production or run SQL against the live Supabase project.
2. Create a staging Supabase project with a sanitized schema and representative test data.
3. Add a stable restaurant/store identifier to sessions (or a singleton store-level session key) before enforcing one active session globally. Do not simply drop the per-user index: existing open sessions may conflict.
4. Add a migration that safely handles legacy open sessions: detect and report duplicates, preserve closed history, and require an explicit resolution for multiple open sessions rather than silently merging money movements.
5. Update `current`, `open`, and UI session state so both roles resolve the same active session.
6. Update `checkout_atomic`, `close_cash_session`, and `get_cash_session_summary` to authorize by role and store/session scope rather than session owner. Keep authentication and role checks server-side.
7. Derive overall sales and transaction count from transactions associated with the session using a durable relationship, not the current cashier's email or only cash movements. For non-cash transactions, add an explicit session association during checkout (or another auditable association) so reporting is correct.
8. Ensure cash movements remain cash-only for cash reconciliation; do not count QRIS/debit/app payments as physical cash.
9. Test concurrency and role permissions before considering deployment.

## Required staging test matrix
- Admin opens a session; Cashier sees and uses the same session.
- Cashier opens a session first; Admin sees and uses that session.
- Two users open simultaneously; exactly one active session is created.
- Cash, QRIS, Debit, Gojek App, and Grab App checkouts succeed with valid combinations and reject invalid combinations.
- Duplicate checkout retry does not duplicate transaction, stock deductions, payment, or cash movement.
- Cash expected balance = opening cash + cash sales + cash-in/adjustments - cash-out, with sign conventions verified against actual movement-entry code.
- Summary includes transactions from all users, including non-cash sales; voided transactions are excluded from net sales and cash reversals are handled according to the existing void policy.
- Closing the shared session blocks further checkout for every account.
- Admin-only reports stay Admin-only; cashier void restrictions remain unchanged.
- Active bills, inventory movements, HPP snapshots, audit logs, and historical closed sessions remain intact.

## Current decision
Do not ship a code-only frontend change or a database-only migration. Without an isolated staging database and an executable regression suite, the shared-cash change cannot yet be demonstrated safe. This plan intentionally does not modify production data or application behavior.
