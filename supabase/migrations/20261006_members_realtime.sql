-- Keep member dropdowns synchronized across authenticated POS devices.
do $$
begin
  begin
    alter publication supabase_realtime add table public.members;
  exception when duplicate_object then
    null;
  end;
end $$;
