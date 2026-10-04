-- Phase A HIGH only.
-- Adds cash sessions, server-side role checks, and inventory reversal on void.

create table if not exists public.cash_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  opened_at timestamptz not null default now(),
  opening_cash numeric not null default 0 check (opening_cash >= 0),
  closed_at timestamptz,
  closing_cash numeric check (closing_cash >= 0),
  expected_cash numeric,
  difference numeric,
  status text not null default 'open' check (status in ('open','closed')),
  created_at timestamptz not null default now()
);

create table if not exists public.cash_movements (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.cash_sessions(id) on delete restrict,
  transaction_id bigint references public.transactions(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  movement_type text not null check (movement_type in ('CASH_SALE','CASH_REFUND','CASH_IN','CASH_OUT','ADJUSTMENT')),
  amount numeric not null check (amount <> 0),
  notes text,
  created_at timestamptz not null default now()
);

create unique index if not exists one_open_cash_session_per_user_idx on public.cash_sessions(user_id) where status = 'open';
create index if not exists cash_movements_session_id_idx on public.cash_movements(session_id);
create index if not exists cash_movements_transaction_id_idx on public.cash_movements(transaction_id);

alter table public.cash_sessions enable row level security;
alter table public.cash_movements enable row level security;

drop policy if exists "cash sessions own read" on public.cash_sessions;
drop policy if exists "cash sessions admin read" on public.cash_sessions;
drop policy if exists "cash movements own read" on public.cash_movements;
drop policy if exists "cash movements admin read" on public.cash_movements;
create policy "cash sessions own read" on public.cash_sessions for select to authenticated using (user_id = (select auth.uid()));
create policy "cash sessions admin read" on public.cash_sessions for select to authenticated using ((select public.is_admin()));
create policy "cash movements own read" on public.cash_movements for select to authenticated using (user_id = (select auth.uid()));
create policy "cash movements admin read" on public.cash_movements for select to authenticated using ((select public.is_admin()));

create or replace function public.open_cash_session(p_opening_cash numeric default 0)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_row public.cash_sessions%rowtype;
begin
  if v_uid is null then raise exception 'Login diperlukan'; end if;
  if not exists (select 1 from public.profiles where user_id = v_uid and role in ('admin','cashier')) then raise exception 'Role akun tidak valid'; end if;
  if coalesce(p_opening_cash,0) < 0 then raise exception 'Kas awal tidak valid'; end if;
  select * into v_row from public.cash_sessions where user_id=v_uid and status='open' for update;
  if found then return jsonb_build_object('id',v_row.id,'status',v_row.status,'opening_cash',v_row.opening_cash,'opened_at',v_row.opened_at); end if;
  insert into public.cash_sessions(user_id, opening_cash) values (v_uid, coalesce(p_opening_cash,0)) returning * into v_row;
  insert into public.audit_logs(user_id,user_email,action,target_type,target_id,details)
  values (v_uid,coalesce(auth.jwt()->>'email',''),'open_cash_session','cash_session',v_row.id::text,jsonb_build_object('opening_cash',v_row.opening_cash));
  return jsonb_build_object('id',v_row.id,'status',v_row.status,'opening_cash',v_row.opening_cash,'opened_at',v_row.opened_at);
end; $$;

create or replace function public.close_cash_session(p_session_id uuid, p_actual_cash numeric)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid(); v_row public.cash_sessions%rowtype; v_expected numeric;
begin
  if v_uid is null then raise exception 'Login diperlukan'; end if;
  if p_actual_cash is null or p_actual_cash < 0 then raise exception 'Kas aktual tidak valid'; end if;
  select * into v_row from public.cash_sessions where id=p_session_id and user_id=v_uid and status='open' for update;
  if not found then raise exception 'Shift terbuka tidak ditemukan'; end if;
  select v_row.opening_cash + coalesce(sum(amount) filter (where movement_type in ('CASH_SALE','CASH_IN','ADJUSTMENT')),0) + coalesce(sum(amount) filter (where movement_type='CASH_OUT'),0)
  into v_expected from public.cash_movements where session_id=v_row.id;
  update public.cash_sessions set status='closed',closed_at=now(),closing_cash=p_actual_cash,expected_cash=v_expected,difference=p_actual_cash-v_expected where id=v_row.id returning * into v_row;
  insert into public.audit_logs(user_id,user_email,action,target_type,target_id,details)
  values (v_uid,coalesce(auth.jwt()->>'email',''),'close_cash_session','cash_session',v_row.id::text,jsonb_build_object('expected_cash',v_expected,'closing_cash',p_actual_cash,'difference',p_actual_cash-v_expected));
  return jsonb_build_object('id',v_row.id,'status',v_row.status,'expected_cash',v_expected,'closing_cash',p_actual_cash,'difference',p_actual_cash-v_expected);
end; $$;

revoke all on function public.open_cash_session(numeric) from anon, public;
revoke all on function public.close_cash_session(uuid,numeric) from anon, public;
grant execute on function public.open_cash_session(numeric) to authenticated;
grant execute on function public.close_cash_session(uuid,numeric) to authenticated;

-- Replace checkout with a shift-bound version and add server-side role/session validation.
drop function if exists public.checkout_atomic(text,text,text,jsonb,text,numeric,boolean,numeric,numeric,text);
create or replace function public.checkout_atomic(
  p_trx_id text, p_order_type text, p_table_name text, p_items jsonb,
  p_payment_method text, p_cash_given numeric default 0,
  p_tax_enabled boolean default false, p_service_rate numeric default 0,
  p_discount_rate numeric default 0, p_member_id text default null,
  p_cash_session_id uuid default null
)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare
  v_uid uuid := auth.uid(); v_transaction_id bigint; v_cash_session public.cash_sessions%rowtype;
  v_subtotal numeric:=0; v_tax numeric:=0; v_service numeric:=0; v_discount numeric:=0; v_member_discount numeric:=0; v_grand_total numeric:=0; v_cash_given numeric:=greatest(coalesce(p_cash_given,0),0); v_change numeric:=0;
  v_item jsonb; v_product public.products%rowtype; v_price numeric; v_qty numeric; v_line numeric; v_recipe jsonb; v_raw_id text; v_raw_qty numeric; v_stock numeric;
begin
  if v_uid is null then raise exception 'Login diperlukan'; end if;
  if not exists (select 1 from public.profiles where user_id=v_uid and role in ('admin','cashier')) then raise exception 'Role akun tidak valid'; end if;
  if p_order_type not in ('Dine In','Takeaway','Gojek','Grab') then raise exception 'Jenis order tidak valid'; end if;
  if p_payment_method not in ('Cash','Gojek App','Grab App','QRIS','Debit') then raise exception 'Metode pembayaran tidak valid'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Item pesanan kosong'; end if;
  if coalesce(p_service_rate,0)<0 or coalesce(p_service_rate,0)>0.50 then raise exception 'Service charge tidak valid'; end if;
  if coalesce(p_discount_rate,0)<0 or coalesce(p_discount_rate,0)>0.50 then raise exception 'Diskon tidak valid'; end if;
  if p_cash_session_id is null then raise exception 'Buka shift kasir terlebih dahulu'; end if;
  select * into v_cash_session from public.cash_sessions where id=p_cash_session_id and user_id=v_uid and status='open' for update;
  if not found then raise exception 'Shift kasir tidak aktif'; end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty := (v_item->>'qty')::numeric; if v_qty is null or v_qty<=0 then raise exception 'Quantity tidak valid'; end if;
    select * into v_product from public.products where id=v_item->>'id' and available=true for update;
    if not found then raise exception 'Produk tidak tersedia: %',v_item->>'id'; end if;
    v_price := case p_order_type when 'Gojek' then coalesce(v_product.gojek_price,v_product.price) when 'Grab' then coalesce(v_product.grab_price,v_product.price) else v_product.price end;
    v_subtotal := v_subtotal + v_price*v_qty;
  end loop;
  v_tax := case when coalesce(p_tax_enabled,false) then v_subtotal*0.10 else 0 end;
  v_service := v_subtotal*coalesce(p_service_rate,0);
  v_discount := (v_subtotal+v_tax+v_service)*coalesce(p_discount_rate,0);
  if p_member_id is not null then if not exists(select 1 from public.members where id=p_member_id) then raise exception 'Member tidak ditemukan'; end if; v_member_discount:=5000; end if;
  v_grand_total := greatest(0,v_subtotal+v_tax+v_service-v_discount-v_member_discount);
  if p_payment_method='Cash' then if v_cash_given<v_grand_total then raise exception 'Uang cash kurang'; end if; v_change:=v_cash_given-v_grand_total; else v_cash_given:=v_grand_total; end if;

  insert into public.transactions(trx_id,date,time,table_name,order_type,cashier,subtotal,tax,grand_total,payment_method,items,status)
  values(trim(p_trx_id),current_date,to_char(localtime,'HH24:MI:SS'),case when p_order_type='Dine In' then p_table_name else '-' end,p_order_type,coalesce(auth.jwt()->>'email',''),v_subtotal,v_tax,v_grand_total,p_payment_method,p_items,'completed') returning id into v_transaction_id;
  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_product from public.products where id=v_item->>'id' and available=true for update; v_qty:=(v_item->>'qty')::numeric;
    v_price:=case p_order_type when 'Gojek' then coalesce(v_product.gojek_price,v_product.price) when 'Grab' then coalesce(v_product.grab_price,v_product.price) else v_product.price end;
    insert into public.order_items(transaction_id,product_id,product_name,unit_price,quantity,line_total) values(v_transaction_id,v_product.id,v_product.name,v_price,v_qty,v_price*v_qty);
    for v_recipe in select * from jsonb_array_elements(coalesce(v_product.recipe,'[]'::jsonb)) loop
      v_raw_id:=v_recipe->>'rawId'; v_raw_qty:=(v_recipe->>'qty')::numeric*v_qty; select stock into v_stock from public.raw_materials where id=v_raw_id for update;
      if not found then raise exception 'Bahan baku tidak ditemukan: %',v_raw_id; end if; if v_stock<v_raw_qty then raise exception 'Stok bahan baku tidak cukup: %',v_raw_id; end if;
      update public.raw_materials set stock=stock-v_raw_qty,updated_at=now() where id=v_raw_id;
      insert into public.inventory_movements(raw_material_id,quantity,movement_type,reference_id,created_by,notes) values(v_raw_id,-v_raw_qty,'SALE',v_transaction_id,v_uid,'Checkout atomic '||trim(p_trx_id));
    end loop;
  end loop;
  insert into public.payments(transaction_id,payment_method,amount,cash_given,change_amount,status) values(v_transaction_id,p_payment_method,v_grand_total,v_cash_given,v_change,'completed');
  if p_payment_method='Cash' then insert into public.cash_movements(session_id,transaction_id,user_id,movement_type,amount,notes) values(v_cash_session.id,v_transaction_id,v_uid,'CASH_SALE',v_grand_total,'Cash checkout '||trim(p_trx_id)); end if;
  insert into public.audit_logs(user_id,user_email,action,target_type,target_id,details) values(v_uid,coalesce(auth.jwt()->>'email',''),'checkout','transaction',trim(p_trx_id),jsonb_build_object('payment_method',p_payment_method,'order_type',p_order_type,'total',v_grand_total,'cash_session_id',v_cash_session.id));
  return jsonb_build_object('trx_id',trim(p_trx_id),'date',current_date,'time',to_char(localtime,'HH24:MI:SS'),'subtotal',v_subtotal,'tax',v_tax,'service_charge',v_service,'discount',v_discount,'member_discount',v_member_discount,'grand_total',v_grand_total,'cash_given',v_cash_given,'change',v_change,'status','completed','cash_session_id',v_cash_session.id);
end; $$;
revoke all on function public.checkout_atomic(text,text,text,jsonb,text,numeric,boolean,numeric,numeric,text,uuid) from anon,public;
grant execute on function public.checkout_atomic(text,text,text,jsonb,text,numeric,boolean,numeric,numeric,text,uuid) to authenticated;

-- Void now reverses recipe-based inventory and records a VOID_REVERSAL movement.
create or replace function public.void_transaction(p_trx_id text,p_reason text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_uid uuid:=auth.uid(); v_transaction_id bigint; v_trx_id text; v_status text; v_item record; v_product public.products%rowtype; v_recipe jsonb; v_raw_id text; v_raw_qty numeric;
begin
  if v_uid is null then raise exception 'Login diperlukan'; end if;
  if not exists(select 1 from public.profiles where user_id=v_uid and role in ('admin','cashier')) then raise exception 'Role akun tidak valid'; end if;
  if length(trim(coalesce(p_reason,'')))<3 then raise exception 'Alasan void wajib diisi'; end if;
  update public.transactions set status='voided',voided_at=now(),voided_by=v_uid,void_reason=trim(p_reason) where trx_id=trim(p_trx_id) and coalesce(status,'completed')<>'voided' returning id,trx_id,status into v_transaction_id,v_trx_id,v_status;
  if v_trx_id is null then raise exception 'Transaksi tidak ditemukan atau sudah pernah di-void'; end if;
  for v_item in select product_id,quantity from public.order_items where transaction_id=v_transaction_id loop
    select * into v_product from public.products where id=v_item.product_id;
    for v_recipe in select * from jsonb_array_elements(coalesce(v_product.recipe,'[]'::jsonb)) loop
      v_raw_id:=v_recipe->>'rawId'; v_raw_qty:=(v_recipe->>'qty')::numeric*v_item.quantity;
      update public.raw_materials set stock=stock+v_raw_qty,updated_at=now() where id=v_raw_id;
      if not found then raise exception 'Bahan baku reversal tidak ditemukan: %',v_raw_id; end if;
      insert into public.inventory_movements(raw_material_id,quantity,movement_type,reference_id,created_by,notes) values(v_raw_id,v_raw_qty,'VOID_REVERSAL',v_transaction_id,v_uid,'Void '||v_trx_id||': '||trim(p_reason));
    end loop;
  end loop;
  update public.payments set status='refunded' where transaction_id=v_transaction_id and status='completed';
  insert into public.audit_logs(user_id,user_email,action,target_type,target_id,details) values(v_uid,coalesce(auth.jwt()->>'email',''),'void_transaction','transaction',v_trx_id,jsonb_build_object('reason',trim(p_reason),'inventory_reversed',true));
  return jsonb_build_object('trx_id',v_trx_id,'status',v_status,'inventory_reversed',true);
end; $$;
revoke all on function public.void_transaction(text,text) from anon,public;
grant execute on function public.void_transaction(text,text) to authenticated;
