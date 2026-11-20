-- Check Auditor CRM · 011 · conversión por cohorte, embudo, distribución por etapa y forecast
-- Ejecutar DESPUÉS de 010. Solo funciones de lectura (security invoker). Idempotente.
--
-- DEFINICIONES (no mezclar):
--  * Conversión de cierres (mensual): ganadas / (ganadas + perdidas) de los cierres del mes. Sale de rev_series.
--  * Conversión por cohorte (rev_cohorts): de los leads CREADOS en un mes, cuántos están hoy ganados.
--    Las cohortes recientes están inmaduras (aún tienen leads abiertos): se informa `abiertos`.
--  * Embudo de cohorte (rev_funnel_cohort): sigue a los leads creados en el período y cuenta en cada
--    etapa a los que la alcanzaron alguna vez (llegar a una etapa implica haber pasado por las anteriores).
--    `perdido` nunca cuenta como avance. Los leads importados solo conservan su etapa final: se informan
--    en `incompletos` porque sus etapas intermedias no son observables.
--  * Distribución actual (rev_stage_distribution): cuántas oportunidades hay en cada etapa en un instante.
--  * Probabilidades: por defecto las de stage_config (supuestos). rev_stage_rates calcula las observadas
--    (ganadas / alcanzaron la etapa) SOLO con leads cerrados cuya trayectoria completa se conoce, y las
--    marca `enough` únicamente con >= 30 cierres y >= 10 leads que alcanzaron la etapa.
--  * Forecast: valor × probabilidad según la fecha estimada de cierre (expected_close_at). Sin fecha →
--    bloque aparte; con fecha ya vencida → bloque "vencida". Nunca se asigna un mes arbitrario.
--    Cada oportunidad cae en un solo bloque. "Comprometido" = etapas con probabilidad configurada >= 70 %.

create or replace function rev_cohorts(
  p_from timestamptz, p_to timestamptz,
  p_owner uuid default null, p_channel text default null, p_icp text default null
) returns jsonb language sql stable set search_path = public as $$
  with c as (
    select date_trunc('month', b.created_at at time zone 'America/Santiago') as mes,
           l.stage, l.deal_value_uf
    from rev_base(p_owner, p_channel, p_icp) b
    join leads l on l.id = b.id
    where b.created_at >= (date_trunc('month', p_from at time zone 'America/Santiago') at time zone 'America/Santiago')
      and b.created_at < p_to
  ),
  g as (
    select mes, count(*) n,
      count(*) filter (where stage = 'ganado') as ganados,
      count(*) filter (where stage = 'perdido') as perdidos,
      count(*) filter (where stage not in ('ganado','perdido')) as abiertos,
      coalesce(sum(deal_value_uf) filter (where stage = 'ganado'), 0) as uf_ganadas
    from c group by mes
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'inicio', (mes at time zone 'America/Santiago'), 'n', n, 'ganados', ganados, 'perdidos', perdidos,
      'abiertos', abiertos, 'uf_ganadas', uf_ganadas,
      'conv_ingresados', round(100.0 * ganados / n, 1),
      'conv_resueltos', case when ganados + perdidos > 0 then round(100.0 * ganados / (ganados + perdidos), 1) end
    ) order by mes), '[]'::jsonb)
  from g
$$;

