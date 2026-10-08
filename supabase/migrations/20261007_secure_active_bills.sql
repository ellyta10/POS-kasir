-- Secure active bills while preserving cashier/admin operational flows.
-- Only Dine In orders are stored as table-keyed active bills.

create or replace function public.save_active_bill(
  p_table_name text,
  p_order_type text,
  p_items jsonb,
  p_order_time text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_table text := trim(coalesce(p_table_name, ''));
  v_order_type text := trim(coalesce(p_order_type, ''));
  v_row public.active_bills%rowtype;
begin
  if v_uid is null then raise exception 'Login diperlukan'; end if;
  if not exists(select 1 from public.profiles where user_id=v_uid and role in ('admin','cashier')) then
    raise exception 'Role akun tidak valid';
  end if;
  if v_order_type <> 'Dine In' then
    raise exception 'Active bill hanya tersedia untuk pesanan Dine In';
  end if;
  if v_table = '' then raise exception 'Meja wajib dipilih'; end if;
  if not exists(select 1 from public.restaurant_tables where name=v_table) then
    raise exception 'Meja tidak ditemukan';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Item bill tidak valid';
  end if;

  insert into public.active_bills(table_name, order_type, items, order_time, updated_at)
    values(v_table, v_order_type, p_items, nullif(trim(coalesce(p_order_time, '')), ''), now())
  on conflict (table_name) do update set
    order_type=excluded.order_type,
    items=excluded.items,
    order_time=excluded.order_time,
    updated_at=now()
  returning * into v_row;

  insert into public.audit_logs(user_id,user_email,action,target_type,target_id,details)
    values(v_uid,coalesce(auth.jwt()->>'email',''),'save_active_bill','active_bill',v_table,
      jsonb_build_object('order_type',v_order_type,'item_count',jsonb_array_length(p_items)));

  return jsonb_build_object('table_name',v_row.table_name,'order_type',v_row.order_type,'items',v_row.items,'order_time',v_row.order_time);
end;
$$;

create or replace function public.remove_active_bill(p_table_name text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_table text := trim(coalesce(p_table_name, ''));
  v_deleted public.active_bills%rowtype;
begin
  if v_uid is null then raise exception 'Login diperlukan'; end if;
  if not exists(select 1 from public.profiles where user_id=v_uid and role in ('admin','cashier')) then
    raise exception 'Role akun tidak valid';
  end if;
  if v_table = '' then raise exception 'Meja wajib dipilih'; end if;

  delete from public.active_bills where table_name=v_table returning * into v_deleted;

  if found then
    insert into public.audit_logs(user_id,user_email,action,target_type,target_id,details)
      values(v_uid,coalesce(auth.jwt()->>'email',''),'remove_active_bill','active_bill',v_table,
        jsonb_build_object('order_type',v_deleted.order_type));
  end if;

  return jsonb_build_object('table_name',v_table,'removed',found);
end;
$$;

revoke all on function public.save_active_bill(text,text,jsonb,text) from anon, public;
revoke all on function public.remove_active_bill(text) from anon, public;
grant execute on function public.save_active_bill(text,text,jsonb,text) to authenticated;
grant execute on function public.remove_active_bill(text) to authenticated;

-- Keep authenticated read access for recall/realtime, but remove direct writes.
drop policy if exists "active bills authenticated access" on public.active_bills;
drop policy if exists "active bills authenticated read" on public.active_bills;
create policy "active bills authenticated read" on public.active_bills
  for select to authenticated using (true);
revoke insert, update, delete, truncate on public.active_bills from anon, authenticated;
grant select on public.active_bills to authenticated;
