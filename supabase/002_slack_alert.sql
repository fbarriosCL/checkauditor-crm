-- Check Auditor CRM · 002 · alerta a Slack (#leads) cuando entra un lead nuevo
-- La URL del webhook vive en Vault (secreto 'slack_leads_webhook'); nunca queda en el código.

create extension if not exists pg_net;

create or replace function notify_slack_new_lead() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare
  hook text;
  canal text;
  txt text;
begin
  select decrypted_secret into hook
  from vault.decrypted_secrets where name = 'slack_leads_webhook' limit 1;
  if hook is null then
    return new; -- sin webhook configurado: no alerta, no falla el insert
  end if;

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

  txt := format(
    E':new: *Nuevo lead* · %s\n*%s* · %s en *%s*\n:bar_chart: Evalúa %s empresas al mes\n:envelope: %s · :phone: %s\n:dart: Canal: *%s*%s\n:speech_balloon: %s',
    to_char(new.created_at at time zone 'America/Santiago', 'DD-MM-YYYY HH24:MI'),
    coalesce(new.first_name, 'Sin nombre'),
    coalesce(new.role_title, 'Sin cargo'),
    coalesce(new.company, 'Sin empresa'),
    coalesce(new.monthly_evaluations::text, '—'),
    coalesce(new.email, '—'),
    coalesce(new.phone, '—'),
    canal,
    case when new.utm_campaign is not null then ' · Campaña: ' || new.utm_campaign else '' end,
    left(coalesce(new.message, '—'), 500)
  );

  perform net.http_post(
    url := hook,
    body := jsonb_build_object('text', txt),
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
  return new;
end $$;

drop trigger if exists trg_leads_slack on leads;
create trigger trg_leads_slack after insert on leads
  for each row execute function notify_slack_new_lead();
