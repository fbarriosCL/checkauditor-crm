-- Pruebas de rev_performance y rev_channel_monthly (012). Solo en una base local/desechable.
begin;
\ir _fixture.sql
create function pg_temp.hh(p_lead uuid, p_at timestamptz, p_to lead_stage) returns void language sql as $$
  insert into lead_stage_history(lead_id, from_stage, to_stage, changed_at) values (p_lead, null, p_to, p_at) $$;
create function pg_temp.perf(p_dim text, p_icp text default 'PERF', p_owner uuid default null, p_channel text default null)
returns jsonb language sql as $$ select rev_performance(p_dim, '2026-03-01', '2026-04-01', p_owner, p_channel, p_icp) $$;
create function pg_temp.row(p_rows jsonb, p_key text) returns jsonb language sql as $$
  select e from jsonb_array_elements(p_rows) e where e->>'clave' is not distinct from p_key $$;

do $$
declare
  o1 constant uuid := '00000000-0000-0000-0000-0000000000a1';
  o2 constant uuid := '00000000-0000-0000-0000-0000000000a2';
  x uuid; j jsonb; r jsonb; k jsonb; tot_g numeric; tot_n int; dim text;
begin
  -- P1 meta/O1: creada 2-mar, ganada 20-mar (18 días), 10 UF
  x := pg_temp.mk('PERF', '2026-03-02', 10, 'ganado', o1, 'meta_ads');
  perform pg_temp.hh(x, '2026-03-02', 'nuevo'); perform pg_temp.hh(x, '2026-03-20', 'ganado');
  -- P2 meta/O1: perdida 25-mar, 5 UF
  x := pg_temp.mk('PERF', '2026-03-05', 5, 'perdido', o1, 'meta_ads', 'precio');
  perform pg_temp.hh(x, '2026-03-05', 'nuevo'); perform pg_temp.hh(x, '2026-03-25', 'perdido');
  -- P3 google/O2: abierta en propuesta, sin actividad, próxima acción ya vencida
  x := pg_temp.mk('PERF', '2026-03-03', 8, 'propuesta', o2, 'google_ads');
  perform pg_temp.hh(x, '2026-03-03', 'nuevo'); perform pg_temp.hh(x, '2026-03-04', 'propuesta');
  update leads set next_action_at = '2026-03-15' where id = x;
  -- P4 google/O2: ganada 10-mar (6 días), 12 UF
  x := pg_temp.mk('PERF', '2026-03-04', 12, 'ganado', o2, 'google_ads');
  perform pg_temp.hh(x, '2026-03-04', 'nuevo'); perform pg_temp.hh(x, '2026-03-10', 'ganado');
  -- P6 google/O2: abierta con actividad reciente (31-mar): NO está sin seguimiento
  x := pg_temp.mk('PERF', '2026-03-20', 3, 'contactado', o2, 'google_ads');
  perform pg_temp.hh(x, '2026-03-20', 'nuevo'); perform pg_temp.hh(x, '2026-03-21', 'contactado');
  insert into lead_activities(lead_id, type, created_at) values (x, 'llamada', '2026-03-31');
  -- P5 sin responsable / directo: ganada 12-mar, 4 UF
  x := pg_temp.mk('PERF', '2026-03-06', 4, 'ganado', null, 'directo');
  perform pg_temp.hh(x, '2026-03-06', 'nuevo'); perform pg_temp.hh(x, '2026-03-12', 'ganado');

  -- ===== Por canal =====
  j := pg_temp.perf('channel');
  r := pg_temp.row(j, 'meta_ads');
  assert (r->>'creados')::int = 2 and (r->>'gan_n')::int = 1 and (r->>'gan_uf')::numeric = 10, 'meta: creados/ganadas';
  assert (r->>'per_n')::int = 1 and (r->>'per_uf')::numeric = 5, 'meta: perdidas';
  assert (r->>'conv_cantidad')::numeric = 50 and (r->>'conv_valor')::numeric = 66.7, 'meta: conversión por cantidad y por valor distintas';
  assert (r->>'ticket')::numeric = 10 and (r->>'dias_cierre')::numeric = 18, 'meta: ticket y ciclo';
  assert (r->>'abiertas')::int = 0 and (r->>'vencidas')::int = 0, 'meta: sin abiertas';
  r := pg_temp.row(j, 'google_ads');
  assert (r->>'creados')::int = 3 and (r->>'abiertas')::int = 2 and (r->>'uf_abiertas')::numeric = 11, 'google: pipeline';
  assert abs((r->>'pond')::numeric - (8 * 0.5 + 3 * 0.08)) < 0.001, 'google: ponderado por etapa';
  assert (r->>'gan_uf')::numeric = 12 and (r->>'conv_cantidad')::numeric = 100 and (r->>'dias_cierre')::numeric = 6, 'google: cierres y ciclo';
  assert (r->>'sin_seguimiento')::int = 1 and (r->>'uf_sin_seguimiento')::numeric = 8, 'google: solo P3 sin seguimiento';
  assert (r->>'vencidas')::int = 1, 'google: una próxima acción vencida';
  assert pg_temp.row(j, 'directo') is not null and (pg_temp.row(j, 'directo')->>'gan_uf')::numeric = 4, 'directo';

  -- ===== Por responsable (incluye "sin responsable" = clave null) =====
  j := pg_temp.perf('owner');
  assert (pg_temp.row(j, o1::text)->>'gan_uf')::numeric = 10 and (pg_temp.row(j, o2::text)->>'gan_uf')::numeric = 12, 'responsables: UF ganadas';
  assert (pg_temp.row(j, o2::text)->>'creados')::int = 3, 'O2: leads asignados';
  assert pg_temp.row(j, null) is not null and (pg_temp.row(j, null)->>'gan_uf')::numeric = 4, 'sin responsable aparece y suma';
  assert j->0->>'clave' = o2::text, 'orden por UF ganadas (O2 con 12 primero)';

  -- ===== Coherencia: las filas suman exactamente el total de los KPIs =====
  k := rev_kpis('2026-03-01', '2026-04-01', null, null, 'PERF');
  foreach dim in array array['channel','owner'] loop
    j := pg_temp.perf(dim);
    select sum((e->>'gan_uf')::numeric), sum((e->>'gan_n')::int) into tot_g, tot_n from jsonb_array_elements(j) e;
    assert tot_g = (k#>>'{ganadas,uf}')::numeric and tot_n = (k#>>'{ganadas,n}')::int, 'filas suman ganadas de rev_kpis (' || dim || ')';
    select sum((e->>'per_uf')::numeric) into tot_g from jsonb_array_elements(j) e;
    assert tot_g = (k#>>'{perdidas,uf}')::numeric, 'filas suman perdidas de rev_kpis';
    select sum((e->>'uf_abiertas')::numeric), sum((e->>'abiertas')::int) into tot_g, tot_n from jsonb_array_elements(j) e;
    assert tot_g = (k#>>'{pipeline,uf}')::numeric and tot_n = (k#>>'{pipeline,n}')::int, 'filas suman el pipeline de rev_kpis';
  end loop;

  -- Filtro por la otra dimensión: canal meta_ads => solo O1 en la tabla de responsables
  j := pg_temp.perf('owner', 'PERF', null, 'meta_ads');
  assert jsonb_array_length(j) = 1 and j->0->>'clave' = o1::text, 'filtro de canal recorta responsables';

  -- Periodo sin datos / dimensión inválida
  assert rev_performance('channel', '2020-01-01', '2020-02-01') = '[]'::jsonb, 'periodo vacío';
  begin
    perform rev_performance('team', '2026-03-01', '2026-04-01');
    assert false, 'debía fallar';
  exception when raise_exception then
    assert sqlerrm like 'dimensión inválida%', 'mensaje de dimensión';
  end;

  -- ===== Evolución mensual por canal =====
  j := rev_channel_monthly('2026-03-01', '2026-04-01', null, null, 'PERF');
  select sum((e->>'gan_uf')::numeric) into tot_g from jsonb_array_elements(j) e;
  assert tot_g = (k#>>'{ganadas,uf}')::numeric, 'serie por canal suma las UF ganadas';
  assert (select (e->>'ing_n')::int from jsonb_array_elements(j) e where e->>'canal' = 'google_ads') = 3, 'ingresados de google en marzo';
  assert (select count(distinct e->>'inicio') from jsonb_array_elements(j) e) = 1, 'un solo mes';

  raise notice 'rev_performance / rev_channel_monthly: todas las pruebas pasaron';
end $$;
rollback;
