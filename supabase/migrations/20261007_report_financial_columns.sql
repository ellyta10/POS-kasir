-- Store the exact financial components produced by checkout_atomic.
-- Safe for existing data: historical rows are backfilled as zero where the exact
-- component was not persisted by the previous schema.
alter table public.transactions
  add column if not exists service_charge numeric not null default 0,
  add column if not exists discount numeric not null default 0,
  add column if not exists member_discount numeric not null default 0;

update public.transactions
set service_charge = coalesce(service_charge, 0),
    discount = coalesce(discount, 0),
    member_discount = coalesce(member_discount, 0)
where service_charge is null or discount is null or member_discount is null;

create or replace function public.checkout_atomic(
  p_trx_id text, p_order_type text, p_table_name text, p_items jsonb,
  p_payment_method text, p_cash_given numeric default 0,
  p_tax_enabled boolean default false, p_service_rate numeric default 0,
  p_discount_rate numeric default 0, p_member_id text default null,
  p_cash_session_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid(); v_transaction_id bigint; v_cash_session public.cash_sessions%rowtype;
  v_subtotal numeric:=0; v_tax numeric:=0; v_service numeric:=0; v_discount numeric:=0;
  v_member_discount numeric:=0; v_grand_total numeric:=0; v_cash_given numeric:=greatest(coalesce(p_cash_given,0),0); v_change numeric:=0;
  v_item jsonb; v_product public.products%rowtype; v_price numeric; v_qty numeric;
  v_recipe jsonb; v_raw_id text; v_raw_qty numeric; v_stock numeric;
begin
  if v_uid is null then raise exception 'Login diperlukan'; end if;
  if not exists(select 1 from public.profiles where user_id=v_uid and role in ('admin','cashier')) then raise exception 'Role akun tidak valid'; end if;
  if p_order_type not in ('Dine In','Takeaway','Gojek','Grab') then raise exception 'Jenis order tidak valid'; end if;
  if p_payment_method not in ('Cash','Gojek App','Grab App','QRIS','Debit') then raise exception 'Metode pembayaran tidak valid'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Item pesanan kosong'; end if;
  if coalesce(p_service_rate,0)<0 or coalesce(p_service_rate,0)>0.50 then raise exception 'Service charge tidak valid'; end if;
  if coalesce(p_discount_rate,0)<0 or coalesce(p_discount_rate,0)>0.50 then raise exception 'Diskon tidak valid'; end if;
  if p_cash_session_id is null then raise exception 'Buka shift kasir terlebih dahulu'; end if;
  select * into v_cash_session from public.cash_sessions where id=p_cash_session_id and user_id=v_uid and status='open' for update;
  if not found then raise exception 'Shift kasir tidak aktif'; end if;
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty := (v_item->>'qty')::numeric;
    if v_qty is null or v_qty<=0 then raise exception 'Quantity tidak valid'; end if;
    select * into v_product from public.products where id=v_item->>'id' and available=true for update;
    if not found then raise exception 'Produk tidak tersedia: %',v_item->>'id'; end if;
    v_price := case p_order_type when 'Gojek' then coalesce(v_product.gojek_price,v_product.price) when 'Grab' then coalesce(v_product.grab_price,v_product.price) else v_product.price end;
    v_subtotal := v_subtotal + v_price*v_qty;
  end loop;
  v_tax := case when coalesce(p_tax_enabled,false) then v_subtotal*0.10 else 0 end;
  v_service := v_subtotal*coalesce(p_service_rate,0);
  v_discount := (v_subtotal+v_tax+v_service)*coalesce(p_discount_rate,0);
  if p_member_id is not null then
    if not exists(select 1 from public.members where id=p_member_id) then raise exception 'Member tidak ditemukan'; end if;
    v_member_discount:=5000;
  end if;
  v_grand_total := greatest(0,v_subtotal+v_tax+v_service-v_discount-v_member_discount);
  if p_payment_method='Cash' then
    if v_cash_given<v_grand_total then raise exception 'Uang cash kurang'; end if;
    v_change:=v_cash_given-v_grand_total;
  else v_cash_given:=v_grand_total; end if;
  insert into public.transactions(
    trx_id,date,time,table_name,order_type,cashier,subtotal,tax,service_charge,discount,member_discount,
    grand_total,payment_method,items,status
  ) values (
    trim(p_trx_id),current_date,to_char(localtime,'HH24:MI:SS'),case when p_order_type='Dine In' then p_table_name else '-' end,
    p_order_type,coalesce(auth.jwt()->>'email',''),v_subtotal,v_tax,v_service,v_discount,v_member_discount,
    v_grand_total,p_payment_method,p_items,'completed'
  ) returning id into v_transaction_id;
  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_product from public.products where id=v_item->>'id' and available=true for update;
    v_qty:=(v_item->>'qty')::numeric;
    v_price:=case p_order_type when 'Gojek' then coalesce(v_product.gojek_price,v_product.price) when 'Grab' then coalesce(v_product.grab_price,v_product.price) else v_product.price end;
    insert into public.order_items(transaction_id,product_id,product_name,unit_price,quantity,line_total,recipe_snapshot)
      values(v_transaction_id,v_product.id,v_product.name,v_price,v_qty,v_price*v_qty,coalesce(v_product.recipe,'[]'::jsonb));
    for v_recipe in select * from jsonb_array_elements(coalesce(v_product.recipe,'[]'::jsonb)) loop
      v_raw_id:=v_recipe->>'rawId'; v_raw_qty:=(v_recipe->>'qty')::numeric*v_qty;
      select stock into v_stock from public.raw_materials where id=v_raw_id for update;
      if not found then raise exception 'Bahan baku tidak ditemukan: %',v_raw_id; end if;
      if v_stock<v_raw_qty then raise exception 'Stok bahan baku tidak cukup: %',v_raw_id; end if;
      update public.raw_materials set stock=stock-v_raw_qty,updated_at=now() where id=v_raw_id;
      insert into public.inventory_movements(raw_material_id,quantity,movement_type,reference_id,created_by,notes)
        values(v_raw_id,-v_raw_qty,'SALE',v_transaction_id,v_uid,'Checkout atomic '||trim(p_trx_id));
    end loop;
  end loop;
  insert into public.payments(transaction_id,payment_method,amount,cash_given,change_amount,status)
    values(v_transaction_id,p_payment_method,v_grand_total,v_cash_given,v_change,'completed');
  if p_payment_method='Cash' then
    insert into public.cash_movements(session_id,transaction_id,user_id,movement_type,amount,notes)
      values(v_cash_session.id,v_transaction_id,v_uid,'CASH_SALE',v_grand_total,'Cash checkout '||trim(p_trx_id));
  end if;
  insert into public.audit_logs(user_id,user_email,action,target_type,target_id,details)
    values(v_uid,coalesce(auth.jwt()->>'email',''),'checkout','transaction',trim(p_trx_id),
      jsonb_build_object('payment_method',p_payment_method,'order_type',p_order_type,'total',v_grand_total,'cash_session_id',v_cash_session.id));
  return jsonb_build_object('trx_id',trim(p_trx_id),'date',current_date,'time',to_char(localtime,'HH24:MI:SS'),
    'subtotal',v_subtotal,'tax',v_tax,'service_charge',v_service,'discount',v_discount,'member_discount',v_member_discount,
    'grand_total',v_grand_total,'cash_given',v_cash_given,'change',v_change,'status','completed','cash_session_id',v_cash_session.id);
end;
$$;

create or replace function public.get_report_dashboard(
  p_from date, p_to date, p_compare_from date default null, p_compare_to date default null,
  p_cashier text default null, p_order_type text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid:=auth.uid(); v_current jsonb; v_previous jsonb; v_void jsonb; v_channels jsonb; v_payments jsonb; v_daily jsonb; v_inventory numeric; v_void_count bigint; v_void_value numeric;
begin
  if v_uid is null then raise exception 'Login diperlukan'; end if;
  if not exists(select 1 from public.profiles where user_id=v_uid and role='admin') then raise exception 'Hanya admin yang dapat melihat laporan lengkap'; end if;
  if p_from is null or p_to is null or p_from>p_to then raise exception 'Periode laporan tidak valid'; end if;
  if p_compare_from is null or p_compare_to is null then p_compare_from:=p_from-(p_to-p_from+1); p_compare_to:=p_from-1; end if;
  select jsonb_build_object('revenue',coalesce(sum(t.grand_total),0),'orders',count(*)::int,'aov',coalesce(avg(t.grand_total),0),'tax',coalesce(sum(t.tax),0),'discount',coalesce(sum(t.discount),0),'member_discount',coalesce(sum(t.member_discount),0),'service_charge',coalesce(sum(t.service_charge),0),'cash_revenue',coalesce(sum(t.grand_total) filter(where t.payment_method='Cash'),0),'non_cash_revenue',coalesce(sum(t.grand_total) filter(where t.payment_method<>'Cash'),0)) into v_current from public.transactions t where t.date between p_from and p_to and coalesce(t.status,'completed')='completed' and (p_cashier is null or t.cashier=p_cashier) and (p_order_type is null or t.order_type=p_order_type);
  select jsonb_build_object('revenue',coalesce(sum(t.grand_total),0),'orders',count(*)::int,'aov',coalesce(avg(t.grand_total),0),'tax',coalesce(sum(t.tax),0),'discount',coalesce(sum(t.discount),0),'member_discount',coalesce(sum(t.member_discount),0),'service_charge',coalesce(sum(t.service_charge),0)) into v_previous from public.transactions t where t.date between p_compare_from and p_compare_to and coalesce(t.status,'completed')='completed' and (p_cashier is null or t.cashier=p_cashier) and (p_order_type is null or t.order_type=p_order_type);
  select jsonb_build_object('count',count(*)::int,'value',coalesce(sum(t.grand_total),0)) into v_void from public.transactions t where t.date between p_from and p_to and t.status='voided' and (p_cashier is null or t.cashier=p_cashier) and (p_order_type is null or t.order_type=p_order_type);
  select coalesce(jsonb_agg(x order by x.revenue desc),'[]'::jsonb) into v_channels from (select t.order_type as channel,count(*)::int as orders,coalesce(sum(t.grand_total),0) as revenue from public.transactions t where t.date between p_from and p_to and coalesce(t.status,'completed')='completed' and (p_cashier is null or t.cashier=p_cashier) and (p_order_type is null or t.order_type=p_order_type) group by t.order_type) x;
  select coalesce(jsonb_agg(x order by x.revenue desc),'[]'::jsonb) into v_payments from (select t.payment_method as method,count(*)::int as orders,coalesce(sum(t.grand_total),0) as revenue from public.transactions t where t.date between p_from and p_to and coalesce(t.status,'completed')='completed' and (p_cashier is null or t.cashier=p_cashier) and (p_order_type is null or t.order_type=p_order_type) group by t.payment_method) x;
  select coalesce(jsonb_agg(x order by x.sale_date),'[]'::jsonb) into v_daily from (select t.date as sale_date,count(*)::int as orders,coalesce(sum(t.grand_total),0) as revenue from public.transactions t where t.date between p_from and p_to and coalesce(t.status,'completed')='completed' and (p_cashier is null or t.cashier=p_cashier) and (p_order_type is null or t.order_type=p_order_type) group by t.date) x;
  select coalesce(sum(stock*cost),0) into v_inventory from public.raw_materials;
  v_void_count:=coalesce((v_void->>'count')::bigint,0); v_void_value:=coalesce((v_void->>'value')::numeric,0);
  return jsonb_build_object('period',jsonb_build_object('from',p_from,'to',p_to),'comparison_period',jsonb_build_object('from',p_compare_from,'to',p_compare_to),'current',v_current,'previous',v_previous,'void',jsonb_build_object('count',v_void_count,'value',v_void_value),'channels',v_channels,'payments',v_payments,'daily',v_daily,'inventory_value',v_inventory);
end;
$$;
revoke all on function public.get_report_dashboard(date,date,date,date,text,text) from anon, public;
grant execute on function public.get_report_dashboard(date,date,date,date,text,text) to authenticated;
