-- Check Auditor CRM · 012 · rendimiento por canal y por responsable
-- Ejecutar DESPUÉS de 011. Solo funciones de lectura (security invoker). Idempotente.
--
-- rev_performance(p_dim, ...) devuelve una fila por canal ('channel') o por responsable ('owner'):
--   creados      leads creados en [desde, hasta) cuyo canal/responsable ACTUAL es el de la fila
--                (en responsables = "leads asignados": los creados en el período que hoy tiene cada persona)
--   abiertas/uf_abiertas/pond   stock abierto justo antes de `hasta` (y valor ponderado por probabilidad de etapa)
--   gan_n/gan_uf/per_n/per_uf    cierres netos del período (mismas reglas que rev_kpis: una reapertura anula el cierre)
--   conv_cantidad / conv_valor   ganadas/(ganadas+perdidas) por cantidad y por valor, nunca mezcladas
--   ticket       UF ganadas / ganadas con valor > 0
--   dias_cierre  promedio de (fecha del cierre - fecha de creación) de las ganadas del período
--   sin_seguimiento / uf_sin_seguimiento  abiertas sin actividad ni cambio de etapa hace más de p_stale_days
--   vencidas     abiertas cuya próxima acción (next_action_at) ya pasó
-- Como los filtros usan el valor actual de cada lead, la suma de las filas es igual al total de rev_kpis.
-- Los filtros p_owner / p_channel se aplican a ambas dimensiones; el cliente pasa null para la propia
-- dimensión cuando quiere comparar todas las filas.
-- NO hay datos de inversión publicitaria en el CRM: no se calcula costo por lead ni CAC.

create or replace function rev_performance(
  p_dim text,
  p_from timestamptz,
  p_to timestamptz,
  p_owner uuid default null,
  p_channel text default null,
  p_icp text default null,
  p_stale_days int default 7
) returns jsonb language plpgsql stable set search_path = public as $$
declare res jsonb;
begin
  if p_dim not in ('channel', 'owner') then
    raise exception 'dimensión inválida: % (usa channel u owner)', p_dim;
  end if;

  with
  g as (
    select b.id, l.created_at, l.next_action_at,
           case when p_dim = 'channel' then l.channel else l.owner_id::text end as k
    from rev_base(p_owner, p_channel, p_icp) b
    join leads l on l.id = b.id
  ),
  ev as (
    select e.lead_id, g.k,
           sum(e.w_n) w_n, sum(e.w_uf) w_uf, sum(e.w_vn) w_vn, sum(e.l_n) l_n, sum(e.l_uf) l_uf,
           max(e.changed_at) filter (where e.w_n > 0) as won_at, g.created_at
    from rev_events(p_owner, p_channel, p_icp) e
    join g on g.id = e.lead_id
    where e.changed_at >= p_from and e.changed_at < p_to
    group by e.lead_id, g.k, g.created_at
  ),
  st as (
    select s.lead_id, g.k, s.val, s.prob, g.next_action_at,
      greatest(g.created_at,
               (select max(h.changed_at) from lead_stage_history h where h.lead_id = s.lead_id and h.changed_at <= p_to),
               (select max(a.created_at) from lead_activities a where a.lead_id = s.lead_id and a.created_at <= p_to)) as last_touch
    from rev_stock(p_to - interval '1 microsecond', p_owner, p_channel, p_icp) s
    join g on g.id = s.lead_id
  ),
  keys as (select distinct k from g),
  r as (
    select keys.k,
      (select count(*) from g where g.k is not distinct from keys.k and g.created_at >= p_from and g.created_at < p_to) as creados,
      (select count(*) from st where st.k is not distinct from keys.k) as abiertas,
      (select coalesce(sum(val), 0) from st where st.k is not distinct from keys.k) as uf_abiertas,
      (select coalesce(sum(val * prob), 0) from st where st.k is not distinct from keys.k) as pond,
      (select coalesce(sum(w_n), 0) from ev where ev.k is not distinct from keys.k) as gan_n,
      (select coalesce(sum(w_uf), 0) from ev where ev.k is not distinct from keys.k) as gan_uf,
      (select coalesce(sum(w_vn), 0) from ev where ev.k is not distinct from keys.k) as gan_vn,
      (select coalesce(sum(l_n), 0) from ev where ev.k is not distinct from keys.k) as per_n,
      (select coalesce(sum(l_uf), 0) from ev where ev.k is not distinct from keys.k) as per_uf,
      (select round((avg(extract(epoch from (won_at - created_at)) / 86400.0))::numeric, 1)
         from ev where ev.k is not distinct from keys.k and w_n > 0) as dias_cierre,
      (select count(*) from st where st.k is not distinct from keys.k
         and p_to - last_touch > make_interval(days => p_stale_days)) as sin_seguimiento,
      (select coalesce(sum(val), 0) from st where st.k is not distinct from keys.k
         and p_to - last_touch > make_interval(days => p_stale_days)) as uf_sin_seguimiento,
      (select count(*) from st where st.k is not distinct from keys.k
         and next_action_at is not null and next_action_at < p_to) as vencidas
    from keys
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'clave', k, 'creados', creados, 'abiertas', abiertas, 'uf_abiertas', uf_abiertas, 'pond', pond,
      'gan_n', gan_n, 'gan_uf', gan_uf, 'per_n', per_n, 'per_uf', per_uf,
      'conv_cantidad', case when gan_n + per_n > 0 then round(100.0 * gan_n / (gan_n + per_n), 1) end,
      'conv_valor', case when gan_uf + per_uf > 0 then round(100.0 * gan_uf / (gan_uf + per_uf), 1) end,
      'ticket', case when gan_vn > 0 then round(gan_uf / gan_vn, 2) end,
      'dias_cierre', dias_cierre,
      'sin_seguimiento', sin_seguimiento, 'uf_sin_seguimiento', uf_sin_seguimiento, 'vencidas', vencidas
    ) order by gan_uf desc, uf_abiertas desc, k), '[]'::jsonb)
  into res
  from r
  where creados + abiertas + gan_n + per_n + gan_uf + per_uf <> 0;

  return res;
