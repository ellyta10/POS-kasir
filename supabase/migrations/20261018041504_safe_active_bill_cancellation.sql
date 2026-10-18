-- Safe cancellation for active dine-in bills.
-- Cancellation is atomic and retry-safe using a client-generated request UUID.
create or replace function public.cancel_active_bill(
  p_table_name text,
  p_reason text,
  p_request_id uuid
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_table text := trim(coalesce(p_table_name, ''));
  v_reason text := trim(coalesce(p_reason, ''));
  v_bill public.active_bills%rowtype;
  v_previous public.audit_logs%rowtype;
begin
  if v_uid is null then raise exception 'Login diperlukan'; end if;
  if not exists (select 1 from public.profiles where user_id = v_uid and role in ('admin', 'cashier')) then
    raise exception 'Role akun tidak valid';
  end if;
  if v_table = '' then raise exception 'Meja wajib dipilih'; end if;
  if v_reason = '' then raise exception 'Alasan pembatalan wajib diisi'; end if;
  if length(v_reason) > 500 then raise exception 'Alasan pembatalan maksimal 500 karakter'; end if;
  if p_request_id is null then raise exception 'ID permintaan pembatalan wajib diisi'; end if;

  -- Serialize retries using the same request ID. Without this lock, two simultaneous
  -- requests could both miss the audit row and the second would fail after the first
  -- request deletes the bill. The lock is transaction-scoped and has no persistent state.
  perform pg_advisory_xact_lock(hashtextextended(p_request_id::text, 0));

  -- Retry with the same request ID returns the original bill snapshot, never a newer bill.
  select * into v_previous
  from public.audit_logs
  where action = 'cancel_active_bill' and details->>'request_id' = p_request_id::text
  limit 1;
  if found then
    return jsonb_build_object(
      'table_name', v_previous.target_id,
      'items', v_previous.details->'items',
      'order_time', v_previous.details->>'order_time',
      'reason', v_previous.details->>'reason',
      'already_cancelled', true
    );
  end if;

  select * into v_bill from public.active_bills where table_name = v_table for update;
  if not found then raise exception 'Bill aktif tidak ditemukan; muat ulang daftar bill'; end if;
  if coalesce(v_bill.order_type, '') <> 'Dine In' then
    raise exception 'Pembatalan bill aktif hanya tersedia untuk pesanan Dine In';
  end if;

  delete from public.active_bills where table_name = v_table;
  insert into public.audit_logs(user_id, user_email, action, target_type, target_id, details)
  values (
    v_uid, coalesce(auth.jwt()->>'email', ''), 'cancel_active_bill', 'active_bill', v_table,
    jsonb_build_object(
      'request_id', p_request_id::text,
      'reason', v_reason,
      'order_type', v_bill.order_type,
      'items', v_bill.items,
      'order_time', v_bill.order_time
    )
  );

  return jsonb_build_object(
    'table_name', v_bill.table_name, 'order_type', v_bill.order_type,
    'items', v_bill.items, 'order_time', v_bill.order_time,
    'reason', v_reason, 'already_cancelled', false
  );
end;
$$;

revoke all on function public.cancel_active_bill(text, text, uuid) from anon, public;
grant execute on function public.cancel_active_bill(text, text, uuid) to authenticated;
