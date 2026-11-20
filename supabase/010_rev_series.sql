-- Check Auditor CRM · 010 · series temporales y drill-down de Revenue Intelligence
-- Ejecutar DESPUÉS de 009. Solo funciones de lectura (security invoker). Idempotente.
--
-- rev_series: una fila por intervalo (día | semana | mes | trimestre) en hora de Santiago.
--   FLUJOS (se pueden sumar entre intervalos): ing_* ingresadas, gan_* ganadas, per_* perdidas.
--   STOCK (foto al final del intervalo, NO se suma): pip_uf / pip_n / pond_uf.
--   p_align = true no recorta el primer intervalo a p_from (útil para meses completos).
--   `en_curso` = el intervalo aún no termina (su final es posterior a p_to).
--   Si p_from es anterior al primer lead, se recorta al primer lead (histórico completo).
-- rev_drill: lista de oportunidades detrás de un número del dashboard.
--   kind: ingresadas | ganadas | perdidas | abiertas (abiertas = stock justo antes de p_to).

create or replace function rev_series(
  p_from timestamptz,
  p_to timestamptz,
  p_gran text,
  p_owner uuid default null,
  p_channel text default null,
  p_icp text default null,
  p_align boolean default false
) returns jsonb language plpgsql stable set search_path = public as $$
declare
  tz constant text := 'America/Santiago';
  step interval;
  step_days numeric;
  a timestamptz;
  res jsonb;
begin
  step := case p_gran when 'day' then interval '1 day' when 'week' then interval '1 week'
                      when 'month' then interval '1 month' when 'quarter' then interval '3 months' end;
  if step is null then
    raise exception 'granularidad inválida: % (usa day, week, month o quarter)', p_gran;
  end if;
  step_days := case p_gran when 'day' then 1 when 'week' then 7 when 'month' then 30 else 91 end;

  a := greatest(p_from, coalesce((select min(b.created_at) from rev_base(p_owner, p_channel, p_icp) b), p_to));
  if a >= p_to then return '[]'::jsonb; end if;
  if extract(epoch from (p_to - a)) / 86400 / step_days > 400 then
    raise exception 'demasiados intervalos: elige una granularidad más gruesa o un período más corto';
  end if;

  with
  bk as (
    select (s at time zone tz) as t0, ((s + step) at time zone tz) as t1
    from generate_series(date_trunc(p_gran, a at time zone tz), p_to at time zone tz, step) s
  ),
  bk2 as (
    select t0, t1,
      case when p_align then t0 else greatest(t0, a) end as f0,
      least(t1, p_to) as f1,
      least(t1, p_to) - interval '1 microsecond' as snap
    from bk
  ),
  ing as (
    select b.created_at, rev_value_at(b.id, b.created_at, b.cur_val) as v
    from rev_base(p_owner, p_channel, p_icp) b
  ),
  ev as (select * from rev_events(p_owner, p_channel, p_icp)),
  -- STOCK por intervalos: el estado y el valor de cada lead se calculan UNA vez como tramos [desde, hasta) y luego
  -- se cruzan con las fechas de corte. Equivale a rev_stage_at / rev_value_at en cada corte (hay una prueba que lo
  -- verifica contra rev_stock) pero evita recalcular cada lead en cada intervalo.
  base as materialized (select * from rev_base(p_owner, p_channel, p_icp)),
  hs as (
    select h.lead_id, h.to_stage as st, h.changed_at as f,
           coalesce(lead(h.changed_at) over (partition by h.lead_id order by h.changed_at, h.id), 'infinity'::timestamptz) as t
    from lead_stage_history h
    where not h.approx and h.lead_id in (select id from base)
  ),
  si as (
    select lead_id, st, f, t from hs
    union all   -- antes del primer registro el lead está en "nuevo" (igual que rev_stock)
    select b.id, 'nuevo'::lead_stage, b.created_at, m.f
    from base b join (select lead_id, min(f) as f from hs group by lead_id) m on m.lead_id = b.id
    where b.created_at < m.f
    union all
    select b.id, 'nuevo'::lead_stage, b.created_at, 'infinity'::timestamptz
    from base b where not exists (select 1 from hs where hs.lead_id = b.id)
  ),
  fh as (
    select f.lead_id, f.old_value, f.new_value, f.changed_at,
           row_number() over w as rn,
           lead(f.changed_at) over w as nxt
    from lead_field_history f
    where f.field = 'deal_value_uf' and f.lead_id in (select id from base)
    window w as (partition by f.lead_id order by f.changed_at, f.id)
  ),
  vi as (
    select lead_id, new_value::numeric as val, changed_at as f, coalesce(nxt, 'infinity'::timestamptz) as t from fh
    union all
    select lead_id, old_value::numeric, '-infinity'::timestamptz, changed_at from fh where rn = 1
    union all
    select b.id, b.cur_val, '-infinity'::timestamptz, 'infinity'::timestamptz
    from base b where not exists (select 1 from fh where fh.lead_id = b.id)
  ),
  stk as (
    select k.snap, count(*) as n, coalesce(sum(vi.val), 0) as uf, coalesce(sum(vi.val * coalesce(c.probability, 0)), 0) as pond
    from bk2 k
    join si on si.f <= k.snap and k.snap < si.t and si.st not in ('ganado', 'perdido')
    join base b on b.id = si.lead_id and b.created_at <= k.snap and not b.undated
    join vi on vi.lead_id = si.lead_id and vi.f <= k.snap and k.snap < vi.t
    left join stage_config c on c.stage = si.st
    where k.f0 < k.f1
    group by k.snap
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'inicio', k.t0, 'fin', k.t1, 'desde', k.f0, 'hasta', k.f1, 'en_curso', k.t1 > p_to,
      'ing_uf', (select coalesce(sum(v), 0) from ing where created_at >= k.f0 and created_at < k.f1),
      'ing_n',  (select count(*) from ing where created_at >= k.f0 and created_at < k.f1),
      'gan_uf', (select coalesce(sum(w_uf), 0) from ev where changed_at >= k.f0 and changed_at < k.f1),
      'gan_n',  (select coalesce(sum(w_n), 0) from ev where changed_at >= k.f0 and changed_at < k.f1),
      'gan_vn', (select coalesce(sum(w_vn), 0) from ev where changed_at >= k.f0 and changed_at < k.f1),
      'per_uf', (select coalesce(sum(l_uf), 0) from ev where changed_at >= k.f0 and changed_at < k.f1),
      'per_n',  (select coalesce(sum(l_n), 0) from ev where changed_at >= k.f0 and changed_at < k.f1),
      'pip_uf', coalesce(st.uf, 0), 'pip_n', coalesce(st.n, 0), 'pond_uf', coalesce(st.pond, 0)
    ) order by k.t0), '[]'::jsonb)
  into res
  from bk2 k
  left join stk st on st.snap = k.snap
  where k.f0 < k.f1;

  return res;