create or replace function rev_funnel_cohort(
  p_from timestamptz, p_to timestamptz,
  p_owner uuid default null, p_channel text default null, p_icp text default null
) returns jsonb language sql stable set search_path = public as $$
  with c as (
    select b.id, l.deal_value_uf as val, l.stage,
      greatest(
        coalesce((select max(h.to_stage) from lead_stage_history h
                  where h.lead_id = b.id and h.to_stage <> 'perdido' and not h.approx), 'nuevo'::lead_stage),
        case when l.stage <> 'perdido' then l.stage else 'nuevo'::lead_stage end
      ) as mx,
      (select count(*) from lead_stage_history h where h.lead_id = b.id and not h.approx) as filas
    from rev_base(p_owner, p_channel, p_icp) b
    join leads l on l.id = b.id
    where b.created_at >= p_from and b.created_at < p_to
  ),
  st as (
    select s as etapa from unnest(enum_range(null::lead_stage)) s where s <> 'perdido'
  ),
  dur as (
    select t.to_stage as etapa, avg(extract(epoch from (t.next_at - t.changed_at)) / 86400.0) as dias
    from (select h.lead_id, h.to_stage, h.changed_at,
                 lead(h.changed_at) over (partition by h.lead_id order by h.changed_at, h.id) as next_at
          from lead_stage_history h
          where not h.approx and h.lead_id in (select id from c)) t
    where t.next_at is not null and t.to_stage not in ('ganado','perdido')
    group by 1
  )
  select jsonb_build_object(
    'total', (select count(*) from c),
    'incompletos', (select count(*) from c where filas <= 1 and stage <> 'nuevo'),
    'etapas', (select jsonb_agg(jsonb_build_object(
        'etapa', st.etapa,
        'alcanzaron', (select count(*) from c where c.mx >= st.etapa),
        'uf', (select coalesce(sum(val), 0) from c where c.mx >= st.etapa),
        'dias_prom', (select round(d.dias::numeric, 1) from dur d where d.etapa = st.etapa)
      ) order by st.etapa) from st)
  )
$$;

create or replace function rev_stage_distribution(
  p_t timestamptz default now(),
  p_owner uuid default null, p_channel text default null, p_icp text default null
) returns jsonb language sql stable set search_path = public as $$
  with s as (select * from rev_stock(p_t - interval '1 microsecond', p_owner, p_channel, p_icp)),
  st as (select e as etapa from unnest(enum_range(null::lead_stage)) e where e not in ('ganado','perdido'))
  select jsonb_build_object(
    'total_n', (select count(*) from s),
    'total_uf', (select coalesce(sum(val), 0) from s),
    'etapas', (select jsonb_agg(jsonb_build_object(
        'etapa', st.etapa,
        'n', (select count(*) from s where s.stage = st.etapa),
        'uf', (select coalesce(sum(val), 0) from s where s.stage = st.etapa),
        'sin_valor', (select count(*) from s where s.stage = st.etapa and coalesce(val, 0) <= 0)
      ) order by st.etapa) from st)
  )
$$;

-- Probabilidad observada por etapa (global: no se calibra con subconjuntos pequeños).
create or replace function rev_stage_rates()
returns table (stage lead_stage, reached_n int, won_n int, observed numeric, prob_config numeric, enough boolean)
language sql stable set search_path = public as $$
  with r as (
    select l.id, l.stage as final_stage,
      greatest(
        coalesce((select max(h.to_stage) from lead_stage_history h
                  where h.lead_id = l.id and h.to_stage <> 'perdido' and not h.approx), 'nuevo'::lead_stage),
        case when l.stage <> 'perdido' then l.stage else 'nuevo'::lead_stage end
      ) as mx
    from leads l
    where l.stage in ('ganado','perdido')
      and exists (select 1 from lead_stage_history h where h.lead_id = l.id and h.to_stage = 'nuevo' and not h.approx)
  ),
  tot as (select count(*) as n from r)
  select s.e, (select count(*)::int from r where r.mx >= s.e),
    (select count(*)::int from r where r.mx >= s.e and r.final_stage = 'ganado'),
    (select case when count(*) > 0 then round(count(*) filter (where r.final_stage = 'ganado')::numeric / count(*), 3) end
       from r where r.mx >= s.e),
    c.probability,
    (select n from tot) >= 30 and (select count(*) from r where r.mx >= s.e) >= 10
  from unnest(enum_range(null::lead_stage)) s(e)
  left join stage_config c on c.stage = s.e
  where s.e not in ('ganado','perdido')
