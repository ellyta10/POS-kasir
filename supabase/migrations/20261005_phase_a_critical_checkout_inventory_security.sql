-- Phase A CRITICAL migration only.
-- Non-destructive: adds child tables/functions, removes anonymous business policies,
-- and seeds the three raw materials already present in the current app defaults.

create extension if not exists pgcrypto;

create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  transaction_id bigint not null references public.transactions(id) on delete restrict,
  product_id text not null references public.products(id) on delete restrict,
  product_name text not null,
  unit_price numeric not null check (unit_price >= 0),
  quantity numeric not null check (quantity > 0),
  line_total numeric not null check (line_total >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  transaction_id bigint not null references public.transactions(id) on delete restrict,
  payment_method text not null,
  amount numeric not null check (amount >= 0),
  cash_given numeric not null default 0 check (cash_given >= 0),
  change_amount numeric not null default 0 check (change_amount >= 0),
  status text not null default 'completed' check (status in ('completed','failed','refunded')),
  created_at timestamptz not null default now()
);

create table if not exists public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  raw_material_id text not null references public.raw_materials(id) on delete restrict,
  quantity numeric not null check (quantity <> 0),
  movement_type text not null check (movement_type in ('PURCHASE','SALE','WASTE','ADJUSTMENT','STOCK_OPNAME','RETURN','TRANSFER_IN','TRANSFER_OUT','VOID_REVERSAL')),
  reference_id bigint references public.transactions(id) on delete restrict,
  created_by uuid references auth.users(id) on delete set null,
  notes text,
  created_at timestamptz not null default now()
);

create index if not exists order_items_transaction_id_idx on public.order_items(transaction_id);
create index if not exists payments_transaction_id_idx on public.payments(transaction_id);
create index if not exists inventory_movements_raw_material_id_idx on public.inventory_movements(raw_material_id);
create index if not exists inventory_movements_reference_id_idx on public.inventory_movements(reference_id);

-- Seed only rows represented by the current application defaults; existing rows are preserved.
insert into public.raw_materials (id, name, category, stock, unit, cost)
values
  ('rm_1', 'Daging Ayam Fresh', 'Daging & Unggas', 85, 'potong', 12000),
  ('rm_2', 'Beras Premium', 'Sembako', 50, 'kg', 15000),
  ('rm_3', 'Terasi Udang', 'Bumbu', 12, 'pack', 8000)
on conflict (id) do nothing;

alter table public.order_items enable row level security;
alter table public.payments enable row level security;
alter table public.inventory_movements enable row level security;

-- RPC is the only write path for these new critical tables.
drop policy if exists "order items admin read" on public.order_items;
drop policy if exists "payments admin read" on public.payments;
drop policy if exists "inventory movements admin read" on public.inventory_movements;
create policy "order items admin read" on public.order_items for select to authenticated using ((select public.is_admin()));
create policy "payments admin read" on public.payments for select to authenticated using ((select public.is_admin()));
create policy "inventory movements admin read" on public.inventory_movements for select to authenticated using ((select public.is_admin()));

-- Remove every anonymous policy from public business tables. This is intentional security hardening.
do $$
declare p record;
begin
  for p in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public' and 'anon' = any(roles)
  loop
    execute format('drop policy if exists %I on %I.%I', p.policyname, p.schemaname, p.tablename);
  end loop;
end $$;

revoke all on function public.is_admin() from anon, public;
grant execute on function public.is_admin() to authenticated;

