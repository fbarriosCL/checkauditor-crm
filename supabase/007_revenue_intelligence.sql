-- Check Auditor CRM · 007 · base de datos para Revenue Intelligence (solo cambios aditivos)
-- Ejecutar UNA vez en Supabase -> SQL Editor. Es idempotente: se puede repetir sin efectos.
--
-- Qué agrega:
--  1. leads.expected_close_at (fecha estimada de cierre) y leads.lost_at (fecha de pérdida).
--  2. lead_stage_history: foto del valor UF, responsable y canal en cada cambio de etapa,
--     y la marca `approx` para fechas no confiables (p. ej. cierres importados sin fecha).
--  3. lead_field_history: historial de cambios de valor UF, responsable, canal y fecha estimada.
--  4. stage_config: probabilidad de cierre por etapa (editable; NO es una probabilidad calibrada).
--  5. Índices para consultas históricas.
--
-- Reaperturas: pasar de ganado/perdido a una etapa abierta limpia won_at/lost_at. El historial
-- conserva todos los eventos; los cálculos toman como cierre efectivo solo el último cierre
-- que no fue seguido de una reapertura.

-- 1. Campos nuevos en leads
alter table leads add column if not exists expected_close_at date;
alter table leads add column if not exists lost_at timestamptz;

-- 2. Historial de etapas con foto del valor
alter table lead_stage_history add column if not exists deal_value_uf numeric(10,2);
alter table lead_stage_history add column if not exists owner_id uuid;
alter table lead_stage_history add column if not exists channel text;
alter table lead_stage_history add column if not exists approx boolean not null default false;

-- 3. Historial de cambios de campos comerciales
create table if not exists lead_field_history (
  id bigint generated always as identity primary key,
  lead_id uuid not null references leads(id) on delete cascade,
  field text not null,            -- deal_value_uf | owner_id | channel | expected_close_at
  old_value text,
  new_value text,
  changed_by uuid references auth.users(id),
  changed_at timestamptz not null default now()
);
create index if not exists lfh_lead_idx on lead_field_history(lead_id, field, changed_at);

alter table lead_field_history enable row level security;
drop policy if exists team_read_field_history on lead_field_history;
create policy team_read_field_history on lead_field_history
  for select to authenticated using (is_team_member());

-- 4. Probabilidad de cierre por etapa (configurable)
create table if not exists stage_config (
  stage lead_stage primary key,
  probability numeric(4,3) not null check (probability between 0 and 1),
  updated_at timestamptz not null default now()
);

-- Valores iniciales: supuestos de partida, no probabilidades observadas.
insert into stage_config (stage, probability) values
  ('nuevo', 0.05), ('contactado', 0.08), ('calificado', 0.15),
  ('demo_agendada', 0.20), ('demo_hecha', 0.30), ('propuesta', 0.50),
  ('negociacion', 0.70), ('ganado', 1), ('perdido', 0)
on conflict (stage) do nothing;

alter table stage_config enable row level security;
drop policy if exists team_read_stage_config on stage_config;
create policy team_read_stage_config on stage_config
  for select to authenticated using (is_team_member());
drop policy if exists team_update_stage_config on stage_config;
create policy team_update_stage_config on stage_config
  for update to authenticated using (is_team_member()) with check (is_team_member());

-- 5. Triggers
-- 5a. Fechas clave: se conserva la lógica original y se agregan lost_at y reapertura.
create or replace function leads_before_update() returns trigger
language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  if new.stage is distinct from old.stage then
    new.stage_changed_at := now();
    if old.stage = 'nuevo' and new.first_contact_at is null then
      new.first_contact_at := now();
    end if;
    if new.stage = 'ganado' then new.won_at := now(); end if;
    if new.stage = 'perdido' then new.lost_at := now(); end if;
    -- Reapertura: sale de un estado final a una etapa abierta.
    if old.stage in ('ganado','perdido') and new.stage not in ('ganado','perdido') then
      new.won_at := null;
      new.lost_at := null;
    end if;
    -- Cambio directo ganado <-> perdido: queda solo la fecha del estado vigente.
    if new.stage = 'ganado' then new.lost_at := null; end if;
    if new.stage = 'perdido' then new.won_at := null; end if;
  end if;
  return new;
end $$;

-- 5b. Historial de etapas con foto de valor, responsable y canal.
create or replace function leads_after_stage() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into lead_stage_history(lead_id, from_stage, to_stage, changed_by, deal_value_uf, owner_id, channel)
    values (new.id, null, new.stage, auth.uid(), new.deal_value_uf, new.owner_id, new.channel);
  elsif new.stage is distinct from old.stage then
    insert into lead_stage_history(lead_id, from_stage, to_stage, changed_by, deal_value_uf, owner_id, channel)
    values (new.id, old.stage, new.stage, auth.uid(), new.deal_value_uf, new.owner_id, new.channel);
  end if;
  return new;
end $$;

-- 5c. Historial de cambios de valor, responsable, canal y fecha estimada de cierre.
create or replace function leads_after_fields() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.deal_value_uf is distinct from old.deal_value_uf then
    insert into lead_field_history(lead_id, field, old_value, new_value, changed_by)
    values (new.id, 'deal_value_uf', old.deal_value_uf::text, new.deal_value_uf::text, auth.uid());
  end if;
  if new.owner_id is distinct from old.owner_id then
    insert into lead_field_history(lead_id, field, old_value, new_value, changed_by)
    values (new.id, 'owner_id', old.owner_id::text, new.owner_id::text, auth.uid());
  end if;
  if new.channel is distinct from old.channel then
    insert into lead_field_history(lead_id, field, old_value, new_value, changed_by)
    values (new.id, 'channel', old.channel, new.channel, auth.uid());
  end if;
  if new.expected_close_at is distinct from old.expected_close_at then
    insert into lead_field_history(lead_id, field, old_value, new_value, changed_by)
    values (new.id, 'expected_close_at', old.expected_close_at::text, new.expected_close_at::text, auth.uid());
  end if;
  return new;
end $$;

drop trigger if exists trg_leads_after_fields on leads;
create trigger trg_leads_after_fields
  after update of deal_value_uf, owner_id, channel, expected_close_at on leads
  for each row execute function leads_after_fields();

-- 6. Índices para consultas históricas
create index if not exists lsh_to_stage_idx on lead_stage_history(to_stage, changed_at);
create index if not exists leads_expected_close_idx on leads(expected_close_at) where expected_close_at is not null;
create index if not exists leads_open_idx on leads(owner_id, channel) where stage not in ('ganado','perdido');
create index if not exists la_created_idx on lead_activities(created_at);
