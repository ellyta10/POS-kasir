-- CRITICAL lockdown: transaction creation must go through checkout_atomic.
drop policy if exists "transactions authenticated insert" on public.transactions;
revoke all on function public.void_transaction(text, text) from anon, public;
grant execute on function public.void_transaction(text, text) to authenticated;
