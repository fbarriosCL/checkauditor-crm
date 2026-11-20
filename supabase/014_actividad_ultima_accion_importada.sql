-- Check Auditor CRM · 014 (OPCIONAL) · "Última acción" de la hoja Pipeline como actividad
-- Ejecutar DESPUÉS de 008. No contiene datos de clientes: solo códigos de fila (D###) y fechas.
--
-- Por qué: los leads importados no tienen actividades en el CRM, así que el dashboard de salud los marcaría
-- "sin seguimiento" aunque la hoja diga que se trabajaron hace poco. Esta migración registra UNA nota por lead
-- con la fecha de su "Última acción" de la hoja, claramente rotulada como importada.
--  * Solo 76 de 79 leads de la hoja tienen "Última acción"; el resto no recibe nada (no se inventa).
--  * Si la fecha es anterior a la creación del lead, se usa la fecha de creación (igual que en 008).
--  * Es idempotente: no duplica la nota si ya existe.
-- Si prefieres que la salud del pipeline solo considere actividades reales del CRM, NO ejecutes este archivo.

insert into lead_activities (lead_id, type, body, created_at)
select l.id, 'nota', 'Última acción registrada en la hoja Pipeline (importada)',
       (v.fecha + time '12:00') at time zone 'America/Santiago'
from (values
    ('D001', '2026-08-07'::date),
    ('D002', '2026-09-15'::date),
    ('D003', '2026-08-13'::date),
    ('D004', '2026-06-16'::date),
    ('D005', '2026-07-09'::date),
    ('D006', '2026-07-27'::date),
    ('D007', '2026-07-30'::date),
    ('D008', '2026-08-31'::date),
    ('D009', '2026-10-10'::date),
    ('D010', '2026-02-13'::date),
    ('D011', '2026-07-13'::date),
    ('D012', '2026-02-23'::date),
    ('D013', '2026-07-30'::date),
    ('D014', '2026-04-21'::date),
    ('D015', '2026-08-06'::date),
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
    ('D029', '2026-07-31'::date),
    ('D030', '2026-02-05'::date),
    ('D031', '2026-03-05'::date),
    ('D032', '2026-02-25'::date),
    ('D033', '2026-03-21'::date),
    ('D034', '2026-02-13'::date),
    ('D035', '2026-05-12'::date),
    ('D036', '2026-04-06'::date),
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
    ('D052', '2026-09-14'::date),
    ('D053', '2026-08-25'::date),
    ('D054', '2026-09-11'::date),
    ('D055', '2026-11-04'::date),
    ('D056', '2026-08-25'::date),
    ('D057', '2026-10-28'::date),
    ('D058', '2026-09-15'::date),
    ('D059', '2026-09-15'::date),
    ('D060', '2026-09-15'::date),
    ('D061', '2026-10-14'::date),
    ('D064', '2026-10-19'::date),
    ('D065', '2026-10-06'::date),
    ('D066', '2026-10-14'::date),
    ('D067', '2026-10-06'::date),
    ('D068', '2026-10-14'::date),
    ('D069', '2026-10-20'::date),
    ('D070', '2026-10-22'::date),
    ('D071', '2026-11-05'::date),
    ('D072', '2026-11-17'::date),
    ('D073', '2026-11-11'::date),
    ('D074', '2026-11-09'::date),
    ('D075', '2026-11-12'::date),
    ('D076', '2026-11-19'::date),
    ('D077', '2026-11-04'::date),
    ('D078', '2026-11-19'::date),
    ('D079', '2026-11-19'::date)
) as v(code, fecha)
join leads l on l.source_form = 'sheet_pipeline' and l.notes like '[Hoja Pipeline ' || v.code || ']%'
where not exists (
  select 1 from lead_activities a
  where a.lead_id = l.id and a.type = 'nota' and a.body = 'Última acción registrada en la hoja Pipeline (importada)'
);

select count(*) as notas_importadas from lead_activities where body = 'Última acción registrada en la hoja Pipeline (importada)';
