-- Check Auditor CRM · 004 · botones "WhatsApp" y "Correo" en la alerta de Slack (#leads)

create or replace function slack_post_payload(payload jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare hook text;
begin
  select decrypted_secret into hook
  from vault.decrypted_secrets where name = 'slack_leads_webhook' limit 1;
  if hook is null then return; end if;
  perform net.http_post(url := hook, body := payload,
    headers := '{"Content-Type": "application/json"}'::jsonb);
end $$;

create or replace function notify_slack_new_lead() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare
  canal text;
  txt text;
  digits text;
  buttons jsonb := '[]'::jsonb;
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

  txt := format(
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
  );

  -- Teléfono en formato internacional (Chile): solo dígitos, con 56 adelante
  digits := regexp_replace(coalesce(new.phone, ''), '\D', '', 'g');
  if length(digits) = 9 then digits := '56' || digits; end if;

  if length(digits) >= 11 then
    buttons := buttons || jsonb_build_array(
      -- Slack solo acepta enlaces https en botones (tel: da invalid_blocks).
      -- El botón Llamar llegará con el CRM (crm.checkauditor.com/llamar redirige a tel:).
      jsonb_build_object('type', 'button', 'style', 'primary',
        'text', jsonb_build_object('type', 'plain_text', 'text', ':speech_balloon: WhatsApp', 'emoji', true),
        'url', 'https://wa.me/' || digits));
  end if;
  if new.email is not null then
    buttons := buttons || jsonb_build_array(
      jsonb_build_object('type', 'button',
        'text', jsonb_build_object('type', 'plain_text', 'text', ':envelope: Correo', 'emoji', true),
        'url', 'https://mail.google.com/mail/?view=cm&to=' || new.email));
  end if;

  perform slack_post_payload(jsonb_build_object(
    'text', txt,  -- respaldo para notificaciones
    'blocks', jsonb_build_array(
      jsonb_build_object('type', 'section', 'text', jsonb_build_object('type', 'mrkdwn', 'text', txt))
    ) || case when jsonb_array_length(buttons) > 0
           then jsonb_build_array(jsonb_build_object('type', 'actions', 'elements', buttons))
           else '[]'::jsonb end
  ));
  return new;
end $$;
