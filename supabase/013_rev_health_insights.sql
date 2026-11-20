-- Check Auditor CRM · 013 · salud del pipeline, riesgo de pérdida e insights automáticos
-- Ejecutar DESPUÉS de 012. Solo funciones de lectura + una tabla de umbrales editable. Idempotente.
--
-- SALUD DEL PIPELINE (rev_health_state, base de todo lo demás). Para cada oportunidad abierta en p_at:
--   days_idle     días desde la última señal: creación, último cambio de etapa o última actividad
--   days_in_stage días en la etapa actual
--   days_action_late  días de atraso de la próxima acción (next_action_at), si ya pasó
--   days_close_late   días de atraso de la fecha estimada de cierre (expected_close_at), si ya pasó
-- RIESGO DE PÉRDIDA = reglas transparentes (sin IA). Una oportunidad suma una señal por cada regla que cumple:
--   inactividad     días sin actividad ni cambio de etapa > riesgo_dias_sin_actividad
--   fecha_vencida   la fecha estimada de cierre ya pasó
--   postergaciones  la fecha estimada se movió hacia adelante >= riesgo_postergaciones veces
--   exceso_etapa    días en la etapa > riesgo_factor_etapa × promedio histórico de esa etapa
--                   (solo si hay >= riesgo_min_muestras_etapa estadías terminadas; sin base, la regla no se aplica)
-- Los umbrales viven en health_config y se pueden editar (update health_config set value = ... where key = ...).
--
-- INSIGHTS (rev_insights): reglas determinísticas que devuelven {codigo, tipo, datos}; el texto lo arma el cliente.
-- Cada regla exige un mínimo de datos para no afirmar cosas con muestras diminutas.

create table if not exists health_config (
  key text primary key,
  value numeric not null,
  descripcion text
);
insert into health_config (key, value, descripcion) values
  ('riesgo_dias_sin_actividad', 14, 'Días sin actividad ni cambio de etapa para marcar riesgo'),
  ('riesgo_postergaciones', 2, 'Veces que se pospuso la fecha estimada de cierre para marcar riesgo'),
  ('riesgo_factor_etapa', 2, 'Veces el tiempo promedio histórico de la etapa para marcar riesgo'),
  ('riesgo_min_muestras_etapa', 5, 'Estadías terminadas mínimas para usar el promedio histórico de una etapa')
on conflict (key) do nothing;

alter table health_config enable row level security;
drop policy if exists team_read_health_config on health_config;
create policy team_read_health_config on health_config for select to authenticated using (is_team_member());
drop policy if exists team_update_health_config on health_config;
create policy team_update_health_config on health_config for update to authenticated
  using (is_team_member()) with check (is_team_member());

