-- Report dashboard foundation: one server-side, role-checked query for KPI
-- and period comparison. Revenue excludes voided transactions.
create or replace function public.get_report_dashboard(
  p_from date,
  p_to date,
  p_compare_from date default null,
  p_compare_to date default null,
  p_cashier text default null,
  p_order_type text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_current jsonb;
  v_previous jsonb;
  v_void jsonb;
  v_channels jsonb;
  v_payments jsonb;
  v_daily jsonb;
  v_inventory numeric;
  v_void_count bigint;
  v_void_value numeric;
begin
  if v_uid is null then raise exception 'Login diperlukan'; end if;
  if not exists (select 1 from public.profiles where user_id = v_uid and role = 'admin') then
    raise exception 'Hanya admin yang dapat melihat laporan lengkap';
  end if;
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'Periode laporan tidak valid';
  end if;
  if p_compare_from is null or p_compare_to is null then
    p_compare_from := p_from - (p_to - p_from + 1);
    p_compare_to := p_from - 1;
  end if;

  select jsonb_build_object(
    'revenue', coalesce(sum(t.grand_total), 0),
    'orders', count(*)::int,
    'aov', coalesce(avg(t.grand_total), 0),
    'tax', coalesce(sum(t.tax), 0),
    'discount_estimate', coalesce(sum(greatest(0, t.subtotal + t.tax - t.grand_total)), 0),
    'service_charge', 0,
    'cash_revenue', coalesce(sum(t.grand_total) filter (where t.payment_method = 'Cash'), 0),
    'non_cash_revenue', coalesce(sum(t.grand_total) filter (where t.payment_method <> 'Cash'), 0)
  ) into v_current
  from public.transactions t
  where t.date between p_from and p_to
    and coalesce(t.status, 'completed') = 'completed'
    and (p_cashier is null or t.cashier = p_cashier)
    and (p_order_type is null or t.order_type = p_order_type);

  select jsonb_build_object(
    'revenue', coalesce(sum(t.grand_total), 0),
    'orders', count(*)::int,
    'aov', coalesce(avg(t.grand_total), 0),
    'tax', coalesce(sum(t.tax), 0),
    'discount_estimate', coalesce(sum(greatest(0, t.subtotal + t.tax - t.grand_total)), 0)
  ) into v_previous
  from public.transactions t
  where t.date between p_compare_from and p_compare_to
    and coalesce(t.status, 'completed') = 'completed'
    and (p_cashier is null or t.cashier = p_cashier)
    and (p_order_type is null or t.order_type = p_order_type);

  select jsonb_build_object(
    'count', count(*)::int,
    'value', coalesce(sum(t.grand_total), 0)
  ) into v_void
  from public.transactions t
  where t.date between p_from and p_to
    and t.status = 'voided'
    and (p_cashier is null or t.cashier = p_cashier)
    and (p_order_type is null or t.order_type = p_order_type);

  select coalesce(jsonb_agg(x order by x.revenue desc), '[]'::jsonb) into v_channels
  from (
    select t.order_type as channel, count(*)::int as orders, coalesce(sum(t.grand_total),0) as revenue
    from public.transactions t
    where t.date between p_from and p_to and coalesce(t.status,'completed')='completed'
      and (p_cashier is null or t.cashier=p_cashier) and (p_order_type is null or t.order_type=p_order_type)
    group by t.order_type
  ) x;

  select coalesce(jsonb_agg(x order by x.revenue desc), '[]'::jsonb) into v_payments
  from (
    select t.payment_method as method, count(*)::int as orders, coalesce(sum(t.grand_total),0) as revenue
    from public.transactions t
    where t.date between p_from and p_to and coalesce(t.status,'completed')='completed'
      and (p_cashier is null or t.cashier=p_cashier) and (p_order_type is null or t.order_type=p_order_type)
    group by t.payment_method
  ) x;

  select coalesce(jsonb_agg(x order by x.sale_date), '[]'::jsonb) into v_daily
  from (
    select t.date as sale_date, count(*)::int as orders, coalesce(sum(t.grand_total),0) as revenue
    from public.transactions t
    where t.date between p_from and p_to and coalesce(t.status,'completed')='completed'
      and (p_cashier is null or t.cashier=p_cashier) and (p_order_type is null or t.order_type=p_order_type)
    group by t.date
  ) x;

  select coalesce(sum(stock * cost),0) into v_inventory from public.raw_materials;
  v_void_count := coalesce((v_void->>'count')::bigint, 0);
  v_void_value := coalesce((v_void->>'value')::numeric, 0);

  return jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'comparison_period', jsonb_build_object('from', p_compare_from, 'to', p_compare_to),
    'current', v_current,
    'previous', v_previous,
    'void', jsonb_build_object('count', v_void_count, 'value', v_void_value),
    'channels', v_channels,
    'payments', v_payments,
    'daily', v_daily,
    'inventory_value', v_inventory
  );
end;
$$;

revoke all on function public.get_report_dashboard(date,date,date,date,text,text) from anon, public;
grant execute on function public.get_report_dashboard(date,date,date,date,text,text) to authenticated;
