-- Pruebas de rev_series y rev_drill (010). Solo en una base local/desechable (ver rev_kpis_test.sql).
begin;
\ir _fixture.sql
create function pg_temp.s(p_from text, p_to text, p_gran text, p_icp text default null, p_align boolean default false)
returns jsonb language sql as $$ select rev_series(p_from::timestamptz, p_to::timestamptz, p_gran, null, null, p_icp, p_align) $$;
create function pg_temp.d(p_kind text, p_from text, p_to text, p_icp text default null)
returns jsonb language sql as $$ select rev_drill(p_kind, p_from::timestamptz, p_to::timestamptz, null, null, p_icp) $$;

do $$
declare
  j jsonb; k jsonb; r jsonb; i int; s_gan numeric; s_gan_n int; s_per numeric; s_per_n int; s_ing numeric;
begin
  -- B: ingresa en enero, pipeline hasta marzo, gana en marzo (series mensuales alineadas)
  j := pg_temp.s('2026-01-01', '2026-05-01', 'month', 'B', true);
  assert jsonb_array_length(j) = 4, 'B: cuatro meses';
  assert (j#>>'{0,ing_uf}')::numeric = 20 and (j#>>'{1,ing_uf}')::numeric = 0, 'B: ingreso solo en enero';
  assert (j#>>'{0,pip_uf}')::numeric = 20 and (j#>>'{1,pip_uf}')::numeric = 20, 'B: en pipeline ene y feb';
  assert (j#>>'{2,gan_uf}')::numeric = 20 and (j#>>'{2,pip_uf}')::numeric = 0, 'B: gana y sale del pipeline en marzo';
  assert (j#>>'{3,pip_uf}')::numeric = 0 and (j#>>'{3,gan_uf}')::numeric = 0, 'B: abril vacío';

  -- D: reapertura. Feb +5, marzo neto 0 y vuelve al stock mientras está reabierta
  j := pg_temp.s('2026-01-01', '2026-05-01', 'month', 'D', true);
  assert (j#>>'{1,gan_uf}')::numeric = 5 and (j#>>'{2,gan_uf}')::numeric = 0, 'D: feb 5, marzo neto 0';
  assert (j#>>'{1,pip_uf}')::numeric = 0 and (j#>>'{2,pip_uf}')::numeric = 0, 'D: cerrada a fin de feb y de marzo';
  j := pg_temp.s('2026-03-01', '2026-03-10', 'day', 'D');
  assert (j#>>'{9,pip_uf}')::numeric = 5 or (j#>>'{8,pip_uf}')::numeric = 5, 'D: reabierta 3-mar aparece en el pipeline diario';
  -- Los intervalos son días de Santiago: el primero (índice 0) es el 28-feb local porque p_from es 1-mar 00:00 UTC,
  -- y la reapertura del 3-mar 00:00 UTC ocurre el 2-mar 21:00 local (índice 2).
  assert (j#>>'{0,pip_uf}')::numeric = 0 and (j#>>'{1,pip_uf}')::numeric = 0, 'D: 28-feb y 1-mar siguen cerrada';
  assert (j#>>'{2,pip_uf}')::numeric = 5, 'D: entra al pipeline el 2-mar local';

  -- E: el stock usa el valor vigente en cada fecha (4 hasta el 10-mar)
  j := pg_temp.s('2026-02-01', '2026-03-20', 'week', 'E');
  assert (j#>>'{0,pip_uf}')::numeric = 4, 'E: primera semana con valor 4';

  -- M: cierre el 1-mar 02:00 UTC cae en febrero (hora de Santiago)
  j := pg_temp.s('2026-02-01', '2026-04-01', 'month', 'M', true);
  assert (j#>>'{0,gan_uf}')::numeric = 6 and (j#>>'{1,gan_uf}')::numeric = 0, 'M: gana en febrero local, no en marzo';
  j := pg_temp.s('2026-02-01', '2026-04-01', 'month', 'M', false);
  assert (j#>>'{0,gan_uf}')::numeric = 6, 'M (sin alinear): febrero conserva el cierre';

  -- Trimestre y semana: bordes de intervalo
  j := pg_temp.s('2026-01-01', '2026-07-01', 'quarter', 'B', true);
  assert jsonb_array_length(j) = 2 and (j#>>'{0,gan_uf}')::numeric = 20 and (j#>>'{0,ing_uf}')::numeric = 20, 'trimestre Q1 de B';
  assert (j#>>'{1,pip_uf}')::numeric = 0, 'trimestre Q2 vacío';

  -- Intervalo en curso
  j := pg_temp.s('2026-03-01', '2026-03-15', 'month', 'A', true);
  assert (j#>>'{0,en_curso}')::boolean, 'marzo parcial marcado en curso';

  -- Período sin datos y sin leads
  j := pg_temp.s('2020-01-01', '2020-03-01', 'month');
  assert j = '[]'::jsonb, 'sin leads en el rango: lista vacía';

  -- Coherencia con KPIs: la suma de los flujos de la serie = KPI del mismo período, y el último stock = pipeline del KPI
  k := rev_kpis('2026-01-01', '2026-05-01');
  j := pg_temp.s('2026-01-01', '2026-05-01', 'week');
  select sum((e->>'gan_uf')::numeric), sum((e->>'gan_n')::int), sum((e->>'per_uf')::numeric), sum((e->>'per_n')::int)
    into s_gan, s_gan_n, s_per, s_per_n from jsonb_array_elements(j) e;
  assert s_gan = (k#>>'{ganadas,uf}')::numeric and s_gan_n = (k#>>'{ganadas,n}')::int, 'serie vs KPI: ganadas';
  assert s_per = (k#>>'{perdidas,uf}')::numeric and s_per_n = (k#>>'{perdidas,n}')::int, 'serie vs KPI: perdidas';
  assert (j#>>'{-1,pip_uf}')::numeric = (k#>>'{pipeline,uf}')::numeric
     and (j#>>'{-1,pip_n}')::int = (k#>>'{pipeline,n}')::int, 'serie vs KPI: pipeline al cierre';
  -- ...y no importa la granularidad
  j := pg_temp.s('2026-01-01', '2026-05-01', 'day');
  select sum((e->>'gan_uf')::numeric) into s_gan from jsonb_array_elements(j) e;
  assert s_gan = (k#>>'{ganadas,uf}')::numeric, 'serie diaria suma lo mismo';
  j := pg_temp.s('2026-01-01', '2026-05-01', 'month');
  select sum((e->>'gan_uf')::numeric), sum((e->>'ing_uf')::numeric) into s_gan, s_ing from jsonb_array_elements(j) e;
  assert s_gan = (k#>>'{ganadas,uf}')::numeric, 'serie mensual suma lo mismo';

  -- Drill-down coincide con los números
  r := pg_temp.d('ganadas', '2026-01-01', '2026-05-01');
  assert jsonb_array_length(r) = (k#>>'{ganadas,n}')::int, 'drill ganadas: misma cantidad que el KPI';
  select sum((e->>'uf')::numeric) into s_gan from jsonb_array_elements(r) e;
  assert s_gan = (k#>>'{ganadas,uf}')::numeric, 'drill ganadas: mismas UF que el KPI';
  r := pg_temp.d('perdidas', '2026-01-01', '2026-05-01');
  assert jsonb_array_length(r) = (k#>>'{perdidas,n}')::int, 'drill perdidas: misma cantidad';
  r := pg_temp.d('abiertas', '2026-01-01', '2026-03-10');
  k := rev_kpis('2026-01-01', '2026-03-10');
  assert jsonb_array_length(r) = (k#>>'{pipeline,n}')::int, 'drill abiertas: misma cantidad que pipeline';
  assert jsonb_array_length(pg_temp.d('ganadas', '2026-03-01', '2026-04-01', 'D')) = 0, 'drill D marzo: reabierta no figura';
  assert jsonb_array_length(pg_temp.d('ganadas', '2026-02-01', '2026-03-01', 'D')) = 1, 'drill D febrero: figura una vez';
  assert jsonb_array_length(pg_temp.d('ingresadas', '2026-01-01', '2026-02-01', 'B')) = 1, 'drill ingresadas B enero';
  assert (pg_temp.d('ingresadas', '2026-01-01', '2026-02-01', 'B')#>>'{0,uf}')::numeric = 20, 'drill ingresadas con su valor';

  -- Errores controlados
  begin
    perform rev_series('2026-01-01', '2026-02-01', 'hora');
    assert false, 'debía fallar por granularidad';
  exception when raise_exception then
    assert sqlerrm like 'granularidad inválida%', 'mensaje de granularidad';
  end;
  perform pg_temp.h(pg_temp.mk('OLD', '2020-01-01', 1, 'nuevo'), '2020-01-01', 'nuevo');
  begin
    perform rev_series('2020-01-01', '2026-02-01', 'day');
    assert false, 'debía fallar por exceso de intervalos';
  exception when raise_exception then
    assert sqlerrm like 'demasiados intervalos%', 'mensaje de exceso de intervalos';
  end;

  raise notice 'rev_series / rev_drill: todas las pruebas pasaron';
end $$;
rollback;
