-- Shared cash register session for all authenticated Admin and Kasir accounts.
-- Review/apply in staging first. This file is NOT applied automatically.
-- Existing closed sessions and transaction history are preserved.

drop index if exists public.one_open_cash_session_per_user_idx;
create unique index if not exists one_open_cash_session_global_idx
  on public.cash_sessions ((status)) where status = 'open';

drop policy if exists "cash sessions own read" on public.cash_sessions;
drop policy if exists "cash sessions admin read" on public.cash_sessions;
create policy "cash sessions shared read" on public.cash_sessions
  for select to authenticated using (exists (
    select 1 from public.profiles p
    where p.user_id = (select auth.uid()) and p.role in ('admin','cashier')
  ));

create or replace function public.open_cash_session(p_opening_cash numeric default 0)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_row public.cash_sessions%rowtype;
begin
  if v_uid is null then raise exception 'Login diperlukan'; end if;
  if not exists (select 1 from public.profiles where user_id=v_uid and role in ('admin','cashier')) then raise exception 'Role akun tidak valid'; end if;
  if coalesce(p_opening_cash,0)<0 then raise exception 'Kas awal tidak valid'; end if;
  perform pg_advisory_xact_lock(hashtext('pos_shared_cash_session_open'));
  select * into v_row from public.cash_sessions where status='open' limit 1 for update;
  if found then return jsonb_build_object('id',v_row.id,'status',v_row.status,'opening_cash',v_row.opening_cash,'opened_at',v_row.opened_at); end if;
  insert into public.cash_sessions(user_id,opening_cash) values(v_uid,coalesce(p_opening_cash,0)) returning * into v_row;
  insert into public.audit_logs(user_id,user_email,action,target_type,target_id,details)
  values(v_uid,coalesce(auth.jwt()->>'email',''),'open_cash_session','cash_session',v_row.id::text,jsonb_build_object('opening_cash',v_row.opening_cash));
  return jsonb_build_object('id',v_row.id,'status',v_row.status,'opening_cash',v_row.opening_cash,'opened_at',v_row.opened_at);
end; $$;