create or replace function rev_health_state(p_at timestamptz, p_owner uuid, p_channel text, p_icp text)
returns table (
  lead_id uuid, stage lead_stage, val numeric, owner_id uuid, created_at timestamptz,
  days_idle numeric, days_age numeric, days_in_stage numeric,
  days_action_late int, days_close_late int, postponements int, stage_avg numeric,
  f_idle boolean, f_close boolean, f_postpone boolean, f_stage boolean, n_flags int
) language sql stable set search_path = public as $$
  with
  cfg as (
    select
      coalesce((select value from health_config where key = 'riesgo_dias_sin_actividad'), 14) as idle,
      coalesce((select value from health_config where key = 'riesgo_postergaciones'), 2) as post,
      coalesce((select value from health_config where key = 'riesgo_factor_etapa'), 2) as factor,
      coalesce((select value from health_config where key = 'riesgo_min_muestras_etapa'), 5) as min_n
  ),
  today as (select (p_at at time zone 'America/Santiago')::date as d),
  avgs as (
    select t.to_stage as st, avg(extract(epoch from (t.next_at - t.changed_at)) / 86400.0) as d, count(*) as n
    from (select h.to_stage, h.changed_at,
                 lead(h.changed_at) over (partition by h.lead_id order by h.changed_at, h.id) as next_at
          from lead_stage_history h
          where not h.approx and h.changed_at <= p_at) t
    where t.next_at is not null and t.next_at <= p_at and t.to_stage not in ('ganado', 'perdido')
    group by 1
  ),
  s as (
    select st.lead_id, st.stage, st.val, l.owner_id, l.created_at, l.next_action_at, l.expected_close_at as ec,
      greatest(l.created_at,
               (select max(h.changed_at) from lead_stage_history h where h.lead_id = st.lead_id and h.changed_at <= p_at),
               (select max(a.created_at) from lead_activities a where a.lead_id = st.lead_id and a.created_at <= p_at)) as lt,
      coalesce((select max(h.changed_at) from lead_stage_history h
                where h.lead_id = st.lead_id and h.changed_at <= p_at and not h.approx), l.created_at) as since,
      (select count(*)::int from lead_field_history f
       where f.lead_id = st.lead_id and f.field = 'expected_close_at' and f.changed_at <= p_at
         and f.old_value is not null and f.new_value is not null and f.new_value > f.old_value) as post
    from rev_stock(p_at - interval '1 microsecond', p_owner, p_channel, p_icp) st
    join leads l on l.id = st.lead_id
  ),
  f as (
    select s.*,
      extract(epoch from (p_at - s.lt)) / 86400.0 as idle,
      extract(epoch from (p_at - s.created_at)) / 86400.0 as age,
      extract(epoch from (p_at - s.since)) / 86400.0 as in_stage,
      case when s.next_action_at is not null and s.next_action_at < p_at
           then floor(extract(epoch from (p_at - s.next_action_at)) / 86400.0)::int end as action_late,
      case when s.ec is not null and s.ec < (select d from today) then (select d from today) - s.ec end as close_late,
      a.d as avg_d, a.n as avg_n
    from s left join avgs a on a.st = s.stage
  )
  select f.lead_id, f.stage, f.val, f.owner_id, f.created_at,
    f.idle, f.age, f.in_stage, f.action_late, f.close_late, f.post, f.avg_d,
    f.idle > (select idle from cfg),
    f.close_late is not null,
    f.post >= (select post from cfg),
    coalesce(f.avg_n >= (select min_n from cfg) and f.in_stage > (select factor from cfg) * f.avg_d, false),
    (f.idle > (select idle from cfg))::int + (f.close_late is not null)::int + (f.post >= (select post from cfg))::int
      + coalesce(f.avg_n >= (select min_n from cfg) and f.in_stage > (select factor from cfg) * f.avg_d, false)::int
  from f
$$;

