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
declare
  v_role text;
  v_today date := (now() at time zone 'Asia/Jakarta')::date;
  v_requested_date date := coalesce(p_date, v_today);
begin
  select role into v_role from public.profiles where user_id = auth.uid();
  if v_role not in ('admin', 'cashier') then
    raise exception 'Role akun tidak valid';
  end if;
  if v_role = 'cashier' and v_requested_date <> v_today then
    raise exception 'Kasir hanya dapat melihat transaksi pada hari operasional yang sama';
  end if;

  return query
  select t.trx_id, t.date, t.time, t.grand_total, t.cashier, t.status
  from public.transactions t
  where t.date = v_requested_date
    and t.status = 'completed'
  order by t.time desc, t.id desc
  limit 200;
end;
$$;

revoke all on function public.list_voidable_transactions(date) from public;
revoke all on function public.list_voidable_transactions(date) from anon;
grant execute on function public.list_voidable_transactions(date) to authenticated;