create or replace function public.close_cash_session(p_session_id uuid,p_actual_cash numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid:=auth.uid(); v_row public.cash_sessions%rowtype; v_expected numeric;
begin
  if v_uid is null then raise exception 'Login diperlukan'; end if;
  if not exists (select 1 from public.profiles where user_id=v_uid and role in ('admin','cashier')) then raise exception 'Role akun tidak valid'; end if;
  if p_actual_cash is null or p_actual_cash<0 then raise exception 'Kas aktual tidak valid'; end if;
  select * into v_row from public.cash_sessions where id=p_session_id and status='open' for update;
  if not found then raise exception 'Sesi kas bersama tidak ditemukan atau sudah ditutup'; end if;
  select v_row.opening_cash + coalesce(sum(amount) filter(where movement_type in ('CASH_SALE','CASH_IN','ADJUSTMENT')),0) + coalesce(sum(amount) filter(where movement_type='CASH_OUT'),0)
    into v_expected from public.cash_movements where session_id=v_row.id;
  update public.cash_sessions set status='closed',closed_at=now(),closing_cash=p_actual_cash,expected_cash=v_expected,difference=p_actual_cash-v_expected where id=v_row.id returning * into v_row;
  insert into public.audit_logs(user_id,user_email,action,target_type,target_id,details)
  values(v_uid,coalesce(auth.jwt()->>'email',''),'close_cash_session','cash_session',v_row.id::text,jsonb_build_object('expected_cash',v_expected,'closing_cash',p_actual_cash,'difference',p_actual_cash-v_expected));
  return jsonb_build_object('id',v_row.id,'status',v_row.status,'expected_cash',v_expected,'closing_cash',p_actual_cash,'difference',p_actual_cash-v_expected);
end; $$;

revoke all on function public.open_cash_session(numeric) from anon,public;
revoke all on function public.close_cash_session(uuid,numeric) from anon,public;
grant execute on function public.open_cash_session(numeric) to authenticated;
grant execute on function public.close_cash_session(uuid,numeric) to authenticated;

-- Summary across the shared session for all staff, not just the opener.
create or replace function public.get_cash_session_summary(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_session public.cash_sessions%rowtype;
  v_cash numeric := 0;
  v_cash_count bigint := 0;
  v_expected numeric := 0;
  v_total numeric := 0;
  v_count bigint := 0;
begin
  if v_uid is null then
    raise exception 'Login diperlukan';
  end if;

  select *
    into v_session
  from public.cash_sessions
  where id = p_session_id
    and status in ('open', 'closed')
  for share;

  if not found then
    raise exception 'Shift tidak ditemukan';
  end if;

  select
    coalesce(sum(amount) filter (where movement_type = 'CASH_SALE'), 0),
    count(*) filter (where movement_type = 'CASH_SALE')
  into v_cash, v_cash_count
  from public.cash_movements
  where session_id = v_session.id;

  -- Keep the shift summary consistent with close_cash_session.
  select
    v_session.opening_cash
    + coalesce(sum(amount) filter (where movement_type in ('CASH_SALE', 'CASH_IN', 'ADJUSTMENT')), 0)
    + coalesce(sum(amount) filter (where movement_type = 'CASH_OUT'), 0)
  into v_expected
  from public.cash_movements
  where session_id = v_session.id;

  select
    coalesce(sum(grand_total), 0),
    count(*)
  into v_total, v_count
  from public.transactions
  where created_at >= v_session.opened_at
    and (v_session.closed_at is null or created_at <= v_session.closed_at)
    and status <> 'voided';

  return jsonb_build_object(
    'cash_sales', v_cash,
    'cash_count', v_cash_count,
    'total_sales', v_total,
    'transaction_count', v_count,
    'opening_cash', v_session.opening_cash,
    'expected_cash', v_expected
  );
end;
$$;

revoke all on function public.get_cash_session_summary(uuid) from anon, public;
grant execute on function public.get_cash_session_summary(uuid) to authenticated;


-- Preserve checkout logic; only allow the shared open session to be used by any authenticated staff member.
-- Shared cash-session checkout compatibility: preserves existing checkout, stock, payment and idempotency behavior.

create or replace function public.checkout_atomic(
  p_trx_id text, p_order_type text, p_table_name text, p_items jsonb,
  p_payment_method text, p_cash_given numeric default 0,
  p_tax_enabled boolean default false, p_service_rate numeric default 0,
  p_discount_rate numeric default 0, p_member_id text default null,
  p_cash_session_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_transaction_id bigint;
  v_cash_session public.cash_sessions%rowtype;
  v_existing public.transactions%rowtype;
  v_subtotal numeric := 0;
  v_tax numeric := 0;
  v_service numeric := 0;
  v_discount numeric := 0;
  v_member_discount numeric := 0;
  v_grand_total numeric := 0;
  v_cash_given numeric := greatest(coalesce(p_cash_given, 0), 0);
  v_change numeric := 0;
  v_item jsonb;
  v_items jsonb;
  v_transaction_items jsonb;
  v_fingerprint text;
  v_product public.products%rowtype;
  v_price numeric;
  v_qty numeric;
  v_recipe jsonb;
  v_raw_id text;
  v_raw_qty numeric;
  v_stock numeric;
  v_existing_cash_given numeric := 0;
  v_existing_change numeric := 0;
  v_business_date date := (now() at time zone 'Asia/Jakarta')::date;
  v_business_time text := to_char(now() at time zone 'Asia/Jakarta', 'HH24:MI:SS');
begin
  if v_uid is null then raise exception 'Login diperlukan'; end if;
  if not exists (
    select 1 from public.profiles
    where user_id = v_uid and role in ('admin', 'cashier')
  ) then raise exception 'Role akun tidak valid'; end if;
  if trim(coalesce(p_trx_id, '')) = '' then raise exception 'Nomor transaksi wajib diisi'; end if;
  if p_order_type not in ('Dine In', 'Takeaway', 'Gojek', 'Grab') then raise exception 'Jenis order tidak valid'; end if;
  if p_payment_method not in ('Cash', 'Gojek App', 'Grab App', 'QRIS', 'Debit') then raise exception 'Metode pembayaran tidak valid'; end if;
  if p_payment_method = 'Gojek App' and p_order_type <> 'Gojek' then raise exception 'Gojek App hanya untuk order Gojek'; end if;
  if p_payment_method = 'Grab App' and p_order_type <> 'Grab' then raise exception 'Grab App hanya untuk order Grab'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Item pesanan kosong'; end if;
  if coalesce(p_service_rate, 0) not in (0, 0.05, 0.07) then raise exception 'Service charge tidak valid'; end if;
  if coalesce(p_discount_rate, 0) not in (0, 0.05, 0.10, 0.15, 0.20) then raise exception 'Diskon promo tidak valid'; end if;

  -- Validate item structure before aggregation, then collapse duplicate product IDs.
  for v_item in select value from jsonb_array_elements(p_items) as input_items(value) loop
    if trim(coalesce(v_item->>'id', '')) = '' then raise exception 'ID produk wajib diisi'; end if;
    begin
      v_qty := (v_item->>'qty')::numeric;
    exception when others then
      raise exception 'Quantity tidak valid untuk produk %', v_item->>'id';
    end;
    if v_qty is null or v_qty <= 0 then raise exception 'Quantity tidak valid'; end if;
  end loop;

  select jsonb_agg(
    jsonb_build_object('id', grouped.product_id, 'qty', grouped.total_qty)
    order by grouped.product_id
  )
  into v_items
  from (
    select trim(value->>'id') as product_id,
           sum((value->>'qty')::numeric) as total_qty
    from jsonb_array_elements(p_items) as input_items(value)
    group by trim(value->>'id')
  ) grouped;

  -- A retry is recognized only for the same user, shift, and checkout payload.
  -- For legacy transactions without a fingerprint, fail closed rather than guessing.
  v_fingerprint := md5(jsonb_build_object(
    'user_id', v_uid,
    'order_type', p_order_type,
    'table_name', case when p_order_type = 'Dine In' then trim(coalesce(p_table_name, '')) else '-' end,
    'items', v_items,
    'payment_method', p_payment_method,
    'cash_given', case when p_payment_method = 'Cash' then greatest(coalesce(p_cash_given, 0), 0) else null end,
    'tax_enabled', coalesce(p_tax_enabled, false),
    'service_rate', coalesce(p_service_rate, 0),
    'discount_rate', coalesce(p_discount_rate, 0),
    'member_id', p_member_id,
    'cash_session_id', p_cash_session_id
  )::text);

  select * into v_existing
  from public.transactions
  where trx_id = trim(p_trx_id);

  if found then
    if v_existing.status <> 'completed' then
      raise exception 'Nomor transaksi sudah ada dengan status %; periksa laporan sebelum melanjutkan.', v_existing.status;
    end if;
    if v_existing.checkout_fingerprint is null
       or v_existing.checkout_fingerprint <> v_fingerprint then
      raise exception 'Nomor transaksi sudah digunakan dan payload tidak dapat diverifikasi. Periksa riwayat sebelum mencoba lagi.';
    end if;

    select coalesce(cash_given, 0), coalesce(change_amount, 0)
      into v_existing_cash_given, v_existing_change
    from public.payments
    where transaction_id = v_existing.id
    limit 1;

    return jsonb_build_object(
      'trx_id', v_existing.trx_id,
      'date', v_existing.date,
      'time', v_existing.time,
      'subtotal', v_existing.subtotal,
      'tax', v_existing.tax,
      'service_charge', v_existing.service_charge,
      'discount', v_existing.discount,
      'member_discount', v_existing.member_discount,
      'grand_total', v_existing.grand_total,
      'cash_given', v_existing_cash_given,
      'change', v_existing_change,
      'status', v_existing.status,
      'cash_session_id', p_cash_session_id,
      'replayed', true
    );
  end if;

  if p_order_type = 'Dine In' then
    if trim(coalesce(p_table_name, '')) = '' then raise exception 'Meja wajib dipilih untuk Dine In'; end if;
    if not exists(select 1 from public.restaurant_tables where name = trim(p_table_name)) then raise exception 'Meja tidak ditemukan'; end if;
  end if;

  if p_cash_session_id is null then raise exception 'Buka shift kasir terlebih dahulu'; end if;
  select * into v_cash_session
  from public.cash_sessions
  where id = p_cash_session_id and status = 'open'
  for update;
  if not found then raise exception 'Shift kasir tidak aktif'; end if;

  for v_item in select value from jsonb_array_elements(v_items) as normalized_items(value) loop
    v_qty := (v_item->>'qty')::numeric;
    select * into v_product
    from public.products
    where id = v_item->>'id' and available = true
    for update;
    if not found then raise exception 'Produk tidak tersedia: %', v_item->>'id'; end if;
    v_price := case p_order_type
      when 'Gojek' then coalesce(v_product.gojek_price, v_product.price)
      when 'Grab' then coalesce(v_product.grab_price, v_product.price)
      else v_product.price
    end;
    v_subtotal := v_subtotal + v_price * v_qty;
  end loop;

  -- Preserve the full legacy transaction item snapshot used by reports/history.
  select jsonb_agg(
    jsonb_build_object(
      'id', p.id,
      'name', p.name,
      'price', case p_order_type
        when 'Gojek' then coalesce(p.gojek_price, p.price)
        when 'Grab' then coalesce(p.grab_price, p.price)
        else p.price
      end,
      'qty', (i.value->>'qty')::numeric,
      'lineTotal', (case p_order_type
        when 'Gojek' then coalesce(p.gojek_price, p.price)
        when 'Grab' then coalesce(p.grab_price, p.price)
        else p.price
      end) * (i.value->>'qty')::numeric
    ) order by p.id
  )
  into v_transaction_items
  from jsonb_array_elements(v_items) as i(value)
  join public.products p on p.id = i.value->>'id';

  v_tax := case when coalesce(p_tax_enabled, false) then v_subtotal * 0.10 else 0 end;
  v_service := v_subtotal * coalesce(p_service_rate, 0);
  v_discount := (v_subtotal + v_tax + v_service) * coalesce(p_discount_rate, 0);

  if p_member_id is not null then
    if not exists(select 1 from public.members where id = p_member_id) then raise exception 'Member tidak ditemukan'; end if;
    v_member_discount := 5000;
  end if;

  v_grand_total := greatest(0, v_subtotal + v_tax + v_service - v_discount - v_member_discount);
  if p_payment_method = 'Cash' then
    if v_cash_given < v_grand_total then raise exception 'Uang cash kurang'; end if;
    v_change := v_cash_given - v_grand_total;
  else
    v_cash_given := v_grand_total;
  end if;

  insert into public.transactions(
    trx_id, date, time, table_name, order_type, cashier, subtotal, tax,
    service_charge, discount, member_discount, grand_total, payment_method,
    items, status, checkout_fingerprint
  ) values (
    trim(p_trx_id), v_business_date, v_business_time,
    case when p_order_type = 'Dine In' then trim(p_table_name) else '-' end,
    p_order_type, coalesce(auth.jwt()->>'email', ''), v_subtotal, v_tax,
    v_service, v_discount, v_member_discount, v_grand_total, p_payment_method,
    v_transaction_items, 'completed', v_fingerprint
  ) returning id into v_transaction_id;

  for v_item in select value from jsonb_array_elements(v_items) as normalized_items(value) loop
    select * into v_product
    from public.products
    where id = v_item->>'id' and available = true
    for update;
    v_qty := (v_item->>'qty')::numeric;
    v_price := case p_order_type
      when 'Gojek' then coalesce(v_product.gojek_price, v_product.price)
      when 'Grab' then coalesce(v_product.grab_price, v_product.price)
      else v_product.price
    end;

    insert into public.order_items(transaction_id, product_id, product_name, unit_price, quantity, line_total, recipe_snapshot)
    values(v_transaction_id, v_product.id, v_product.name, v_price, v_qty, v_price * v_qty, coalesce(v_product.recipe, '[]'::jsonb));

    for v_recipe in select value from jsonb_array_elements(coalesce(v_product.recipe, '[]'::jsonb)) as recipes(value) loop
      v_raw_id := v_recipe->>'rawId';
      v_raw_qty := (v_recipe->>'qty')::numeric * v_qty;
      select stock into v_stock from public.raw_materials where id = v_raw_id for update;
      if not found then raise exception 'Bahan baku tidak ditemukan: %', v_raw_id; end if;
      if v_stock < v_raw_qty then raise exception 'Stok bahan baku tidak cukup: %', v_raw_id; end if;
      update public.raw_materials set stock = stock - v_raw_qty, updated_at = now() where id = v_raw_id;
      insert into public.inventory_movements(raw_material_id, quantity, movement_type, reference_id, created_by, notes)
      values(v_raw_id, -v_raw_qty, 'SALE', v_transaction_id, v_uid, 'Checkout atomic ' || trim(p_trx_id));
    end loop;
  end loop;

  insert into public.payments(transaction_id, payment_method, amount, cash_given, change_amount, status)
  values(v_transaction_id, p_payment_method, v_grand_total, v_cash_given, v_change, 'completed');

  if p_payment_method = 'Cash' then
    insert into public.cash_movements(session_id, transaction_id, user_id, movement_type, amount, notes)
    values(v_cash_session.id, v_transaction_id, v_uid, 'CASH_SALE', v_grand_total, 'Cash checkout ' || trim(p_trx_id));
  end if;

  insert into public.audit_logs(user_id, user_email, action, target_type, target_id, details)
  values(v_uid, coalesce(auth.jwt()->>'email', ''), 'checkout', 'transaction', trim(p_trx_id),
    jsonb_build_object('payment_method', p_payment_method, 'order_type', p_order_type, 'total', v_grand_total, 'cash_session_id', v_cash_session.id));

  -- Keep active bill cleanup in the same transaction as sale creation.
  if p_order_type = 'Dine In' then
    -- Delete only the exact bill contents that were checked out. If another cashier
    -- has since changed the table's bill, preserve that newer order for reconciliation.
    delete from public.active_bills ab
    where ab.table_name = trim(p_table_name)
      and (
        select jsonb_agg(
          jsonb_build_object('id', grouped.product_id, 'qty', grouped.total_qty)
          order by grouped.product_id
        )
        from (
          select trim(value->>'id') as product_id,
                 sum((value->>'qty')::numeric) as total_qty
          from jsonb_array_elements(
            case when jsonb_typeof(ab.items) = 'array' then ab.items else '[]'::jsonb end
          ) as bill_items(value)
          group by trim(value->>'id')
        ) grouped
      ) = v_items;
  end if;

  return jsonb_build_object(
    'trx_id', trim(p_trx_id), 'date', v_business_date, 'time', v_business_time,
    'subtotal', v_subtotal, 'tax', v_tax, 'service_charge', v_service,
    'discount', v_discount, 'member_discount', v_member_discount,
    'grand_total', v_grand_total, 'cash_given', v_cash_given,
    'change', v_change, 'status', 'completed', 'cash_session_id', v_cash_session.id,
    'replayed', false
  );

exception
  when unique_violation then
    -- A concurrent retry may pass the initial lookup. The unique trx_id constraint
    -- arbitrates the race; after rollback, return the committed row only if identical.
    select * into v_existing
    from public.transactions
    where trx_id = trim(p_trx_id);

    if found and v_existing.status = 'completed'
       and v_existing.checkout_fingerprint is not null
       and v_existing.checkout_fingerprint = v_fingerprint then
      select coalesce(cash_given, 0), coalesce(change_amount, 0)
        into v_existing_cash_given, v_existing_change
      from public.payments
      where transaction_id = v_existing.id
      limit 1;

      return jsonb_build_object(
        'trx_id', v_existing.trx_id,
        'date', v_existing.date,
        'time', v_existing.time,
        'subtotal', v_existing.subtotal,
        'tax', v_existing.tax,
        'service_charge', v_existing.service_charge,
        'discount', v_existing.discount,
        'member_discount', v_existing.member_discount,
        'grand_total', v_existing.grand_total,
        'cash_given', v_existing_cash_given,
        'change', v_existing_change,
        'status', v_existing.status,
        'cash_session_id', p_cash_session_id,
        'replayed', true
      );
    end if;
    raise;
end;
$$;

revoke all on function public.checkout_atomic(text,text,text,jsonb,text,numeric,boolean,numeric,numeric,text,uuid) from anon, public;
grant execute on function public.checkout_atomic(text,text,text,jsonb,text,numeric,boolean,numeric,numeric,text,uuid) to authenticated;