end $$;

-- Evolución mensual por canal: UF ganadas (cierres netos) y leads ingresados por mes calendario (Santiago).
-- Solo devuelve meses con datos; el cliente rellena con ceros.
create or replace function rev_channel_monthly(
  p_from timestamptz,
  p_to timestamptz,
  p_owner uuid default null,
  p_channel text default null,
  p_icp text default null
) returns jsonb language sql stable set search_path = public as $$
  with
  lim as (select (date_trunc('month', p_from at time zone 'America/Santiago') at time zone 'America/Santiago') as t0),
  g as (
    select b.id, l.channel, b.created_at
    from rev_base(p_owner, p_channel, p_icp) b join leads l on l.id = b.id
  ),
  gan as (
    select date_trunc('month', e.changed_at at time zone 'America/Santiago') as mes, g.channel,
           sum(e.w_uf) as uf, sum(e.w_n) as n
    from rev_events(p_owner, p_channel, p_icp) e join g on g.id = e.lead_id
    where e.changed_at >= (select t0 from lim) and e.changed_at < p_to
    group by 1, 2
  ),
  ing as (
    select date_trunc('month', g.created_at at time zone 'America/Santiago') as mes, g.channel, count(*) as n
    from g
    where g.created_at >= (select t0 from lim) and g.created_at < p_to
    group by 1, 2
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'inicio', (coalesce(gan.mes, ing.mes) at time zone 'America/Santiago'),
      'canal', coalesce(gan.channel, ing.channel),
      'gan_uf', coalesce(gan.uf, 0), 'gan_n', coalesce(gan.n, 0), 'ing_n', coalesce(ing.n, 0)
    ) order by coalesce(gan.mes, ing.mes), coalesce(gan.channel, ing.channel)), '[]'::jsonb)
  from gan full join ing on ing.mes = gan.mes and ing.channel = gan.channel
$$;