create or replace function rev_health(
  p_owner uuid default null, p_channel text default null, p_icp text default null, p_at timestamptz default now()
) returns jsonb language sql stable set search_path = public as $$
  with h as materialized (select * from rev_health_state(p_at, p_owner, p_channel, p_icp)),
  hl as (select h.*, l.company, l.first_name from h join leads l on l.id = h.lead_id)
  select jsonb_build_object(
    'al', p_at,
    'abiertas', jsonb_build_object('n', (select count(*) from h), 'uf', (select coalesce(sum(val), 0) from h)),
    -- acumulado: una oportunidad sin señales hace 20 días cuenta en >3, >7 y >14
    'estancadas', (select jsonb_agg(jsonb_build_object('dias', d, 'n', x.n, 'uf', x.uf) order by d)
                   from unnest(array[3, 7, 14, 30]) d
                   cross join lateral (select count(*) as n, coalesce(sum(h.val), 0) as uf from h where h.days_idle > d) x),
    'vencidas', jsonb_build_object(
      'n', (select count(*) from h where days_action_late is not null),
      'uf', (select coalesce(sum(val), 0) from h where days_action_late is not null),
      'por_responsable', coalesce((select jsonb_agg(jsonb_build_object('owner_id', owner_id, 'n', n, 'uf', uf, 'dias_max', dmax) order by uf desc, n desc)
                                   from (select owner_id, count(*) n, coalesce(sum(val), 0) uf, max(days_action_late) dmax
                                         from h where days_action_late is not null group by owner_id) g), '[]'::jsonb),
      'top', coalesce((select jsonb_agg(jsonb_build_object('id', lead_id, 'empresa', company, 'nombre', first_name, 'owner_id', owner_id,
                                                           'etapa', stage, 'uf', val, 'dias', days_action_late) order by days_action_late desc)
                       from (select * from hl where days_action_late is not null order by days_action_late desc, val desc nulls last limit 6) t), '[]'::jsonb)),
    'antiguedad', (select jsonb_agg(jsonb_build_object('rango', r.rango, 'n', x.n, 'uf', x.uf) order by r.ord)
                   from (values (1, '0-7', 0, 7), (2, '8-15', 8, 15), (3, '16-30', 16, 30), (4, '31-60', 31, 60), (5, '60+', 61, 100000)) r(ord, rango, lo, hi)
                   cross join lateral (select count(*) as n, coalesce(sum(h.val), 0) as uf from h
                                       where floor(h.days_age) between r.lo and r.hi) x),
    'riesgo', jsonb_build_object(
      'n', (select count(*) from h where n_flags >= 1),
      'uf', (select coalesce(sum(val), 0) from h where n_flags >= 1),
      'reglas', jsonb_build_object(
        'inactividad',    (select jsonb_build_object('n', count(*), 'uf', coalesce(sum(val), 0)) from h where f_idle),
        'fecha_vencida',  (select jsonb_build_object('n', count(*), 'uf', coalesce(sum(val), 0)) from h where f_close),
        'postergaciones', (select jsonb_build_object('n', count(*), 'uf', coalesce(sum(val), 0)) from h where f_postpone),
        'exceso_etapa',   (select jsonb_build_object('n', count(*), 'uf', coalesce(sum(val), 0)) from h where f_stage)),
      'top', coalesce((select jsonb_agg(jsonb_build_object(
                  'id', lead_id, 'empresa', company, 'nombre', first_name, 'owner_id', owner_id, 'etapa', stage, 'uf', val,
                  'senales', n_flags,
                  'motivos', (select jsonb_agg(m) from (select 'inactividad' m where f_idle union all select 'fecha_vencida' where f_close
                              union all select 'postergaciones' where f_postpone union all select 'exceso_etapa' where f_stage) q)
                ) order by n_flags desc, val desc nulls last)
              from (select * from hl where n_flags >= 1 order by n_flags desc, val desc nulls last limit 8) t), '[]'::jsonb)),
    'config', (select jsonb_object_agg(key, value) from health_config)
  )
$$;

-- Lista de oportunidades detrás de un indicador de salud.
--   estancadas: sin señales hace más de p_days días | vencidas: próxima acción vencida | riesgo: con >= 1 señal
create or replace function rev_health_drill(
  p_kind text, p_days int default 7,
  p_owner uuid default null, p_channel text default null, p_icp text default null, p_at timestamptz default now()
) returns jsonb language plpgsql stable set search_path = public as $$
declare res jsonb;
begin
  if p_kind not in ('estancadas', 'vencidas', 'riesgo') then
    raise exception 'tipo inválido: %', p_kind;
  end if;
  with h as (select * from rev_health_state(p_at, p_owner, p_channel, p_icp)),
  sel as (
    select h.*, l.company, l.first_name, l.channel from h join leads l on l.id = h.lead_id
    where (p_kind = 'estancadas' and h.days_idle > p_days)
       or (p_kind = 'vencidas' and h.days_action_late is not null)
       or (p_kind = 'riesgo' and h.n_flags >= 1)
    order by h.val desc nulls last, h.lead_id
    limit 1000
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', lead_id, 'empresa', company, 'nombre', first_name, 'owner_id', owner_id, 'canal', channel, 'etapa', stage,
      'uf', val, 'motivo', null, 'fecha', null,
      'dias', case when p_kind = 'vencidas' then days_action_late else floor(days_idle)::int end,
      'motivos', (select coalesce(jsonb_agg(m), '[]'::jsonb) from (select 'inactividad' m where f_idle union all select 'fecha_vencida' where f_close
                  union all select 'postergaciones' where f_postpone union all select 'exceso_etapa' where f_stage) q)
    ) order by val desc nulls last, company), '[]'::jsonb)
  into res from sel;
  return res;
end $$;