$$;

create or replace function rev_forecast(
  p_owner uuid default null, p_channel text default null, p_icp text default null,
  p_observed boolean default false, p_at timestamptz default now()
) returns jsonb language sql stable set search_path = public as $$
  with
  loc as (select (p_at at time zone 'America/Santiago')::date as today,
                 date_trunc('month', p_at at time zone 'America/Santiago')::date as m0),
  rates as (select * from rev_stage_rates()),
  s as (
    select st.lead_id, st.stage, st.val, st.prob as prob_cfg,
      case when coalesce(p_observed, false) and r.enough then r.observed else st.prob end as prob,
      l.expected_close_at as ec, l.company, l.first_name
    from rev_stock(p_at - interval '1 microsecond', p_owner, p_channel, p_icp) st
    join leads l on l.id = st.lead_id
    left join rates r on r.stage = st.stage
  ),
  k as (
    select s.*,
      case when ec is null then 'sin_fecha'
           when ec < (select today from loc) then 'vencida'
           when ec < (select m0 from loc) + interval '1 month' then 'mes0'
           when ec < (select m0 from loc) + interval '2 months' then 'mes1'
           when ec < (select m0 from loc) + interval '3 months' then 'mes2'
           else 'despues' end as bloque
    from s
  ),
  b as (
    select bloque, count(*) n, coalesce(sum(val), 0) uf, coalesce(sum(val * prob), 0) pond,
           count(*) filter (where coalesce(val, 0) <= 0) sin_valor
    from k group by bloque
  ),
  won as (
    select coalesce(sum(w_uf), 0) uf, coalesce(sum(w_n), 0) n
    from rev_events(p_owner, p_channel, p_icp)
    where changed_at >= ((select m0 from loc)::timestamp at time zone 'America/Santiago') and changed_at < p_at
  )
  select jsonb_build_object(
    'al', p_at,
    'total', jsonb_build_object('n', (select count(*) from k), 'uf', (select coalesce(sum(val), 0) from k),
                                'pond', (select coalesce(sum(val * prob), 0) from k)),
    'comprometido', jsonb_build_object(
      'n', (select count(*) from k where prob_cfg >= 0.7),
      'uf', (select coalesce(sum(val), 0) from k where prob_cfg >= 0.7),
      'pond', (select coalesce(sum(val * prob), 0) from k where prob_cfg >= 0.7)),
    'bloques', (select jsonb_object_agg(x.bloque, jsonb_build_object(
        'n', coalesce(b.n, 0), 'uf', coalesce(b.uf, 0), 'pond', coalesce(b.pond, 0), 'sin_valor', coalesce(b.sin_valor, 0)))
      from (values ('mes0'), ('mes1'), ('mes2'), ('despues'), ('vencida'), ('sin_fecha')) x(bloque)
      left join b on b.bloque = x.bloque),
    'ganado_mes', jsonb_build_object('uf', (select uf from won), 'n', (select n from won)),
    'proximas', coalesce((select jsonb_agg(jsonb_build_object(
        'id', lead_id, 'empresa', company, 'nombre', first_name, 'etapa', stage, 'uf', val, 'prob', prob, 'fecha', ec)
        order by ec, val desc nulls last)
      from (select * from k where ec >= (select today from loc) and ec < (select today from loc) + 30
            order by ec, val desc nulls last limit 8) t), '[]'::jsonb),
    'calibracion', jsonb_build_object(
      'cierres_completos', (select count(*) from leads l where l.stage in ('ganado','perdido')
         and exists (select 1 from lead_stage_history h where h.lead_id = l.id and h.to_stage = 'nuevo' and not h.approx)),
      'disponible', (select coalesce(bool_or(enough), false) from rates),
      'usando_observado', coalesce(p_observed, false) and (select coalesce(bool_or(enough), false) from rates))
  )
$$;
