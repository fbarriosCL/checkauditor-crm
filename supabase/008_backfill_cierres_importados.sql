-- Check Auditor CRM · 008 · fechas de cierre de los leads importados de la hoja Pipeline
-- Ejecutar UNA vez DESPUÉS de 007. No contiene datos de clientes: solo códigos de fila (D###) y fechas.
--
-- Fuente de la fecha: columna "Última acción" de la hoja Pipeline, usada como fecha de cierre
-- de los 44 leads ganados/perdidos. Reglas:
--  * Si "Última acción" es anterior a la creación del lead (D040), se usa la fecha de creación.
--  * Sin "Última acción" (D037, D063) no se inventa fecha: la fila de historial queda con
--    approx = true y won_at/lost_at nulos; los reportes la tratan como "cierre sin fecha".
--  * Los leads abiertos de la hoja mantienen su fecha de entrada = created_at.

do $$
declare
  r record;
  ts timestamptz;
begin
  for r in
    select * from (values
    ('D001', '2026-08-07'::date),
    ('D010', '2026-02-13'::date),
    ('D012', '2026-02-23'::date),
    ('D013', '2026-07-30'::date),
    ('D014', '2026-04-21'::date),
    ('D016', '2026-04-27'::date),
    ('D017', '2026-02-10'::date),
    ('D018', '2026-02-10'::date),
    ('D019', '2026-02-24'::date),
    ('D020', '2026-05-08'::date),
    ('D021', '2026-04-01'::date),
    ('D022', '2026-04-20'::date),
    ('D023', '2026-02-13'::date),
    ('D024', '2026-03-30'::date),
    ('D025', '2026-03-04'::date),
    ('D026', '2026-03-04'::date),
    ('D027', '2026-05-12'::date),
    ('D028', '2026-07-24'::date),
    ('D030', '2026-02-05'::date),
    ('D031', '2026-03-05'::date),
    ('D032', '2026-02-25'::date),
    ('D033', '2026-03-21'::date),
    ('D034', '2026-02-13'::date),
    ('D035', '2026-05-12'::date),
    ('D036', '2026-04-06'::date),
    ('D037', null::date),
    ('D038', '2026-02-03'::date),
    ('D039', '2026-02-10'::date),
    ('D040', '2026-02-12'::date),
    ('D041', '2026-02-24'::date),
    ('D042', '2026-02-24'::date),
    ('D043', '2026-02-24'::date),
    ('D044', '2026-04-22'::date),
    ('D045', '2026-04-27'::date),
    ('D046', '2026-04-28'::date),
    ('D047', '2026-05-08'::date),
    ('D048', '2026-05-12'::date),
    ('D049', '2026-05-12'::date),
    ('D050', '2026-05-08'::date),
    ('D051', '2026-02-10'::date),
    ('D061', '2026-10-14'::date),
    ('D063', null::date),
    ('D068', '2026-10-14'::date),
    ('D072', '2026-11-17'::date)
    ) as t(code, fecha)
  loop
    ts := case when r.fecha is null then null
               else (r.fecha + time '12:00') at time zone 'America/Santiago' end;

    -- Fecha de cierre en el lead
    update leads set
      won_at  = case when stage = 'ganado'  then ts else won_at  end,
      lost_at = case when stage = 'perdido' then ts else lost_at end
    where source_form = 'sheet_pipeline' and notes like '[Hoja Pipeline ' || r.code || ']%';

    -- Fila de historial creada por el import: fecha real (o marcada aproximada) + foto de valor
    update lead_stage_history h set
      changed_at    = coalesce(ts, l.created_at),
      approx        = (ts is null),
      deal_value_uf = l.deal_value_uf,
      owner_id      = l.owner_id,
      channel       = l.channel
    from leads l
    where h.lead_id = l.id and h.from_stage is null
      and l.source_form = 'sheet_pipeline' and l.notes like '[Hoja Pipeline ' || r.code || ']%';
  end loop;
end $$;

-- Leads abiertos de la hoja: entran al pipeline en su fecha de creación (no el día del import).
update lead_stage_history h set
  changed_at    = l.created_at,
  deal_value_uf = l.deal_value_uf,
  owner_id      = l.owner_id,
  channel       = l.channel
from leads l
where h.lead_id = l.id and h.from_stage is null
  and l.source_form = 'sheet_pipeline' and l.stage not in ('ganado','perdido');

-- Verificación: cierres por mes (los 2 sin fecha aparecen como NULL)
select to_char(coalesce(won_at, lost_at), 'YYYY-MM') as mes, stage, count(*)
from leads where source_form = 'sheet_pipeline' and stage in ('ganado','perdido')
group by 1, 2 order by 1, 2;
