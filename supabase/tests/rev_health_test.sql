-- Pruebas de salud del pipeline, riesgo, drill e insights (013). Solo en una base local/desechable.
begin;
\ir _fixture.sql
create function pg_temp.hh(p_lead uuid, p_at timestamptz, p_to lead_stage) returns void language sql as $$
  insert into lead_stage_history(lead_id, from_stage, to_stage, changed_at) values (p_lead, null, p_to, p_at) $$;
-- Lead cerrado en p_close (creado el 5-ene): nuevo -> propuesta -> p_stage
create function pg_temp.closed(p_icp text, p_val numeric, p_stage lead_stage, p_close timestamptz, p_channel text default 'directo', p_lost text default 'otro')
returns uuid language plpgsql as $$
declare x uuid;
begin
  x := pg_temp.mk(p_icp, '2026-01-05', p_val, p_stage, null, p_channel, case when p_stage = 'perdido' then p_lost end);
  perform pg_temp.hh(x, '2026-01-05', 'nuevo'); perform pg_temp.hh(x, '2026-01-06', 'propuesta'); perform pg_temp.hh(x, p_close, p_stage);
  return x;
end $$;
create function pg_temp.opened(p_icp text, p_val numeric, p_stage lead_stage default 'propuesta') returns uuid language plpgsql as $$
declare x uuid;
begin
  x := pg_temp.mk(p_icp, '2026-01-05', p_val, p_stage);
  perform pg_temp.hh(x, '2026-01-05', 'nuevo'); perform pg_temp.hh(x, '2026-01-06', p_stage);
  return x;
end $$;
create function pg_temp.has(j jsonb, code text) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(j) e where e->>'codigo' = code) $$;

do $$
declare
  x uuid; j jsonb; k jsonb; d jsonb; i int;
  at constant timestamptz := '2026-06-10 12:00:00+00';
