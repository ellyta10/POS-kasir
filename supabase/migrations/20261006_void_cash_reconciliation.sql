-- Cash reconciliation hardening: a voided cash sale must reduce the
-- corresponding cash session, in addition to reversing inventory.
create or replace function public.void_transaction(p_trx_id text, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_transaction_id bigint;
  v_trx_id text;
  v_status text;
  v_payment_method text;
  v_item record;
  v_recipe jsonb;
  v_raw_id text;
  v_raw_qty numeric;
  v_cash_movement record;
begin
  if v_uid is null then raise exception 'Login diperlukan'; end if;
  if not exists (select 1 from public.profiles where user_id = v_uid and role in ('admin','cashier')) then raise exception 'Role akun tidak valid'; end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Alasan void wajib diisi'; end if;

  update public.transactions
     set status = 'voided', voided_at = now(), voided_by = v_uid, void_reason = trim(p_reason)
   where trx_id = trim(p_trx_id) and coalesce(status, 'completed') <> 'voided'
   returning id, trx_id, status into v_transaction_id, v_trx_id, v_status;
  if v_trx_id is null then raise exception 'Transaksi tidak ditemukan atau sudah pernah di-void'; end if;

  for v_item in select product_id, quantity, recipe_snapshot from public.order_items where transaction_id = v_transaction_id loop
    for v_recipe in select * from jsonb_array_elements(coalesce(v_item.recipe_snapshot, '[]'::jsonb)) loop
      v_raw_id := v_recipe->>'rawId';
      v_raw_qty := (v_recipe->>'qty')::numeric * v_item.quantity;
      update public.raw_materials set stock = stock + v_raw_qty, updated_at = now() where id = v_raw_id;
      if not found then raise exception 'Bahan baku reversal tidak ditemukan: %', v_raw_id; end if;
      insert into public.inventory_movements(raw_material_id, quantity, movement_type, reference_id, created_by, notes)
      values (v_raw_id, v_raw_qty, 'VOID_REVERSAL', v_transaction_id, v_uid, 'Void ' || v_trx_id || ': ' || trim(p_reason));
    end loop;
  end loop;

  select payment_method into v_payment_method from public.payments where transaction_id = v_transaction_id and status = 'completed' limit 1;
  update public.payments set status = 'refunded' where transaction_id = v_transaction_id and status = 'completed';

  if v_payment_method = 'Cash' then
    select cm.session_id, cm.amount into v_cash_movement
      from public.cash_movements cm
     where cm.transaction_id = v_transaction_id and cm.movement_type = 'CASH_SALE'
     order by cm.created_at desc limit 1;
    if found then
      insert into public.cash_movements(session_id, transaction_id, user_id, movement_type, amount, notes)
      values (v_cash_movement.session_id, v_transaction_id, v_uid, 'CASH_REFUND', -abs(v_cash_movement.amount), 'Void ' || v_trx_id || ': ' || trim(p_reason));
    end if;
  end if;

  insert into public.audit_logs(user_id, user_email, action, target_type, target_id, details)
  values (v_uid, coalesce(auth.jwt()->>'email', ''), 'void_transaction', 'transaction', v_trx_id,
          jsonb_build_object('reason', trim(p_reason), 'inventory_reversed', true, 'cash_refunded', v_payment_method = 'Cash', 'actor_role', (select role from public.profiles where user_id = v_uid)));
  return jsonb_build_object('trx_id', v_trx_id, 'status', v_status, 'inventory_reversed', true, 'cash_refunded', v_payment_method = 'Cash');
end;
$$;
revoke all on function public.void_transaction(text, text) from anon, public;
grant execute on function public.void_transaction(text, text) to authenticated;