end $$;

create or replace function rev_drill(
  p_kind text,
  p_from timestamptz,
  p_to timestamptz,
  p_owner uuid default null,
  p_channel text default null,
  p_icp text default null
) returns jsonb language plpgsql stable set search_path = public as $$
declare res jsonb;
begin
  if p_kind not in ('ingresadas','ganadas','perdidas','abiertas') then
    raise exception 'tipo inválido: %', p_kind;
  end if;

  with r as (
    select b.id as lead_id, rev_value_at(b.id, b.created_at, b.cur_val) as uf, b.created_at as fecha, null::lead_stage as etapa
    from rev_base(p_owner, p_channel, p_icp) b
    where p_kind = 'ingresadas' and b.created_at >= p_from and b.created_at < p_to
    union all
    select x.lead_id, x.uf, x.fecha, null::lead_stage
    from (select e.lead_id, sum(e.w_uf) as uf, max(e.changed_at) as fecha
          from rev_events(p_owner, p_channel, p_icp) e
          where e.changed_at >= p_from and e.changed_at < p_to
          group by e.lead_id having sum(e.w_n) > 0) x
    where p_kind = 'ganadas'
    union all
    select x.lead_id, x.uf, x.fecha, null::lead_stage
    from (select e.lead_id, sum(e.l_uf) as uf, max(e.changed_at) as fecha
          from rev_events(p_owner, p_channel, p_icp) e
          where e.changed_at >= p_from and e.changed_at < p_to
          group by e.lead_id having sum(e.l_n) > 0) x
    where p_kind = 'perdidas'
    union all
    select s.lead_id, s.val, null::timestamptz, s.stage
    from rev_stock(p_to - interval '1 microsecond', p_owner, p_channel, p_icp) s
    where p_kind = 'abiertas'
  ),
  top as (
    select r.*, l.company, l.first_name, l.owner_id, l.channel, l.stage as etapa_actual, l.lost_reason
    from r join leads l on l.id = r.lead_id
    order by r.uf desc nulls last, l.company
    limit 1000
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', lead_id, 'empresa', company, 'nombre', first_name, 'owner_id', owner_id, 'canal', channel,
      'etapa', coalesce(etapa, etapa_actual), 'motivo', lost_reason, 'uf', uf, 'fecha', fecha
    ) order by uf desc nulls last, company), '[]'::jsonb)
  into res
  from top;
  return res;
end $$;
