-- Check Auditor CRM · 001 · tabla de leads + historial de etapas
-- Proyecto Supabase: ihtkakajwulpyxsonnph (solo Check Auditor)

create extension if not exists pgcrypto;

-- Etapas del pipeline
do $$ begin
  create type lead_stage as enum (
    'nuevo','contactado','calificado','demo_agendada','demo_hecha',
    'propuesta','negociacion','ganado','perdido'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type lost_reason as enum (
    'precio','timing','competencia','sin_respuesta','sin_necesidad',
    'sin_presupuesto','no_califica','otro'
  );
exception when duplicate_object then null; end $$;

-- Equipo (4 usuarios), ligado a auth.users
create table if not exists team_members (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  email text unique not null,
  role text not null default 'ventas',   -- ventas | growth | admin
  created_at timestamptz not null default now()
);

create table if not exists leads (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- Datos del formulario
  first_name text,
  company text,
  role_title text,
  email text,
  phone text,
  monthly_evaluations int,
  message text,
  rut_empresa text,

  -- Origen / atribución
  channel text not null default 'desconocido',
    -- google_ads | linkedin_ads | meta_ads | organico | email | rrss | referido | directo | desconocido
  source_form text,            -- web_demo | meta_lead_form | linkedin_lead_gen | mail_inbound | manual
  utm_source text,
  utm_medium text,
  utm_campaign text,
  utm_content text,
  utm_term text,
  gclid text,
  fbclid text,
  li_fat_id text,
  landing_page text,
  referrer text,
  first_touch jsonb,
  last_touch jsonb,

  -- Pipeline
  stage lead_stage not null default 'nuevo',
  stage_changed_at timestamptz not null default now(),
  owner_id uuid references team_members(id),
  icp text,                    -- fin_credito | fin_continuidad | compras | compl_21595 | compl_monitoreo | pyme
  lost_reason lost_reason,
  lost_detail text,
  deal_value_uf numeric(10,2),
  next_action_at timestamptz,
  first_contact_at timestamptz,
  won_at timestamptz,

  -- Consentimiento (para reactivación WhatsApp/mail)
  consent_marketing boolean not null default false,
  consent_whatsapp boolean not null default false,

  notes text,

  constraint lost_needs_reason check (stage <> 'perdido' or lost_reason is not null)
);

create index if not exists leads_stage_idx on leads(stage);
create index if not exists leads_channel_idx on leads(channel);
create index if not exists leads_created_idx on leads(created_at desc);
create index if not exists leads_email_idx on leads(lower(email));
create index if not exists leads_owner_idx on leads(owner_id);

-- Historial de etapas (para tiempo por etapa en el dashboard)
create table if not exists lead_stage_history (
  id bigint generated always as identity primary key,
  lead_id uuid not null references leads(id) on delete cascade,
  from_stage lead_stage,
  to_stage lead_stage not null,
  changed_by uuid references auth.users(id),
  changed_at timestamptz not null default now()
);
create index if not exists lsh_lead_idx on lead_stage_history(lead_id, changed_at);

-- Actividades (llamadas, mails, reuniones, notas)
create table if not exists lead_activities (
  id bigint generated always as identity primary key,
  lead_id uuid not null references leads(id) on delete cascade,
  type text not null,          -- llamada | email | whatsapp | reunion | nota
  body text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create index if not exists la_lead_idx on lead_activities(lead_id, created_at desc);

-- Trigger: updated_at, registro de cambio de etapa, fechas clave
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
  end if;
  return new;
end $$;

create or replace function leads_after_stage() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into lead_stage_history(lead_id, from_stage, to_stage, changed_by)
    values (new.id, null, new.stage, auth.uid());
  elsif new.stage is distinct from old.stage then
    insert into lead_stage_history(lead_id, from_stage, to_stage, changed_by)
    values (new.id, old.stage, new.stage, auth.uid());
  end if;
  return new;
end $$;

drop trigger if exists trg_leads_before_update on leads;
create trigger trg_leads_before_update before update on leads
  for each row execute function leads_before_update();

drop trigger if exists trg_leads_after_stage on leads;
create trigger trg_leads_after_stage after insert or update of stage on leads
  for each row execute function leads_after_stage();

-- Seguridad: solo miembros del equipo leen/escriben.
-- Los inserts desde el formulario web irán por una Edge Function con service_role (no por anon).
alter table team_members enable row level security;
alter table leads enable row level security;
alter table lead_stage_history enable row level security;
alter table lead_activities enable row level security;

create or replace function is_team_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from team_members where id = auth.uid());
$$;

drop policy if exists team_read_self on team_members;
create policy team_read_self on team_members for select to authenticated using (is_team_member());

drop policy if exists team_all_leads on leads;
create policy team_all_leads on leads for all to authenticated
  using (is_team_member()) with check (is_team_member());

drop policy if exists team_read_history on lead_stage_history;
create policy team_read_history on lead_stage_history for select to authenticated using (is_team_member());

drop policy if exists team_all_activities on lead_activities;
create policy team_all_activities on lead_activities for all to authenticated
  using (is_team_member()) with check (is_team_member());

-- Vista para el dashboard: embudo por canal
create or replace view v_funnel_by_channel with (security_invoker = true) as
select
  channel,
  count(*)                                                          as leads,
  count(*) filter (where stage not in ('nuevo'))                    as contactados,
  count(*) filter (where stage in ('demo_agendada','demo_hecha','propuesta','negociacion','ganado')) as demos,
  count(*) filter (where stage = 'ganado')                          as ganados,
  count(*) filter (where stage = 'perdido')                         as perdidos,
  round(avg(extract(epoch from (first_contact_at - created_at))/3600)::numeric, 1) as horas_a_primer_contacto
from leads
group by channel;
