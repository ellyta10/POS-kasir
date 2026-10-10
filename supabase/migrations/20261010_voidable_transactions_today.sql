create or replace function public.list_voidable_transactions(p_date date default (now() at time zone 'Asia/Jakarta')::date)
returns table (
  trx_id text,
  sale_date date,
  sale_time text,
  grand_total numeric,
  cashier text,
  status text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1
    from public.profiles
    where user_id = auth.uid()
      and role in ('admin', 'cashier')
  ) then
    raise exception 'Role akun tidak valid';
  end if;

  return query
  select
    t.trx_id,
    t.date,
    t.time,
    t.grand_total,
    t.cashier,
    t.status
  from public.transactions t
  where t.date = coalesce(p_date, (now() at time zone 'Asia/Jakarta')::date)
    and t.status = 'completed'
  order by t.time desc, t.id desc
  limit 200;
end;
$$;

revoke all on function public.list_voidable_transactions(date) from public;
revoke all on function public.list_voidable_transactions(date) from anon;
grant execute on function public.list_voidable_transactions(date) to authenticated;
