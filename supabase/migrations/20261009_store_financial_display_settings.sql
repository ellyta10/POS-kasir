-- Store-level financial display settings.
-- Defaults preserve the existing POS behavior: tax off, service charge on at 7%.
alter table public.store_config
  add column if not exists tax_enabled boolean not null default false,
  add column if not exists service_charge_enabled boolean not null default true,
  add column if not exists service_charge_rate numeric(5,4) not null default 0.07;

update public.store_config
set tax_enabled = coalesce(tax_enabled, false),
    service_charge_enabled = coalesce(service_charge_enabled, true),
    service_charge_rate = case
      when service_charge_rate is null or service_charge_rate < 0 or service_charge_rate > 1 then 0.07
      else service_charge_rate
    end
where id = 'default';

alter table public.store_config
  drop constraint if exists store_config_service_charge_rate_check;
alter table public.store_config
  add constraint store_config_service_charge_rate_check
  check (service_charge_rate >= 0 and service_charge_rate <= 1);
