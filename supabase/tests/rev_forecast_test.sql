-- Pruebas de cohortes, embudo, distribución y forecast (011). Solo en una base local/desechable.
begin;
\ir _fixture.sql
create function pg_temp.hh(p_lead uuid, p_at timestamptz, p_to lead_stage) returns void language sql as $$
  insert into lead_stage_history(lead_id, from_stage, to_stage, changed_at) values (p_lead, null, p_to, p_at) $$;
-- Oportunidad abierta de prueba: creada 2026-05-01, en `p_stage` desde 2026-05-02, con fecha estimada de cierre
create function pg_temp.open_lead(p_icp text, p_val numeric, p_stage lead_stage, p_ec date) returns uuid language plpgsql as $$
declare x uuid;
begin
  x := pg_temp.mk(p_icp, '2026-05-01', p_val, p_stage);
  perform pg_temp.hh(x, '2026-05-01', 'nuevo');
  if p_stage <> 'nuevo' then perform pg_temp.hh(x, '2026-05-02', p_stage); end if;
  update leads set expected_close_at = p_ec where id = x;
  return x;
end $$;

do $$
declare j jsonb; r jsonb; i int; x uuid; w numeric; obs numeric;
  at constant timestamptz := '2026-06-10 12:00:00+00';
begin
  -- ===== COHORTES =====
  -- B se creó en enero y se ganó en marzo: pertenece a la cohorte de ENERO (no a la de marzo)
  j := rev_cohorts('2026-01-01', '2026-05-01', null, null, 'B');
  assert jsonb_array_length(j) = 1 and (j#>>'{0,n}')::int = 1 and (j#>>'{0,ganados}')::int = 1, 'cohorte B en enero';
  assert (j#>>'{0,conv_ingresados}')::numeric = 100, 'cohorte B 100%';
  -- C: perdida => 0% sobre ingresados y 0% sobre resueltos
  j := rev_cohorts('2026-03-01', '2026-04-01', null, null, 'C');
  assert (j#>>'{0,conv_ingresados}')::numeric = 0 and (j#>>'{0,conv_resueltos}')::numeric = 0, 'cohorte C 0%';
  -- Lead abierto: no cuenta como resuelto
  perform pg_temp.open_lead('COH', 5, 'propuesta', null);
  j := rev_cohorts('2026-05-01', '2026-06-01', null, null, 'COH');
  assert (j#>>'{0,abiertos}')::int = 1 and j#>'{0,conv_resueltos}' = 'null'::jsonb, 'cohorte inmadura sin tasa de resueltos';
  assert rev_cohorts('2020-01-01', '2020-02-01') = '[]'::jsonb, 'cohortes sin datos';

  -- ===== EMBUDO DE COHORTE =====
  -- C: nuevo -> perdido. Alcanzó solo "nuevo"
  j := rev_funnel_cohort('2026-03-01', '2026-04-01', null, null, 'C');
  assert (j#>>'{etapas,0,alcanzaron}')::int = 1 and (j#>>'{etapas,1,alcanzaron}')::int = 0, 'embudo C: perdido no avanza';
  -- B: nuevo -> propuesta -> ganado. Llegó a ganado, así que cuenta en todas las etapas previas
  j := rev_funnel_cohort('2026-01-01', '2026-02-01', null, null, 'B');
  assert (select bool_and((e->>'alcanzaron')::int = 1) from jsonb_array_elements(j->'etapas') e), 'embudo B: todas las etapas';
  assert (j#>>'{etapas,5,uf}')::numeric = 20, 'embudo B: UF de quienes alcanzaron propuesta';
  -- N: cierre importado de una fila: se cuenta como ganado y se informa como incompleto
  j := rev_funnel_cohort('2026-03-01', '2026-04-01', null, null, 'N');
  assert (j->>'incompletos')::int = 1 and (j#>>'{etapas,7,alcanzaron}')::int = 1, 'embudo N incompleto';
  -- la lista de etapas no incluye perdido
  assert jsonb_array_length(j->'etapas') = 8, 'embudo con 8 etapas (sin perdido)';
  -- tiempo en etapa: B estuvo en nuevo 22 días (10-ene a 1-feb)
  j := rev_funnel_cohort('2026-01-01', '2026-02-01', null, null, 'B');
  assert (j#>>'{etapas,0,dias_prom}')::numeric = 22, 'embudo B: días en nuevo';
  assert rev_funnel_cohort('2020-01-01', '2020-02-01')->>'total' = '0', 'embudo sin datos';

  -- ===== DISTRIBUCIÓN ACTUAL =====
  j := rev_stage_distribution('2026-02-15', null, null, 'B');
  assert (j->>'total_n')::int = 1 and (j#>>'{etapas,5,n}')::int = 1 and (j#>>'{etapas,5,uf}')::numeric = 20, 'distribución B en propuesta el 15-feb';
  assert (j#>>'{etapas,0,n}')::int = 0, 'distribución: nada en nuevo';

  -- ===== FORECAST =====
  perform pg_temp.open_lead('FC', 10, 'propuesta',   '2026-06-25');  -- mes actual
  perform pg_temp.open_lead('FC', 20, 'negociacion', '2026-07-15');  -- mes +1, comprometido
  perform pg_temp.open_lead('FC', 8,  'contactado',  '2026-08-30');  -- mes +2
  perform pg_temp.open_lead('FC', 6,  'demo_hecha',  '2027-01-01');  -- después
  perform pg_temp.open_lead('FC', 4,  'calificado',  null);          -- sin fecha
  perform pg_temp.open_lead('FC', 5,  'propuesta',   '2026-06-01');  -- fecha vencida
  perform pg_temp.open_lead('FC', null, 'nuevo',     '2026-06-12');  -- sin valor, mes actual
  j := rev_forecast(null, null, 'FC', false, at);
  assert (j#>>'{total,n}')::int = 7 and (j#>>'{total,uf}')::numeric = 53, 'forecast total';
  assert abs((j#>>'{total,pond}')::numeric - 24.54) < 0.001, 'forecast ponderado total';
  assert (j#>>'{bloques,mes0,uf}')::numeric = 10 and (j#>>'{bloques,mes0,n}')::int = 2 and (j#>>'{bloques,mes0,sin_valor}')::int = 1, 'mes actual';
  assert (j#>>'{bloques,mes0,pond}')::numeric = 5, 'mes actual ponderado';
  assert (j#>>'{bloques,mes1,uf}')::numeric = 20 and (j#>>'{bloques,mes1,pond}')::numeric = 14, 'mes +1';
  assert (j#>>'{bloques,mes2,uf}')::numeric = 8 and abs((j#>>'{bloques,mes2,pond}')::numeric - 0.64) < 0.001, 'mes +2';
  assert (j#>>'{bloques,despues,uf}')::numeric = 6, 'después del horizonte';
  assert (j#>>'{bloques,sin_fecha,n}')::int = 1 and (j#>>'{bloques,sin_fecha,uf}')::numeric = 4, 'sin fecha estimada va aparte';
  assert (j#>>'{bloques,vencida,n}')::int = 1 and (j#>>'{bloques,vencida,uf}')::numeric = 5, 'fecha vencida va aparte';
  -- Sin duplicados: los seis bloques suman exactamente el total
  assert (select sum((v->>'n')::int) from jsonb_each(j->'bloques') e(k, v)) = 7, 'cada oportunidad en un solo bloque';
  assert (select sum((v->>'uf')::numeric) from jsonb_each(j->'bloques') e(k, v)) = 53, 'bloques suman las UF totales';
  assert (j#>>'{comprometido,uf}')::numeric = 20 and (j#>>'{comprometido,n}')::int = 1, 'comprometido = prob >= 70%';
  assert jsonb_array_length(j->'proximas') = 2 and (j#>>'{proximas,0,fecha}') = '2026-06-12', 'próximas 30 días ordenadas';
  assert (j#>>'{ganado_mes,uf}')::numeric = 0, 'nada ganado aún en junio';
  assert (j#>>'{calibracion,usando_observado}')::boolean = false, 'sin historial no se usa probabilidad observada';

  -- Pedir probabilidades observadas sin historial suficiente no cambia nada
  r := rev_forecast(null, null, 'FC', true, at);
  assert (r#>>'{total,pond}')::numeric = (j#>>'{total,pond}')::numeric, 'observadas sin datos: igual que configuradas';
  assert (r#>>'{calibracion,usando_observado}')::boolean = false, 'bandera de calibración apagada';

  -- Ganado en el mes actual: se informa, y no se mezcla con el pipeline abierto
  x := pg_temp.mk('FCW', '2026-06-01', 7, 'ganado');
  perform pg_temp.hh(x, '2026-06-01', 'nuevo'); perform pg_temp.hh(x, '2026-06-05', 'ganado');
  j := rev_forecast(null, null, 'FCW', false, at);
  assert (j#>>'{ganado_mes,uf}')::numeric = 7 and (j#>>'{total,n}')::int = 0, 'ganado del mes aparte del pipeline';

  -- ===== CALIBRACIÓN CON HISTORIAL SUFICIENTE =====
  for i in 1..40 loop
    x := pg_temp.mk('CAL', '2026-01-01', 5, case when i <= 12 then 'ganado'::lead_stage else 'perdido'::lead_stage end,
                    null, 'directo', case when i > 12 then 'otro' end);
    perform pg_temp.hh(x, '2026-01-01', 'nuevo');
    if i <= 12 then
      perform pg_temp.hh(x, '2026-01-10', 'propuesta'); perform pg_temp.hh(x, '2026-02-01', 'ganado');
    else
      perform pg_temp.hh(x, '2026-01-05', 'contactado'); perform pg_temp.hh(x, '2026-01-20', 'perdido');
    end if;
  end loop;
  perform pg_temp.open_lead('CALOPEN', 10, 'propuesta', '2026-06-20');
  select observed into obs from rev_stage_rates() where stage = 'propuesta';
  assert (select enough from rev_stage_rates() where stage = 'propuesta'), 'propuesta con historial suficiente';
  assert (select abs(observed - round(won_n::numeric / reached_n, 3)) < 0.0011 from rev_stage_rates() where stage = 'contactado'), 'observada = ganadas / alcanzaron';
  j := rev_forecast(null, null, 'CALOPEN', false, at);
  r := rev_forecast(null, null, 'CALOPEN', true, at);
  assert (j#>>'{total,pond}')::numeric = 5, 'configurada 50%';
  assert abs((r#>>'{total,pond}')::numeric - 10 * obs) < 0.001 and obs <> 0.5, 'observada reemplaza a la configurada';
  assert (r#>>'{calibracion,usando_observado}')::boolean, 'bandera de calibración encendida';
  -- Los leads importados de una fila NO calibran: N y los demás de una sola fila no están en el conteo
  assert (select reached_n from rev_stage_rates() where stage = 'nuevo') =
         (select count(*) from leads l where l.stage in ('ganado','perdido')
            and exists (select 1 from lead_stage_history h where h.lead_id = l.id and h.to_stage = 'nuevo')), 'solo trayectorias completas calibran';

  raise notice 'rev cohortes / embudo / forecast: todas las pruebas pasaron';
end $$;
rollback;
