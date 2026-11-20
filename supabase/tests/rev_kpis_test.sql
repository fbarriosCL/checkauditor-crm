-- Pruebas de rev_kpis (009). Correr SOLO en una base local/desechable, nunca en producción:
--   psql -v ON_ERROR_STOP=1 -d <base_local> -f supabase/tests/rev_kpis_test.sql   (desde la raíz del repo)
-- Todo ocurre dentro de una transacción que termina en ROLLBACK. Un assert fallido aborta con error.
begin;
\ir _fixture.sql
do $$
declare
  j jsonb;
  o1 constant uuid := '00000000-0000-0000-0000-0000000000a1';
  o2 constant uuid := '00000000-0000-0000-0000-0000000000a2';
begin
  -- 1 / A: mismo mes
  j := pg_temp.k('2026-03-01', '2026-04-01', 'A');
  assert (j#>>'{ganadas,n}')::int = 1 and (j#>>'{ganadas,uf}')::numeric = 10, 'caso 1 ganadas';
  assert (j#>>'{ticket,uf}')::numeric = 10 and (j#>>'{conversion,por_cantidad}')::numeric = 100, 'caso 1 ticket/conversion';
  assert (j#>>'{pipeline,n}')::int = 0, 'caso 1: ya no está en pipeline';

  -- 2 / B: ingresa en enero, gana en marzo; sigue en el pipeline hasta su cierre
  j := pg_temp.k('2026-02-01', '2026-03-01', 'B');
  assert (j#>>'{pipeline,uf}')::numeric = 20 and (j#>>'{pipeline,n}')::int = 1, 'caso 2 stock feb';
  assert (j#>>'{pipeline,uf_inicio}')::numeric = 20, 'caso 2 cierre anterior';
  assert (j#>>'{ponderado,uf}')::numeric = 10, 'caso 2 ponderado propuesta 50%';
  assert (j#>>'{ganadas,n}')::int = 0, 'caso 2: no gana en febrero';
  j := pg_temp.k('2026-03-01', '2026-04-01', 'B');
  assert (j#>>'{ganadas,uf}')::numeric = 20 and (j#>>'{pipeline,n}')::int = 0, 'caso 2 marzo';

  -- 3 / C: perdida
  j := pg_temp.k('2026-03-01', '2026-04-01', 'C');
  assert (j#>>'{perdidas,n}')::int = 1 and (j#>>'{perdidas,uf}')::numeric = 8, 'caso 3 perdidas';
  assert j#>>'{perdidas,motivos,0,motivo}' = 'precio', 'caso 3 motivo';
  assert (j#>>'{conversion,por_cantidad}')::numeric = 0, 'caso 3 conversion 0%';

  -- 4 / D: reapertura no duplica cierres
  j := pg_temp.k('2026-02-01', '2026-03-01', 'D');
  assert (j#>>'{ganadas,n}')::int = 1 and (j#>>'{ganadas,uf}')::numeric = 5, 'caso 4 feb';
  j := pg_temp.k('2026-03-01', '2026-04-01', 'D');
  assert (j#>>'{ganadas,n}')::int = 0 and (j#>>'{ganadas,uf}')::numeric = 0, 'caso 4 marzo neto 0';
  j := pg_temp.k('2026-01-01', '2026-05-01', 'D');
  assert (j#>>'{ganadas,n}')::int = 1 and (j#>>'{ganadas,uf}')::numeric = 5, 'caso 4 total sin doble conteo';
  j := pg_temp.k('2026-03-01', '2026-03-10', 'D');
  assert (j#>>'{pipeline,n}')::int = 1 and (j#>>'{pipeline,n_inicio}')::int = 0, 'caso 4 reabierta vuelve al pipeline';

  -- 5 / E: valor al cierre y valor histórico en el stock
  j := pg_temp.k('2026-03-01', '2026-04-01', 'E');
  assert (j#>>'{ganadas,uf}')::numeric = 9, 'caso 5 valor al cierre';
  j := pg_temp.k('2026-03-01', '2026-03-05', 'E');
  assert (j#>>'{pipeline,uf}')::numeric = 4, 'caso 5 stock con el valor de esa fecha';

  -- 6 y 7 / F: responsable y canal actuales, sin doble conteo
  assert (pg_temp.k('2026-03-01', '2026-04-01', 'F', o1)#>>'{ganadas,n}')::int = 0, 'caso 6 O1';
  assert (pg_temp.k('2026-03-01', '2026-04-01', 'F', o2)#>>'{ganadas,n}')::int = 1, 'caso 6 O2';
  assert (pg_temp.k('2026-03-01', '2026-04-01', 'F', null, 'meta_ads')#>>'{ganadas,n}')::int = 0, 'caso 7 canal anterior';
  assert (pg_temp.k('2026-03-01', '2026-04-01', 'F', null, 'directo')#>>'{ganadas,n}')::int = 1, 'caso 7 canal actual';
  assert (pg_temp.k('2026-03-01', '2026-04-01', 'F')#>>'{ganadas,n}')::int = 1, 'caso 6/7 global';

  -- 8: mes sin ventas
  j := pg_temp.k('2026-04-01', '2026-05-01', 'A');
  assert (j#>>'{ganadas,n}')::int = 0 and (j#>>'{ganadas,uf}')::numeric = 0, 'caso 8 ceros';
  assert j#>'{conversion,por_cantidad}' = 'null'::jsonb and j#>'{ticket,uf}' = 'null'::jsonb, 'caso 8 sin tasa ni ticket';

  -- 9 / H: sin valor UF
  j := pg_temp.k('2026-03-01', '2026-04-01', 'H');
  assert (j#>>'{ganadas,n}')::int = 1 and (j#>>'{ganadas,uf}')::numeric = 0, 'caso 9 cuenta pero 0 UF';
  assert j#>'{ticket,uf}' = 'null'::jsonb, 'caso 9 no afecta ticket';
  j := pg_temp.k('2026-03-01', '2026-03-10', 'H');
  assert (j#>>'{pipeline,sin_valor}')::int = 1, 'caso 9 stock marca sin valor';

  -- 11 / I: corrección posterior al cierre
  j := pg_temp.k('2026-03-01', '2026-04-01', 'I');
  assert (j#>>'{ganadas,uf}')::numeric = 6, 'caso 11 conserva valor del cierre';

  -- 12: periodo sin datos
  j := pg_temp.k('2020-01-01', '2020-02-01');
  assert (j#>>'{pipeline,uf}')::numeric = 0 and (j#>>'{ganadas,n}')::int = 0 and (j#>>'{perdidas,n}')::int = 0, 'caso 12 ceros';
  assert j#>'{conversion,historica}' = 'null'::jsonb and j#>'{conversion,por_valor}' = 'null'::jsonb, 'caso 12 sin tasas';

  -- K: cierre sin fecha queda aparte
  j := pg_temp.k('2026-03-01', '2026-04-01', 'K');
  assert (j#>>'{ganadas,n}')::int = 0 and (j#>>'{pipeline,n}')::int = 0, 'K fuera de flujos y stock';
  assert (j#>>'{sin_fecha,n}')::int = 1 and (j#>>'{sin_fecha,uf}')::numeric = 3, 'K informado como sin fecha';

  -- L: ganado -> perdido
  j := pg_temp.k('2026-03-01', '2026-04-01', 'L');
  assert (j#>>'{ganadas,n}')::int = 0 and (j#>>'{ganadas,uf}')::numeric = 0, 'L ya no es ganada';
  assert (j#>>'{perdidas,n}')::int = 1 and (j#>>'{perdidas,uf}')::numeric = 5, 'L es perdida';

  -- N: cierre importado de una sola fila cuenta
  j := pg_temp.k('2026-03-01', '2026-04-01', 'N');
  assert (j#>>'{ganadas,n}')::int = 1 and (j#>>'{ganadas,uf}')::numeric = 4, 'N cierre de una sola fila';

  -- Invariante: la suma de todos los eventos = estado actual (ganados A,B,D,E,F,H,I,N,M = 9; perdidos C,L = 2)
  j := pg_temp.k('2000-01-01', '2100-01-01');
  assert (j#>>'{ganadas,n}')::int = 9, 'invariante ganadas';
  assert (j#>>'{perdidas,n}')::int = 2, 'invariante perdidas';
  assert (j#>>'{ganadas,uf}')::numeric = 10 + 20 + 5 + 9 + 7 + 0 + 6 + 4 + 6, 'invariante UF ganadas';

  raise notice 'rev_kpis: todas las pruebas pasaron';
end $$;
rollback;