create or replace function public.checkout_atomic(
  p_trx_id text,
  p_order_type text,
  p_table_name text,
  p_items jsonb,
  p_payment_method text,
  p_cash_given numeric default 0,
  p_tax_enabled boolean default false,
  p_service_rate numeric default 0,
  p_discount_rate numeric default 0,
  p_member_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_transaction_id bigint;
  v_subtotal numeric := 0;
  v_tax numeric := 0;
  v_service numeric := 0;
  v_discount numeric := 0;
  v_member_discount numeric := 0;
  v_grand_total numeric := 0;
  v_cash_given numeric := greatest(coalesce(p_cash_given, 0), 0);
  v_change numeric := 0;
  v_item jsonb;
  v_product public.products%rowtype;
  v_price numeric;
  v_qty numeric;
  v_line numeric;
  v_recipe jsonb;
  v_raw_id text;
  v_raw_qty numeric;
  v_stock numeric;
begin
  if v_uid is null then raise exception 'Login diperlukan'; end if;
  if trim(coalesce(p_trx_id, '')) = '' then raise exception 'Nomor transaksi wajib diisi'; end if;
  if p_order_type not in ('Dine In','Takeaway','Gojek','Grab') then raise exception 'Jenis order tidak valid'; end if;
  if p_payment_method not in ('Cash','Gojek App','Grab App','QRIS','Debit') then raise exception 'Metode pembayaran tidak valid'; end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Item pesanan kosong'; end if;
  if coalesce(p_service_rate, 0) < 0 or coalesce(p_service_rate, 0) > 0.50 then raise exception 'Service charge tidak valid'; end if;
  if coalesce(p_discount_rate, 0) < 0 or coalesce(p_discount_rate, 0) > 0.50 then raise exception 'Diskon tidak valid'; end if;

  -- Lock each product row and recalculate all prices on the server.
  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_qty := (v_item->>'qty')::numeric;
    if v_qty is null or v_qty <= 0 then raise exception 'Quantity tidak valid'; end if;
    select * into v_product from public.products where id = v_item->>'id' and available = true for update;
    if not found then raise exception 'Produk tidak tersedia: %', v_item->>'id'; end if;
    v_price := case p_order_type when 'Gojek' then coalesce(v_product.gojek_price, v_product.price) when 'Grab' then coalesce(v_product.grab_price, v_product.price) else v_product.price end;
    v_line := v_price * v_qty;
    v_subtotal := v_subtotal + v_line;
  end loop;

  v_tax := case when coalesce(p_tax_enabled, false) then v_subtotal * 0.10 else 0 end;
  v_service := v_subtotal * coalesce(p_service_rate, 0);
  v_discount := (v_subtotal + v_tax + v_service) * coalesce(p_discount_rate, 0);
  if p_member_id is not null then
    if not exists (select 1 from public.members where id = p_member_id) then raise exception 'Member tidak ditemukan'; end if;
    v_member_discount := 5000;
  end if;
  v_grand_total := greatest(0, v_subtotal + v_tax + v_service - v_discount - v_member_discount);
  if p_payment_method = 'Cash' then
    if v_cash_given < v_grand_total then raise exception 'Uang cash kurang'; end if;
    v_change := v_cash_given - v_grand_total;
  else
    v_cash_given := v_grand_total;
  end if;

  insert into public.transactions (trx_id, date, time, table_name, order_type, cashier, subtotal, tax, grand_total, payment_method, items, status)
  values (trim(p_trx_id), current_date, to_char(localtime, 'HH24:MI:SS'), case when p_order_type = 'Dine In' then p_table_name else '-' end, p_order_type, coalesce(auth.jwt()->>'email',''), v_subtotal, v_tax, v_grand_total, p_payment_method, p_items, 'completed')
  returning id into v_transaction_id;

  for v_item in select * from jsonb_array_elements(p_items)
  loop
    select * into v_product from public.products where id = v_item->>'id' and available = true for update;
    v_qty := (v_item->>'qty')::numeric;
    v_price := case p_order_type when 'Gojek' then coalesce(v_product.gojek_price, v_product.price) when 'Grab' then coalesce(v_product.grab_price, v_product.price) else v_product.price end;
    insert into public.order_items(transaction_id, product_id, product_name, unit_price, quantity, line_total)
    values (v_transaction_id, v_product.id, v_product.name, v_price, v_qty, v_price * v_qty);

    for v_recipe in select * from jsonb_array_elements(coalesce(v_product.recipe, '[]'::jsonb))
    loop
      v_raw_id := v_recipe->>'rawId';
      v_raw_qty := (v_recipe->>'qty')::numeric * v_qty;
      select stock into v_stock from public.raw_materials where id = v_raw_id for update;
      if not found then raise exception 'Bahan baku tidak ditemukan: %', v_raw_id; end if;
      if v_stock < v_raw_qty then raise exception 'Stok bahan baku tidak cukup: %', v_raw_id; end if;
      update public.raw_materials set stock = stock - v_raw_qty, updated_at = now() where id = v_raw_id;
      insert into public.inventory_movements(raw_material_id, quantity, movement_type, reference_id, created_by, notes)
      values (v_raw_id, -v_raw_qty, 'SALE', v_transaction_id, v_uid, 'Checkout atomic ' || trim(p_trx_id));
    end loop;
  end loop;

  insert into public.payments(transaction_id, payment_method, amount, cash_given, change_amount, status)
  values (v_transaction_id, p_payment_method, v_grand_total, v_cash_given, v_change, 'completed');

  insert into public.audit_logs(user_id, user_email, action, target_type, target_id, details)
  values (v_uid, coalesce(auth.jwt()->>'email',''), 'checkout', 'transaction', trim(p_trx_id), jsonb_build_object('payment_method', p_payment_method, 'order_type', p_order_type, 'total', v_grand_total));

  return jsonb_build_object('trx_id', trim(p_trx_id), 'date', current_date, 'time', to_char(localtime, 'HH24:MI:SS'), 'subtotal', v_subtotal, 'tax', v_tax, 'service_charge', v_service, 'discount', v_discount, 'member_discount', v_member_discount, 'grand_total', v_grand_total, 'cash_given', v_cash_given, 'change', v_change, 'status', 'completed');
end;
$$;

revoke all on function public.checkout_atomic(text,text,text,jsonb,text,numeric,boolean,numeric,numeric,text) from anon, public;
grant execute on function public.checkout_atomic(text,text,text,jsonb,text,numeric,boolean,numeric,numeric,text) to authenticated;
