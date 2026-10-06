-- Enforce the business rule at the database boundary as well as in the UI:
-- only Dine In active bills may be moved between restaurant tables.
create or replace function public.move_active_bill(p_from_table text, p_to_table text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_uid uuid := auth.uid();
  v_bill public.active_bills%rowtype;
begin
  if v_uid is null then raise exception 'Login diperlukan'; end if;
  if not exists(select 1 from public.profiles where user_id=v_uid and role in ('admin','cashier')) then
    raise exception 'Role akun tidak valid';
  end if;
  if trim(coalesce(p_from_table,''))='' or trim(coalesce(p_to_table,''))='' or trim(p_from_table)=trim(p_to_table) then
    raise exception 'Meja asal dan tujuan tidak valid';
  end if;
  if not exists(select 1 from public.restaurant_tables where name=trim(p_to_table)) then
    raise exception 'Meja tujuan tidak ditemukan';
  end if;

  select * into v_bill
  from public.active_bills
  where table_name=trim(p_from_table)
  for update;
  if not found then raise exception 'Bill aktif di meja asal tidak ditemukan'; end if;
  if coalesce(v_bill.order_type, '') <> 'Dine In' then
    raise exception 'Pindah meja hanya tersedia untuk pesanan Dine In';
  end if;
  if exists(select 1 from public.active_bills where table_name=trim(p_to_table)) then
    raise exception 'Meja tujuan sudah memiliki bill aktif';
  end if;

  insert into public.active_bills(table_name,order_type,items,order_time,updated_at)
    values(trim(p_to_table),v_bill.order_type,v_bill.items,v_bill.order_time,now());
  delete from public.active_bills where table_name=trim(p_from_table);
  insert into public.table_move_history(from_table,to_table,order_type,items,moved_by)
    values(trim(p_from_table),trim(p_to_table),v_bill.order_type,v_bill.items,v_uid);
  insert into public.audit_logs(user_id,user_email,action,target_type,target_id,details)
    values(v_uid,coalesce(auth.jwt()->>'email',''),'move_active_bill','active_bill',trim(p_to_table),jsonb_build_object('from_table',trim(p_from_table),'to_table',trim(p_to_table),'order_type',v_bill.order_type));

  return jsonb_build_object('from_table',trim(p_from_table),'to_table',trim(p_to_table),'order_type',v_bill.order_type,'items',v_bill.items,'order_time',v_bill.order_time);
end;
$$;

revoke all on function public.move_active_bill(text,text) from anon,public;
grant execute on function public.move_active_bill(text,text) to authenticated;
