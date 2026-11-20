-- Consistencia entre módulos de Revenue Intelligence sobre 400 leads con casos difíciles:
-- reaperturas, ganado->perdido, cambios de valor, empates de fecha en el historial y cierres sin fecha.
-- Verifica que (a) la serie por intervalos coincide con la función de referencia rev_stock en CADA corte y
-- (b) todos los módulos suman lo mismo que los KPIs. Solo en una base local/desechable.
begin;
\ir _fixture.sql
create function pg_temp.hh2(p_lead uuid, p_at timestamptz, p_to lead_stage, p_approx boolean default false) returns void language sql as $$
  insert into lead_stage_history(lead_id, from_stage, to_stage, changed_at, approx) values (p_lead, null, p_to, p_at, p_approx) $$;

do $$
declare
  o1 constant uuid := '00000000-0000-0000-0000-0000000000a1';
  o2 constant uuid := '00000000-0000-0000-0000-0000000000a2';
  i int; x uuid; c timestamptz; v numeric; fin lead_stage; own uuid; ch text; kind int;
begin
  perform setseed(0.7);
  for i in 1..400 loop
    c := timestamptz '2025-06-01' + (i * interval '17 hours');
    v := case when i % 9 = 0 then null else 1 + (i % 23) end;
    own := case when i % 5 = 0 then null when i % 2 = 0 then o1 else o2 end;
    ch := (array['meta_ads','google_ads','directo','organico'])[1 + i % 4];
    kind := i % 8;
    fin := case kind when 0 then 'nuevo' when 1 then 'propuesta' when 2 then 'ganado' when 3 then 'perdido'
                     when 4 then 'ganado' when 5 then 'perdido' when 6 then 'ganado'
                     else case when i % 16 = 7 then 'negociacion' else 'ganado' end end;
    if i % 37 = 0 then fin := 'ganado'; end if;     -- cierre importado sin fecha (approx)
    if i % 41 = 0 and i % 37 <> 0 then fin := 'propuesta'; kind := 99; end if;   -- primer registro de historial posterior a la creación
    if i % 43 = 0 and i % 37 <> 0 then fin := 'nuevo'; kind := 98; end if;       -- sin ningún registro de historial
    x := pg_temp.mk('CONS', c, v, fin, own, ch, case when fin = 'perdido' then 'precio' end);
    if i % 37 = 0 then
      perform pg_temp.hh2(x, c, 'ganado', true);
      continue;
    end if;
    if kind = 98 then continue; end if;
    if kind = 99 then perform pg_temp.hh2(x, c + interval '5 days', 'propuesta'); continue; end if;
    perform pg_temp.hh2(x, c, 'nuevo');
    if kind = 1 then perform pg_temp.hh2(x, c + interval '2 days', 'contactado'); perform pg_temp.hh2(x, c + interval '9 days', 'propuesta'); end if;
    if kind = 2 then perform pg_temp.hh2(x, c + interval '3 days', 'contactado'); perform pg_temp.hh2(x, c + interval '20 days', 'ganado'); end if;
    if kind = 3 then perform pg_temp.hh2(x, c + interval '15 days', 'perdido'); end if;
    if kind = 4 then   -- ganada, reabierta, ganada de nuevo
      perform pg_temp.hh2(x, c + interval '10 days', 'ganado'); perform pg_temp.hh2(x, c + interval '20 days', 'negociacion'); perform pg_temp.hh2(x, c + interval '30 days', 'ganado');
    end if;
    if kind = 5 then   -- ganada y corregida a perdida
      perform pg_temp.hh2(x, c + interval '10 days', 'ganado'); perform pg_temp.hh2(x, c + interval '11 days', 'perdido');
    end if;
    if kind = 6 then   -- cambios de valor antes y después del cierre
      perform pg_temp.f(x, c + interval '5 days', 'deal_value_uf', coalesce(v, 3)::text, (coalesce(v, 3) + 2)::text);
      perform pg_temp.hh2(x, c + interval '25 days', 'ganado');
      perform pg_temp.f(x, c + interval '40 days', 'deal_value_uf', (coalesce(v, 3) + 2)::text, (coalesce(v, 3) + 5)::text);
    end if;
    if kind = 7 then   -- dos cambios de etapa con la MISMA fecha: manda el último registrado
      perform pg_temp.hh2(x, c + interval '3 days', 'propuesta'); perform pg_temp.hh2(x, c + interval '3 days', 'negociacion');
      if fin = 'ganado' then perform pg_temp.hh2(x, c + interval '50 days', 'ganado'); end if;
    end if;
    if kind in (0, 1, 7) and fin <> 'ganado' then update leads set expected_close_at = date '2026-06-30' + (i % 40) where id = x; end if;
  end loop;
