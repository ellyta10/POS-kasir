-- Move remaining operational data toward Supabase source of truth.
-- Existing rows are preserved; no legacy transactions are modified.

-- Enable realtime delivery for the tables used by multiple devices.
do $$
begin
  begin alter publication supabase_realtime add table public.products; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.raw_materials; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.active_bills; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.categories; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.restaurant_tables; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.store_config; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.cash_sessions; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.cash_movements; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.transactions; exception when duplicate_object then null; end;
end $$;

-- Allow an authenticated cashier/admin to add a member through a validated RPC.
create or replace function public.create_member(p_id text, p_name text, p_phone text)
returns public.members
language plpgsql security definer set search_path=public
as $$
declare v_uid uuid := auth.uid(); v_row public.members%rowtype;
begin
  if v_uid is null then raise exception 'Login diperlukan'; end if;
  if not exists (select 1 from public.profiles where user_id=v_uid and role in ('admin','cashier')) then raise exception 'Role akun tidak valid'; end if;
  if trim(coalesce(p_id,''))='' or trim(coalesce(p_name,''))='' or trim(coalesce(p_phone,''))='' then raise exception 'Data member wajib diisi'; end if;
  insert into public.members(id,name,phone,points) values(trim(p_id),trim(p_name),trim(p_phone),0) returning * into v_row;
  insert into public.audit_logs(user_id,user_email,action,target_type,target_id,details)
  values(v_uid,coalesce(auth.jwt()->>'email',''),'create_member','member',v_row.id,jsonb_build_object('name',v_row.name,'phone',v_row.phone));
  return v_row;
end; $$;
revoke all on function public.create_member(text,text,text) from anon,public;
grant execute on function public.create_member(text,text,text) to authenticated;
