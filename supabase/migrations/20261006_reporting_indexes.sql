-- Reporting/performance hardening.
-- These indexes support date/status filtering and common audit/detail lookups.
create index if not exists transactions_date_status_idx
  on public.transactions(date, status);
create index if not exists transactions_created_at_idx
  on public.transactions(created_at desc);
create index if not exists order_items_transaction_product_idx
  on public.order_items(transaction_id, product_id);
create index if not exists audit_logs_created_at_idx
  on public.audit_logs(created_at desc);
create index if not exists audit_logs_target_idx
  on public.audit_logs(target_type, target_id);

-- Avoid per-row auth function re-evaluation in the two policies flagged by the advisor.
drop policy if exists "profiles own read" on public.profiles;
create policy "profiles own read" on public.profiles
  for select to authenticated using (user_id = (select auth.uid()));

drop policy if exists "audit logs authenticated insert" on public.audit_logs;
create policy "audit logs authenticated insert" on public.audit_logs
  for insert to authenticated with check (user_id = (select auth.uid()));