end $$;

create function pg_temp.k(p_from text, p_to text, p_owner uuid, p_ch text) returns jsonb language sql as $$
  select rev_kpis(p_from::timestamptz, p_to::timestamptz, p_owner, p_ch, 'CONS') $$;

do $$
declare
  o1 constant uuid := '00000000-0000-0000-0000-0000000000a1';
  o2 constant uuid := '00000000-0000-0000-0000-0000000000a2';
  f record; g text; j jsonb; k jsonb; e jsonb; ref record; d text; tot numeric; tot_n int; n_checked int := 0;
  p_to constant text := '2026-06-15 12:00:00+00';
begin
  for f in select * from (values (null::uuid, null::text), (o1, null), (null, 'meta_ads'), (o1, 'directo')) t(owner, ch) loop
    foreach g in array array['day', 'week', 'month', 'quarter'] loop
      -- (a) la serie por intervalos == referencia punto a punto
      j := rev_series(case g when 'day' then '2026-04-20' else '2025-06-01' end::timestamptz, p_to::timestamptz, g, f.owner, f.ch, 'CONS', g = 'month');
      assert jsonb_array_length(j) > 0, format('la serie %s no debe venir vacía (owner %s, canal %s)', g, f.owner, f.ch);
      for e in select * from jsonb_array_elements(j) loop
        select count(*) as n, coalesce(sum(val), 0) as uf, coalesce(sum(val * prob), 0) as pond into ref
        from rev_stock(((e->>'hasta')::timestamptz) - interval '1 microsecond', f.owner, f.ch, 'CONS');
        assert (e->>'pip_n')::int = ref.n and (e->>'pip_uf')::numeric = ref.uf and abs((e->>'pond_uf')::numeric - ref.pond) < 0.0001,
          format('serie %s vs rev_stock en %s: n %s/%s uf %s/%s', g, e->>'hasta', e->>'pip_n', ref.n, e->>'pip_uf', ref.uf);
        n_checked := n_checked + 1;
      end loop;
      -- los flujos de la serie suman lo mismo que el KPI del mismo tramo
      k := rev_kpis(((j->0)->>'desde')::timestamptz, p_to::timestamptz, f.owner, f.ch, 'CONS');
      select coalesce(sum((x->>'gan_uf')::numeric), 0), coalesce(sum((x->>'gan_n')::int), 0) into tot, tot_n from jsonb_array_elements(j) x;
      assert tot = (k#>>'{ganadas,uf}')::numeric and tot_n = (k#>>'{ganadas,n}')::int, 'serie ' || g || ': ganadas = KPI';
      select coalesce(sum((x->>'per_uf')::numeric), 0), coalesce(sum((x->>'per_n')::int), 0) into tot, tot_n from jsonb_array_elements(j) x;
      assert tot = (k#>>'{perdidas,uf}')::numeric and tot_n = (k#>>'{perdidas,n}')::int, 'serie ' || g || ': perdidas = KPI';
    end loop;

    -- (b) todos los módulos suman lo mismo que los KPIs
    k := rev_kpis('2025-09-01', p_to::timestamptz, f.owner, f.ch, 'CONS');
    foreach d in array array['channel', 'owner'] loop
      j := rev_performance(d, '2025-09-01', p_to::timestamptz, f.owner, f.ch, 'CONS');
      select coalesce(sum((x->>'gan_uf')::numeric), 0), coalesce(sum((x->>'gan_n')::int), 0) into tot, tot_n from jsonb_array_elements(j) x;
      assert tot = (k#>>'{ganadas,uf}')::numeric and tot_n = (k#>>'{ganadas,n}')::int, 'performance ' || d || ': ganadas';
      select sum((x->>'per_uf')::numeric) into tot from jsonb_array_elements(j) x;
      assert tot = (k#>>'{perdidas,uf}')::numeric, 'performance ' || d || ': perdidas';
      select sum((x->>'uf_abiertas')::numeric), sum((x->>'abiertas')::int) into tot, tot_n from jsonb_array_elements(j) x;
      assert tot = (k#>>'{pipeline,uf}')::numeric and tot_n = (k#>>'{pipeline,n}')::int, 'performance ' || d || ': pipeline';
    end loop;
    j := rev_stage_distribution(p_to::timestamptz, f.owner, f.ch, 'CONS');
    assert (j->>'total_n')::int = (k#>>'{pipeline,n}')::int and (j->>'total_uf')::numeric = (k#>>'{pipeline,uf}')::numeric, 'distribución = pipeline';
    j := rev_health(f.owner, f.ch, 'CONS', p_to::timestamptz);
    assert (j#>>'{abiertas,n}')::int = (k#>>'{pipeline,n}')::int and (j#>>'{abiertas,uf}')::numeric = (k#>>'{pipeline,uf}')::numeric, 'salud = pipeline';
    j := rev_forecast(f.owner, f.ch, 'CONS', false, p_to::timestamptz);
    assert (j#>>'{total,n}')::int = (k#>>'{pipeline,n}')::int and (j#>>'{total,uf}')::numeric = (k#>>'{pipeline,uf}')::numeric, 'forecast total = pipeline';
    assert abs((j#>>'{total,pond}')::numeric - (k#>>'{ponderado,uf}')::numeric) < 0.0001, 'forecast ponderado = KPI ponderado';
    assert (select sum((v->>'n')::int) from jsonb_each(j->'bloques') b(kk, v)) = (k#>>'{pipeline,n}')::int, 'forecast: cada oportunidad en un solo bloque';
    -- drill = KPI
    j := rev_drill('ganadas', '2025-09-01', p_to::timestamptz, f.owner, f.ch, 'CONS');
    select sum((x->>'uf')::numeric) into tot from jsonb_array_elements(j) x;
    assert jsonb_array_length(j) = (k#>>'{ganadas,n}')::int and coalesce(tot, 0) = (k#>>'{ganadas,uf}')::numeric, 'drill ganadas = KPI';
    j := rev_drill('abiertas', '2025-09-01', p_to::timestamptz, f.owner, f.ch, 'CONS');
    assert jsonb_array_length(j) = (k#>>'{pipeline,n}')::int, 'drill abiertas = pipeline';
    -- cohortes y embudo parten del mismo número de leads
    j := rev_cohorts('2025-06-01', p_to::timestamptz, f.owner, f.ch, 'CONS');
    select sum((x->>'n')::int) into tot_n from jsonb_array_elements(j) x;
    assert tot_n = (rev_funnel_cohort('2025-06-01', p_to::timestamptz, f.owner, f.ch, 'CONS')->>'total')::int, 'cohortes y embudo: mismo universo';
    -- sin doble conteo: ganadas + perdidas netas de toda la historia = leads cerrados hoy (sin los de fecha incierta)
    k := rev_kpis('2000-01-01', '2100-01-01', f.owner, f.ch, 'CONS');
    assert (k#>>'{ganadas,n}')::int = (select count(*) from rev_base(f.owner, f.ch, 'CONS') b join leads l on l.id = b.id where l.stage = 'ganado' and not b.undated), 'invariante ganadas';
    assert (k#>>'{perdidas,n}')::int = (select count(*) from rev_base(f.owner, f.ch, 'CONS') b join leads l on l.id = b.id where l.stage = 'perdido' and not b.undated), 'invariante perdidas';
  end loop;
  raise notice 'consistencia entre módulos: todas las pruebas pasaron (% cortes de la serie comparados con rev_stock)', n_checked;
end $$;
rollback;
