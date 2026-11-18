-- Check Auditor CRM · 003 · equipo, responsable por defecto (Tomas) y menciones en Slack
-- team_members pasa a ser la lista de autorizados: existe antes de que la persona inicie sesión.
-- Al primer login (auth.users), se enlaza por correo con user_id.

-- 1. team_members independiente de auth.users
alter table team_members drop constraint if exists team_members_id_fkey;
alter table team_members alter column id set default gen_random_uuid();
alter table team_members add column if not exists user_id uuid unique references auth.users(id) on delete set null;
alter table team_members add column if not exists slack_id text;
alter table team_members add column if not exists is_default_owner boolean not null default false;
alter table team_members add column if not exists active boolean not null default true;

insert into team_members (full_name, email, role, slack_id, is_default_owner) values
  ('Tomas Witto',     'tomas@checkauditor.com',   'ceo',        'U0CJPK9LY5P', true),
  ('Felipe Barrios',  'felipe@checkauditor.com',  'cto',        'U0CJPKAB525', false),
  ('Hugo Valenzuela', 'hugo@checkauditor.com',    'contenidos', 'U0CJFFTEYH1', false),
  ('Rodrigo',         'rodrigo@checkauditor.com', 'growth',     'U0CKG3Y3X88', false)
on conflict (email) do update set
  full_name = excluded.full_name, role = excluded.role,
  slack_id = excluded.slack_id, is_default_owner = excluded.is_default_owner;

-- Enlazar usuarios que ya existan en auth
update team_members t set user_id = u.id
from auth.users u where lower(u.email) = lower(t.email) and t.user_id is null;

-- Al crear un usuario en auth, enlazarlo si su correo está autorizado
create or replace function link_team_member() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update team_members set user_id = new.id
  where lower(email) = lower(new.email) and user_id is null;
  return new;
end $$;

drop trigger if exists trg_link_team_member on auth.users;
create trigger trg_link_team_member after insert on auth.users
  for each row execute function link_team_member();

create or replace function is_team_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from team_members where user_id = auth.uid() and active);
$$;

-- 2. Responsable por defecto
create or replace function leads_default_owner() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.owner_id is null then
    select id into new.owner_id from team_members
    where is_default_owner and active limit 1;
  end if;
  return new;
end $$;

drop trigger if exists trg_leads_default_owner on leads;
create trigger trg_leads_default_owner before insert on leads
  for each row execute function leads_default_owner();

-- 3. Slack: envío común + mención del responsable
create or replace function slack_post(txt text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare hook text;
begin
  select decrypted_secret into hook
  from vault.decrypted_secrets where name = 'slack_leads_webhook' limit 1;
  if hook is null then return; end if;
  perform net.http_post(
    url := hook,
    body := jsonb_build_object('text', txt),
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
end $$;

create or replace function slack_mention(member uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce('<@' || slack_id || '>', full_name) from team_members where id = member;
$$;

create or replace function notify_slack_new_lead() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare canal text;
begin
  canal := case new.channel
    when 'google_ads' then 'Google Ads'
    when 'meta_ads' then 'Meta Ads'
    when 'linkedin_ads' then 'LinkedIn Ads'
    when 'email' then 'Email'
    when 'rrss' then 'Redes sociales'
    when 'organico' then 'Orgánico'
    when 'ia' then 'IA (ChatGPT, etc.)'
    when 'referido' then 'Referido'
    when 'directo' then 'Directo'
    else coalesce(new.channel, 'Desconocido')
  end;

  perform slack_post(format(
    E':new: *Nuevo lead* · %s → %s\n*%s* · %s en *%s*\n:bar_chart: Evalúa %s empresas al mes\n:envelope: %s · :phone: %s\n:dart: Canal: *%s*%s\n:speech_balloon: %s',
    to_char(new.created_at at time zone 'America/Santiago', 'DD-MM-YYYY HH24:MI'),
    coalesce(slack_mention(new.owner_id), 'sin responsable'),
    coalesce(new.first_name, 'Sin nombre'),
    coalesce(new.role_title, 'Sin cargo'),
    coalesce(new.company, 'Sin empresa'),
    coalesce(new.monthly_evaluations::text, '—'),
    coalesce(new.email, '—'),
    coalesce(new.phone, '—'),
    canal,
    case when new.utm_campaign is not null then ' · Campaña: ' || new.utm_campaign else '' end,
    left(coalesce(new.message, '—'), 500)
  ));
  return new;
end $$;

create or replace function notify_slack_reassign() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform slack_post(format(
    E':arrows_counterclockwise: Lead *%s* (%s) reasignado a %s',
    coalesce(new.company, 'Sin empresa'),
    coalesce(new.first_name, 'Sin nombre'),
    coalesce(slack_mention(new.owner_id), 'sin responsable')
  ));
  return new;
end $$;

drop trigger if exists trg_leads_slack_reassign on leads;
create trigger trg_leads_slack_reassign after update of owner_id on leads
  for each row when (new.owner_id is distinct from old.owner_id)
  execute function notify_slack_reassign();
