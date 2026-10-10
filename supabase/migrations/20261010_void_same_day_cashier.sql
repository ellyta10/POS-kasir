create or replace function public.void_transaction(p_trx_id text,p_reason text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare
  v_uid uuid:=auth.uid();
  v_role text;
  v_transaction_id bigint;
  v_trx_id text;
  v_status text;
  v_tx_date date;
  v_item record;
  v_recipe jsonb;
  v_raw_id text;
  v_raw_qty numeric;
begin
  if v_uid is null then raise exception 'Login diperlukan'; end if;
  select role into v_role from public.profiles where user_id=v_uid;
  if v_role not in ('admin','cashier') then raise exception 'Role akun tidak valid'; end if;
  if length(trim(coalesce(p_reason,'')))<3 then raise exception 'Alasan void wajib diisi'; end if;

  select id,trx_id,status,date into v_transaction_id,v_trx_id,v_status,v_tx_date
  from public.transactions
  where trx_id=trim(p_trx_id)
  limit 1;
  if v_trx_id is null or coalesce(v_status,'completed')='voided' then
    raise exception 'Transaksi tidak ditemukan atau sudah pernah di-void';
  end if;
  if v_role='cashier' and v_tx_date <> (now() at time zone 'Asia/Jakarta')::date then
    raise exception 'Kasir hanya dapat melakukan void transaksi pada hari operasional yang sama';
  end if;

  update public.transactions
  set status='voided',voided_at=now(),voided_by=v_uid,void_reason=trim(p_reason)
  where id=v_transaction_id and coalesce(status,'completed')<>'voided'
  returning id,trx_id,status into v_transaction_id,v_trx_id,v_status;
  if v_trx_id is null then raise exception 'Transaksi tidak ditemukan atau sudah pernah di-void'; end if;

  for v_item in select product_id,quantity,recipe_snapshot from public.order_items where transaction_id=v_transaction_id loop
    for v_recipe in select * from jsonb_array_elements(coalesce(v_item.recipe_snapshot,'[]'::jsonb)) loop
      v_raw_id:=v_recipe->>'rawId';
      v_raw_qty:=(v_recipe->>'qty')::numeric*v_item.quantity;
      update public.raw_materials set stock=stock+v_raw_qty,updated_at=now() where id=v_raw_id;
      if not found then raise exception 'Bahan baku reversal tidak ditemukan: %',v_raw_id; end if;
      insert into public.inventory_movements(raw_material_id,quantity,movement_type,reference_id,created_by,notes)
      values(v_raw_id,v_raw_qty,'VOID_REVERSAL',v_transaction_id,v_uid,'Void '||v_trx_id||': '||trim(p_reason));
    end loop;
  end loop;

  update public.payments set status='refunded' where transaction_id=v_transaction_id and status='completed';
  insert into public.audit_logs(user_id,user_email,action,target_type,target_id,details)
  values(v_uid,coalesce(auth.jwt()->>'email',''),'void_transaction','transaction',v_trx_id,
    jsonb_build_object('reason',trim(p_reason),'inventory_reversed',true,'actor_role',v_role,'transaction_date',v_tx_date));
  return jsonb_build_object('trx_id',v_trx_id,'status',v_status,'inventory_reversed',true);
end; $$;

revoke all on function public.void_transaction(text,text) from anon,public;
grant execute on function public.void_transaction(text,text) to authenticated;