-- Insights automáticos: reglas determinísticas con mínimos de datos. Orden: alertas, luego positivos, luego informativos.
create or replace function rev_insights(
  p_from timestamptz, p_to timestamptz,
  p_owner uuid default null, p_channel text default null, p_icp text default null
) returns jsonb language plpgsql stable set search_path = public as $$
declare
  k jsonb; ser jsonb; perf jsonb; ins jsonb := '[]'::jsonb;
  cur numeric; prv numeric; n_cur int; n_prv int;
  arr numeric[]; a numeric; b numeric; c numeric;
  top_row jsonb; tot_uf numeric; tot_n int; p75 numeric; hv_n int; hv_uf numeric;
  open_uf numeric; nodate_uf numeric; pipe numeric; pipe0 numeric; mot jsonb; mot_total int; venc_n int; venc_uf numeric;
begin
  k := rev_kpis(p_from, p_to, p_owner, p_channel, p_icp);

  -- 1. Conversión de cierres vs período anterior (mínimo 3 cierres en cada período)
  cur := (k #>> '{conversion,por_cantidad}')::numeric;
  prv := (k #>> '{conversion,prev_por_cantidad}')::numeric;
  n_cur := (k #>> '{ganadas,n}')::int + (k #>> '{perdidas,n}')::int;
  n_prv := (k #>> '{ganadas,n_prev}')::int + (k #>> '{perdidas,n_prev}')::int;
  if cur is not null and prv is not null and n_cur >= 3 and n_prv >= 3 then
    if cur - prv >= 5 then
      ins := ins || jsonb_build_array(jsonb_build_object('codigo', 'conversion_sube', 'tipo', 'positivo', 'datos', jsonb_build_object('actual', cur, 'previo', prv)));
    elsif prv - cur >= 5 then
      ins := ins || jsonb_build_array(jsonb_build_object('codigo', 'conversion_baja', 'tipo', 'alerta', 'datos', jsonb_build_object('actual', cur, 'previo', prv)));
    end if;
  end if;

  -- 2. UF ganadas: tres meses completos seguidos al alza o a la baja
  ser := rev_series(p_to - interval '5 months', p_to, 'month', p_owner, p_channel, p_icp, true);
  select array_agg((e ->> 'gan_uf')::numeric order by e ->> 'inicio') into arr
  from jsonb_array_elements(ser) e where not (e ->> 'en_curso')::boolean;
  if coalesce(array_length(arr, 1), 0) >= 3 then
    a := arr[array_length(arr, 1) - 2]; b := arr[array_length(arr, 1) - 1]; c := arr[array_length(arr, 1)];
    if a > b and b > c then
      ins := ins || jsonb_build_array(jsonb_build_object('codigo', 'ganadas_bajan', 'tipo', 'alerta', 'datos', jsonb_build_object('primero', a, 'ultimo', c)));
    elsif a < b and b < c then
      ins := ins || jsonb_build_array(jsonb_build_object('codigo', 'ganadas_suben', 'tipo', 'positivo', 'datos', jsonb_build_object('primero', a, 'ultimo', c)));
    end if;
  end if;

  -- 3. Un canal concentra la mayoría de las UF ganadas (>= 50 %, al menos 2 ganadas; solo sin filtro de canal)
  if p_channel is null then
    perf := rev_performance('channel', p_from, p_to, p_owner, null, p_icp);
    tot_uf := (k #>> '{ganadas,uf}')::numeric; tot_n := (k #>> '{ganadas,n}')::int;
    select e into top_row from jsonb_array_elements(perf) e order by (e ->> 'gan_uf')::numeric desc limit 1;
    if tot_n >= 2 and tot_uf > 0 and top_row is not null and (top_row ->> 'gan_uf')::numeric / tot_uf >= 0.5 then
      ins := ins || jsonb_build_array(jsonb_build_object('codigo', 'canal_concentra', 'tipo', 'info',
        'datos', jsonb_build_object('canal', top_row ->> 'clave', 'pct', round(100 * (top_row ->> 'gan_uf')::numeric / tot_uf), 'uf', (top_row ->> 'gan_uf')::numeric)));
    end if;
  end if;

  -- Una sola consulta del estado de salud alimenta las reglas 4, 7 y 8
  with h as materialized (
    select hs.*, l.expected_close_at as ec
    from rev_health_state(p_to, p_owner, p_channel, p_icp) hs join leads l on l.id = hs.lead_id
  )
  select (select percentile_cont(0.75) within group (order by val) from h where coalesce(val, 0) > 0),
         (select count(*) from h where val >= (select percentile_cont(0.75) within group (order by val) from h where coalesce(val, 0) > 0) and days_idle > 7),
         (select coalesce(sum(val), 0) from h where val >= (select percentile_cont(0.75) within group (order by val) from h where coalesce(val, 0) > 0) and days_idle > 7),
         (select coalesce(sum(val), 0) from h),
         (select coalesce(sum(val) filter (where ec is null), 0) from h),
         (select count(*) from h where days_action_late is not null),
         (select coalesce(sum(val), 0) from h where days_action_late is not null)
  into p75, hv_n, hv_uf, open_uf, nodate_uf, venc_n, venc_uf;

  -- 4. Oportunidades de alto valor (cuartil superior de las abiertas) sin seguimiento hace más de 7 días
  if p75 is not null and hv_n >= 1 then
    ins := ins || jsonb_build_array(jsonb_build_object('codigo', 'alto_valor_sin_seguimiento', 'tipo', 'alerta', 'datos', jsonb_build_object('n', hv_n, 'uf', hv_uf)));
  end if;

  -- 5. Pipeline activo vs cierre anterior (±15 %, base de al menos 10 UF)
  pipe := (k #>> '{pipeline,uf}')::numeric; pipe0 := (k #>> '{pipeline,uf_inicio}')::numeric;
  if pipe0 >= 10 then
    if (pipe - pipe0) / pipe0 <= -0.15 then
      ins := ins || jsonb_build_array(jsonb_build_object('codigo', 'pipeline_cae', 'tipo', 'alerta', 'datos', jsonb_build_object('actual', pipe, 'previo', pipe0, 'pct', round(100 * (pipe - pipe0) / pipe0))));
    elsif (pipe - pipe0) / pipe0 >= 0.15 then
      ins := ins || jsonb_build_array(jsonb_build_object('codigo', 'pipeline_crece', 'tipo', 'positivo', 'datos', jsonb_build_object('actual', pipe, 'previo', pipe0, 'pct', round(100 * (pipe - pipe0) / pipe0))));
    end if;
  end if;

  -- 6. Un motivo de pérdida domina (>= 40 %, al menos 5 pérdidas)
  mot := k #> '{perdidas,motivos}';
  select coalesce(sum((e ->> 'n')::int), 0) into mot_total from jsonb_array_elements(mot) e;
  if mot_total >= 5 and (mot -> 0 ->> 'n')::numeric / mot_total >= 0.4 then
    ins := ins || jsonb_build_array(jsonb_build_object('codigo', 'motivo_domina', 'tipo', 'info',
      'datos', jsonb_build_object('motivo', mot -> 0 ->> 'motivo', 'pct', round(100 * (mot -> 0 ->> 'n')::numeric / mot_total), 'n', (mot -> 0 ->> 'n')::int)));
  end if;

  -- 7. Más de la mitad del pipeline (en UF) no tiene fecha estimada de cierre
  if open_uf > 0 and nodate_uf / open_uf >= 0.5 then
    ins := ins || jsonb_build_array(jsonb_build_object('codigo', 'forecast_sin_fecha', 'tipo', 'info',
      'datos', jsonb_build_object('pct', round(100 * nodate_uf / open_uf), 'uf', nodate_uf)));
  end if;

  -- 8. Acciones vencidas
  if venc_n >= 1 then
    ins := ins || jsonb_build_array(jsonb_build_object('codigo', 'acciones_vencidas', 'tipo', 'alerta', 'datos', jsonb_build_object('n', venc_n, 'uf', venc_uf)));
  end if;

  return coalesce((select jsonb_agg(e order by case e ->> 'tipo' when 'alerta' then 1 when 'positivo' then 2 else 3 end)
                   from jsonb_array_elements(ins) e), '[]'::jsonb);
end $$;