begin
  -- Base histórica de la etapa "contactado": 6 estadías terminadas de 4 días (promedio 4 d)
  for i in 1..6 loop
    x := pg_temp.mk('BASE', '2026-05-01', 5, 'ganado');
    perform pg_temp.hh(x, '2026-05-01', 'nuevo'); perform pg_temp.hh(x, '2026-05-02', 'contactado');
    perform pg_temp.hh(x, '2026-05-06', 'propuesta'); perform pg_temp.hh(x, '2026-05-20', 'ganado');
  end loop;

  -- H1: sana (activa, joven). Su fecha estimada se ADELANTÓ (no cuenta como postergación)
  x := pg_temp.mk('HL', '2026-06-08', 10, 'propuesta');
  perform pg_temp.hh(x, '2026-06-08', 'nuevo'); perform pg_temp.hh(x, '2026-06-09', 'propuesta');
  update leads set expected_close_at = '2026-06-20' where id = x;
  insert into lead_field_history(lead_id, field, old_value, new_value, changed_at) values (x, 'expected_close_at', '2026-07-01', '2026-06-20', '2026-06-09');
  -- H2: 15,5 días sin actividad y próxima acción vencida hace 9 días
  x := pg_temp.mk('HL', '2026-05-25', 20, 'negociacion');
  perform pg_temp.hh(x, '2026-05-25', 'nuevo'); perform pg_temp.hh(x, '2026-05-26', 'negociacion');
  update leads set next_action_at = '2026-06-01' where id = x;
  -- H3: fecha estimada vencida y pospuesta 2 veces; hace 69 días en "contactado"; con actividad reciente
  x := pg_temp.mk('HL', '2026-04-01', 5, 'contactado');
  perform pg_temp.hh(x, '2026-04-01', 'nuevo'); perform pg_temp.hh(x, '2026-04-02', 'contactado');
  insert into lead_activities(lead_id, type, created_at) values (x, 'llamada', '2026-06-09');
  update leads set expected_close_at = '2026-05-30' where id = x;
  insert into lead_field_history(lead_id, field, old_value, new_value, changed_at) values
    (x, 'expected_close_at', '2026-05-01', '2026-05-15', '2026-05-10'), (x, 'expected_close_at', '2026-05-15', '2026-05-30', '2026-05-20');
  -- H4: sin valor, 6,5 días sin señales (>3 pero no >7)
  x := pg_temp.mk('HL', '2026-06-04', null, 'nuevo'); perform pg_temp.hh(x, '2026-06-04', 'nuevo');
  -- H5: 10,5 días sin señales (>7, no >14)
  x := pg_temp.mk('HL', '2026-05-30', 8, 'calificado');
  perform pg_temp.hh(x, '2026-05-30', 'nuevo'); perform pg_temp.hh(x, '2026-05-31', 'calificado');
  -- H6: 21 días en "contactado" (más del doble del promedio de 4 d), con actividad reciente
  x := pg_temp.mk('HL', '2026-05-19', 7, 'contactado');
  perform pg_temp.hh(x, '2026-05-19', 'nuevo'); perform pg_temp.hh(x, '2026-05-20', 'contactado');
  insert into lead_activities(lead_id, type, created_at) values (x, 'email', '2026-06-09');

  j := rev_health(null, null, 'HL', at);
  assert (j#>>'{abiertas,n}')::int = 6 and (j#>>'{abiertas,uf}')::numeric = 50, 'abiertas';
  -- Estancadas (acumulado)
  assert (j#>>'{estancadas,0,dias}')::int = 3 and (j#>>'{estancadas,0,n}')::int = 3 and (j#>>'{estancadas,0,uf}')::numeric = 28, '>3 días';
  assert (j#>>'{estancadas,1,n}')::int = 2 and (j#>>'{estancadas,1,uf}')::numeric = 28, '>7 días';
  assert (j#>>'{estancadas,2,n}')::int = 1 and (j#>>'{estancadas,2,uf}')::numeric = 20, '>14 días';
  assert (j#>>'{estancadas,3,n}')::int = 0, '>30 días';
  -- Acciones vencidas
  assert (j#>>'{vencidas,n}')::int = 1 and (j#>>'{vencidas,uf}')::numeric = 20 and (j#>>'{vencidas,top,0,dias}')::int = 9, 'vencidas: 1, 20 UF, 9 días';
  assert jsonb_array_length(j#>'{vencidas,por_responsable}') = 1, 'vencidas por responsable';
  -- Antigüedad
  assert (select array_agg((e->>'n')::int order by ord) from jsonb_array_elements(j->'antiguedad') with ordinality t(e, ord)) = array[2,1,2,0,1], 'antigüedad por rango';
  assert (j#>>'{antiguedad,4,uf}')::numeric = 5, '60+ días: 5 UF';
  -- La antigüedad cubre todas las abiertas
  assert (select sum((e->>'n')::int) from jsonb_array_elements(j->'antiguedad') e) = 6, 'antigüedad suma las abiertas';
  -- Riesgo: reglas
  assert (j#>>'{riesgo,n}')::int = 3 and (j#>>'{riesgo,uf}')::numeric = 32, 'riesgo: H2, H3, H6';
  assert (j#>>'{riesgo,reglas,inactividad,n}')::int = 1 and (j#>>'{riesgo,reglas,inactividad,uf}')::numeric = 20, 'regla inactividad';
  assert (j#>>'{riesgo,reglas,fecha_vencida,n}')::int = 1 and (j#>>'{riesgo,reglas,postergaciones,n}')::int = 1, 'reglas fecha y postergaciones';
  assert (j#>>'{riesgo,reglas,exceso_etapa,n}')::int = 2 and (j#>>'{riesgo,reglas,exceso_etapa,uf}')::numeric = 12, 'regla exceso de etapa (H3 y H6)';
  assert (j#>>'{riesgo,top,0,senales}')::int = 3 and jsonb_array_length(j#>'{riesgo,top,0,motivos}') = 3, 'H3 acumula 3 señales y va primero';
  -- Postergación hacia atrás (H1) no cuenta
  assert (select postponements from rev_health_state(at, null, null, 'HL') where val = 10) = 0, 'adelantar la fecha no es postergar';

  -- Coherencia con el pipeline de los KPIs
  k := rev_kpis('2026-05-10', at, null, null, 'HL');
  assert (k#>>'{pipeline,n}')::int = (j#>>'{abiertas,n}')::int and (k#>>'{pipeline,uf}')::numeric = (j#>>'{abiertas,uf}')::numeric, 'salud vs KPI de pipeline';

  -- Umbral configurable: con 10 días, H5 (10,5) también es inactividad
  update health_config set value = 10 where key = 'riesgo_dias_sin_actividad';
  assert (rev_health(null, null, 'HL', at)#>>'{riesgo,reglas,inactividad,n}')::int = 2, 'umbral configurable';
  update health_config set value = 14 where key = 'riesgo_dias_sin_actividad';
  -- Sin base histórica suficiente la regla de etapa no se aplica
  update health_config set value = 99 where key = 'riesgo_min_muestras_etapa';
  assert (rev_health(null, null, 'HL', at)#>>'{riesgo,reglas,exceso_etapa,n}')::int = 0, 'sin muestras no hay regla de etapa';
  update health_config set value = 5 where key = 'riesgo_min_muestras_etapa';

  -- Drill
  d := rev_health_drill('estancadas', 7, null, null, 'HL', at);
  assert jsonb_array_length(d) = 2 and d#>>'{0,uf}' = '20.00', 'drill estancadas >7 d ordenado por UF';
  assert jsonb_array_length(rev_health_drill('estancadas', 3, null, null, 'HL', at)) = 3, 'drill estancadas >3 d';
  assert jsonb_array_length(rev_health_drill('vencidas', 7, null, null, 'HL', at)) = 1, 'drill vencidas';
  assert jsonb_array_length(rev_health_drill('riesgo', 7, null, null, 'HL', at)) = 3, 'drill riesgo';
  assert (rev_health_drill('vencidas', 7, null, null, 'HL', at)#>>'{0,dias}')::int = 9, 'drill vencidas: días de atraso';
  begin
    perform rev_health_drill('otros');
    assert false, 'debía fallar';
  exception when raise_exception then assert sqlerrm like 'tipo inválido%', 'mensaje'; end;
  -- Sin datos
  assert (rev_health(null, null, 'NOEXISTE', at)#>>'{abiertas,n}')::int = 0 and (rev_health(null, null, 'NOEXISTE', at)#>>'{riesgo,n}')::int = 0, 'sin datos';

  -- ===== INSIGHTS =====
  -- Conversión sube (prev: 1 ganada 2 perdidas = 33 %; actual: 3 ganadas = 100 %)
  perform pg_temp.closed('IC', 10, 'ganado', '2026-04-15'); perform pg_temp.closed('IC', 10, 'perdido', '2026-04-20'); perform pg_temp.closed('IC', 10, 'perdido', '2026-04-25');
  perform pg_temp.closed('IC', 10, 'ganado', '2026-05-12'); perform pg_temp.closed('IC', 10, 'ganado', '2026-05-20'); perform pg_temp.closed('IC', 10, 'ganado', '2026-06-02');
  assert pg_temp.has(rev_insights('2026-05-10', at, null, null, 'IC'), 'conversion_sube'), 'conversion_sube';
  -- Conversión baja (prev 3/0 = 100 %, actual 0/3 = 0 %)
  perform pg_temp.closed('IB', 10, 'ganado', '2026-04-12'); perform pg_temp.closed('IB', 10, 'ganado', '2026-04-15'); perform pg_temp.closed('IB', 10, 'ganado', '2026-04-20');
  perform pg_temp.closed('IB', 10, 'perdido', '2026-05-12'); perform pg_temp.closed('IB', 10, 'perdido', '2026-05-20'); perform pg_temp.closed('IB', 10, 'perdido', '2026-06-02');
  assert pg_temp.has(rev_insights('2026-05-10', at, null, null, 'IB'), 'conversion_baja'), 'conversion_baja';
  -- Muestra diminuta (solo 2 cierres actuales): no afirma nada sobre conversión
  perform pg_temp.closed('IZ', 10, 'perdido', '2026-04-12'); perform pg_temp.closed('IZ', 10, 'perdido', '2026-04-15'); perform pg_temp.closed('IZ', 10, 'perdido', '2026-04-20');
  perform pg_temp.closed('IZ', 10, 'ganado', '2026-05-12'); perform pg_temp.closed('IZ', 10, 'ganado', '2026-05-20');
  j := rev_insights('2026-05-10', at, null, null, 'IZ');
  assert not pg_temp.has(j, 'conversion_sube') and not pg_temp.has(j, 'conversion_baja'), 'mínimo de cierres para hablar de conversión';
  -- UF ganadas: tres meses a la baja / al alza
  perform pg_temp.closed('ID', 30, 'ganado', '2026-03-15'); perform pg_temp.closed('ID', 20, 'ganado', '2026-04-15'); perform pg_temp.closed('ID', 10, 'ganado', '2026-05-15');
  assert pg_temp.has(rev_insights('2026-05-10', at, null, null, 'ID'), 'ganadas_bajan'), 'ganadas_bajan';
  perform pg_temp.closed('IE', 5, 'ganado', '2026-03-15'); perform pg_temp.closed('IE', 10, 'ganado', '2026-04-15'); perform pg_temp.closed('IE', 20, 'ganado', '2026-05-15');
  assert pg_temp.has(rev_insights('2026-05-10', at, null, null, 'IE'), 'ganadas_suben'), 'ganadas_suben';
  -- Un canal concentra las ganadas (20 de 25 UF = 80 %)
  perform pg_temp.closed('IK', 10, 'ganado', '2026-05-12', 'meta_ads'); perform pg_temp.closed('IK', 10, 'ganado', '2026-05-15', 'meta_ads'); perform pg_temp.closed('IK', 5, 'ganado', '2026-05-18', 'directo');
  j := rev_insights('2026-05-10', at, null, null, 'IK');
  assert (select e#>>'{datos,canal}' from jsonb_array_elements(j) e where e->>'codigo' = 'canal_concentra') = 'meta_ads'
     and (select (e#>>'{datos,pct}')::int from jsonb_array_elements(j) e where e->>'codigo' = 'canal_concentra') = 80, 'canal_concentra 80 %';
  -- Si ya se filtró por canal, no tiene sentido decir que un canal concentra
  assert not pg_temp.has(rev_insights('2026-05-10', at, null, 'meta_ads', 'IK'), 'canal_concentra'), 'sin canal_concentra con filtro de canal';
  -- Un motivo domina (3 de 5 = 60 %)
  for i in 1..3 loop perform pg_temp.closed('IM', 5, 'perdido', '2026-05-15', 'directo', 'precio'); end loop;
  for i in 1..2 loop perform pg_temp.closed('IM', 5, 'perdido', '2026-05-16', 'directo', 'timing'); end loop;
  j := rev_insights('2026-05-10', at, null, null, 'IM');
  assert (select e#>>'{datos,motivo}' from jsonb_array_elements(j) e where e->>'codigo' = 'motivo_domina') = 'precio', 'motivo_domina';
  -- El pipeline cae (100 -> 40 UF)
  perform pg_temp.closed('IP', 60, 'perdido', '2026-05-20'); perform pg_temp.opened('IP', 40);
  assert pg_temp.has(rev_insights('2026-05-10', at, null, null, 'IP'), 'pipeline_cae'), 'pipeline_cae';
  -- Alto valor sin seguimiento + acciones vencidas + pipeline sin fecha; las alertas van primero
  perform pg_temp.opened('IV', 1); perform pg_temp.opened('IV', 2); perform pg_temp.opened('IV', 3); x := pg_temp.opened('IV', 50);
  update leads set next_action_at = '2026-05-01' where id = x;
  j := rev_insights('2026-05-10', at, null, null, 'IV');
  assert (select (e#>>'{datos,uf}')::numeric from jsonb_array_elements(j) e where e->>'codigo' = 'alto_valor_sin_seguimiento') = 50, 'alto valor sin seguimiento';
  assert pg_temp.has(j, 'acciones_vencidas') and pg_temp.has(j, 'forecast_sin_fecha'), 'vencidas y sin fecha';
  assert j#>>'{0,tipo}' = 'alerta' and (select e->>'tipo' from jsonb_array_elements(j) with ordinality t(e, o) order by o desc limit 1) = 'info', 'orden: alertas primero, info al final';
  -- Sin datos no hay insights
  assert rev_insights('2020-01-01', '2020-02-01') = '[]'::jsonb, 'sin datos: sin insights';

  raise notice 'rev salud / riesgo / insights: todas las pruebas pasaron';
end $$;
rollback;
