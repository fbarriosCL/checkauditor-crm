-- Check Auditor CRM · 009 · base analítica y KPIs ejecutivos de Revenue Intelligence
-- Ejecutar DESPUÉS de 007 y 008. Solo crea funciones de lectura (security invoker: respetan el RLS del equipo).
-- Es idempotente (create or replace).
--
-- REGLAS DE CÁLCULO (todas reproducibles desde el historial)
--  * Stock (pipeline activo / ponderado): estado en un instante t. Un lead está abierto en t si ya
--    existía (created_at <= t) y su última etapa registrada hasta t no es ganado ni perdido.
--  * Flujo (ganadas / perdidas): se suman EVENTOS de cierre del historial de etapas en [desde, hasta).
--    Cada cambio de etapa aporta +1 a su estado final (si es ganado/perdido) y -1 al estado que deja
--    (si era ganado/perdido). Así una reapertura anula el cierre previo y un lead nunca cuenta dos
--    veces: la suma de todos los eventos de un lead es 1 si hoy está cerrado y 0 si está abierto.
--  * UF de un evento = valor UF vigente en el instante del evento (rev_value_at). Corregir el valor
--    DESPUÉS del cierre no reescribe el mes en que se cerró; queda en lead_field_history.
--  * Atribución a responsable / canal / tipo de cliente: se usa el valor ACTUAL del lead, así cada
--    lead aparece en un solo responsable y los totales por responsable suman el total global.
--  * Filas de historial con approx = true (cierres importados sin fecha) quedan fuera del stock y de
--    los flujos, y se informan aparte en `sin_fecha`.
--  * Ticket promedio = UF ganadas / ganadas CON valor > 0 (una ganada sin valor no baja el promedio).
--  * Conversión histórica = ganadas / (ganadas + perdidas) acumuladas hasta la fecha de corte.
--  * Cierre anterior (inicio del periodo) = estado justo antes de `desde`; fin = justo antes de `hasta`.

-- Etapa de un lead en el instante t (null si aún no tenía historial).
create or replace function rev_stage_at(p_lead uuid, p_t timestamptz)
returns lead_stage language sql stable set search_path = public as $$
  select to_stage from lead_stage_history
  where lead_id = p_lead and changed_at <= p_t and not approx
  order by changed_at desc, id desc limit 1
$$;

-- Valor UF/mes de un lead en el instante t, a partir de lead_field_history.
--  1) último cambio registrado hasta t  -> su valor nuevo
--  2) si no hay, primer cambio posterior -> su valor anterior
--  3) si nunca cambió                    -> valor actual (p_current)
create or replace function rev_value_at(p_lead uuid, p_t timestamptz, p_current numeric)
returns numeric language sql stable set search_path = public as $$
  select case
    when exists (select 1 from lead_field_history
                 where lead_id = p_lead and field = 'deal_value_uf' and changed_at <= p_t)
      then (select new_value::numeric from lead_field_history
            where lead_id = p_lead and field = 'deal_value_uf' and changed_at <= p_t
            order by changed_at desc, id desc limit 1)
    when exists (select 1 from lead_field_history
                 where lead_id = p_lead and field = 'deal_value_uf' and changed_at > p_t)
      then (select old_value::numeric from lead_field_history
            where lead_id = p_lead and field = 'deal_value_uf' and changed_at > p_t
            order by changed_at asc, id asc limit 1)
    else p_current
  end
$$;

-- Leads que pasan los filtros (responsable / canal / tipo de cliente actuales).
create or replace function rev_base(p_owner uuid, p_channel text, p_icp text)
returns table (id uuid, created_at timestamptz, cur_val numeric, lost_reason text, undated boolean)
language sql stable set search_path = public as $$
  select l.id, l.created_at, l.deal_value_uf, l.lost_reason::text,
    exists (select 1 from lead_stage_history h where h.lead_id = l.id and h.approx)
  from leads l
  where (p_owner is null or l.owner_id = p_owner)
    and (p_channel is null or l.channel = p_channel)
    and (p_icp is null or l.icp = p_icp)
$$;

-- Eventos netos de cierre (ver reglas arriba). Una fila por transición que entra o sale de ganado/perdido.
create or replace function rev_events(p_owner uuid, p_channel text, p_icp text)
returns table (lead_id uuid, changed_at timestamptz, w_n int, w_uf numeric, w_vn int, l_n int, l_uf numeric)
language sql stable set search_path = public as $$
  with b as (select * from rev_base(p_owner, p_channel, p_icp)),
  tr as (
    select h.lead_id, h.changed_at, h.to_stage,
      lag(h.to_stage) over w as prev_stage,
      lag(h.changed_at) over w as prev_at
    from lead_stage_history h
    where not h.approx and h.lead_id in (select id from b)
    window w as (partition by h.lead_id order by h.changed_at, h.id)
  ),
  ev as (
    select t.lead_id, t.changed_at,
      coalesce(t.to_stage = 'ganado', false) as to_w,   coalesce(t.prev_stage = 'ganado', false) as from_w,
      coalesce(t.to_stage = 'perdido', false) as to_l,  coalesce(t.prev_stage = 'perdido', false) as from_l,
      coalesce(rev_value_at(t.lead_id, t.changed_at, b.cur_val), 0) as v_now,
      case when t.prev_stage in ('ganado','perdido')
           then coalesce(rev_value_at(t.lead_id, t.prev_at, b.cur_val), 0) else 0 end as v_prev
    from tr t join b on b.id = t.lead_id
    where t.to_stage in ('ganado','perdido') or t.prev_stage in ('ganado','perdido')
  )
  select lead_id, changed_at,
    to_w::int - from_w::int,
    to_w::int * v_now - from_w::int * v_prev,
    (to_w and v_now > 0)::int - (from_w and v_prev > 0)::int,
    to_l::int - from_l::int,
    to_l::int * v_now - from_l::int * v_prev
  from ev
$$;

-- Oportunidades abiertas en el instante t, con su valor y probabilidad de etapa vigentes entonces.
create or replace function rev_stock(p_t timestamptz, p_owner uuid, p_channel text, p_icp text)
returns table (lead_id uuid, stage lead_stage, val numeric, prob numeric)
language sql stable set search_path = public as $$
  select b.id, s.st, v.val, coalesce(c.probability, 0)
  from rev_base(p_owner, p_channel, p_icp) b
  cross join lateral (select coalesce(rev_stage_at(b.id, p_t), 'nuevo'::lead_stage) as st) s
  cross join lateral (select rev_value_at(b.id, p_t, b.cur_val) as val) v
  left join stage_config c on c.stage = s.st
  where b.created_at <= p_t and not b.undated and s.st not in ('ganado','perdido')
$$;

-- KPIs ejecutivos. Periodo actual = [p_from, p_to); periodo anterior = mismo largo justo antes.
create or replace function rev_kpis(
  p_from timestamptz,
  p_to timestamptz,
  p_owner uuid default null,
  p_channel text default null,
  p_icp text default null
) returns jsonb language sql stable set search_path = public as $$
with
ev2 as (select * from rev_events(p_owner, p_channel, p_icp)),
cur as (
  select coalesce(sum(w_n),0) w_n, coalesce(sum(w_uf),0) w_uf, coalesce(sum(w_vn),0) w_vn,
         coalesce(sum(l_n),0) l_n, coalesce(sum(l_uf),0) l_uf
  from ev2 where changed_at >= p_from and changed_at < p_to
),
prv as (
  select coalesce(sum(w_n),0) w_n, coalesce(sum(w_uf),0) w_uf, coalesce(sum(w_vn),0) w_vn,
         coalesce(sum(l_n),0) l_n, coalesce(sum(l_uf),0) l_uf
  from ev2 where changed_at >= p_from - (p_to - p_from) and changed_at < p_from
),
hist as (
  select coalesce(sum(w_n),0) w_n, coalesce(sum(l_n),0) l_n
  from ev2 where changed_at < p_to
),
-- Motivos de pérdida: leads con pérdida neta > 0 en el periodo
reasons as (
  select coalesce(b.lost_reason, 'otro') as reason, count(*) as n, sum(x.uf) as uf
  from (select lead_id, sum(l_n) n, sum(l_uf) uf from ev2
        where changed_at >= p_from and changed_at < p_to group by lead_id having sum(l_n) > 0) x
  join rev_base(p_owner, p_channel, p_icp) b on b.id = x.lead_id
  group by 1
),
s_to   as (select * from rev_stock(p_to   - interval '1 microsecond', p_owner, p_channel, p_icp)),
s_from as (select * from rev_stock(p_from - interval '1 microsecond', p_owner, p_channel, p_icp)),
und as (select count(*) n, coalesce(sum(cur_val),0) uf from rev_base(p_owner, p_channel, p_icp) where undated)
select jsonb_build_object(
  'desde', p_from, 'hasta', p_to,
  'pipeline', jsonb_build_object(
    'uf',        (select coalesce(sum(val),0) from s_to),
    'n',         (select count(*) from s_to),
    'sin_valor', (select count(*) from s_to where coalesce(val,0) <= 0),
    'uf_inicio', (select coalesce(sum(val),0) from s_from),
    'n_inicio',  (select count(*) from s_from)),
  'ponderado', jsonb_build_object(
    'uf',        (select coalesce(sum(val * prob),0) from s_to),
    'uf_inicio', (select coalesce(sum(val * prob),0) from s_from)),
  'ganadas', jsonb_build_object(
    'uf', (select w_uf from cur), 'n', (select w_n from cur),
    'uf_prev', (select w_uf from prv), 'n_prev', (select w_n from prv)),
  'perdidas', jsonb_build_object(
    'uf', (select l_uf from cur), 'n', (select l_n from cur),
    'uf_prev', (select l_uf from prv), 'n_prev', (select l_n from prv),
    'motivos', coalesce((select jsonb_agg(jsonb_build_object('motivo', reason, 'n', n, 'uf', uf) order by n desc, uf desc)
                         from reasons), '[]'::jsonb)),
  'conversion', jsonb_build_object(
    'por_cantidad', (select case when w_n + l_n > 0 then round(100.0 * w_n / (w_n + l_n), 1) end from cur),
    'por_valor',    (select case when w_uf + l_uf > 0 then round(100.0 * w_uf / (w_uf + l_uf), 1) end from cur),
    'prev_por_cantidad', (select case when w_n + l_n > 0 then round(100.0 * w_n / (w_n + l_n), 1) end from prv),
    'prev_por_valor',    (select case when w_uf + l_uf > 0 then round(100.0 * w_uf / (w_uf + l_uf), 1) end from prv),
    'historica',    (select case when w_n + l_n > 0 then round(100.0 * w_n / (w_n + l_n), 1) end from hist),
    'cierres', (select w_n + l_n from cur)),
  'ticket', jsonb_build_object(
    'uf',      (select case when w_vn > 0 then round(w_uf / w_vn, 2) end from cur),
    'uf_prev', (select case when w_vn > 0 then round(w_uf / w_vn, 2) end from prv),
    'n_con_valor', (select w_vn from cur)),
  'sin_fecha', jsonb_build_object('n', (select n from und), 'uf', (select uf from und))
)
$$;
