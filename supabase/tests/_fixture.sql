-- Fixture compartido de las pruebas de Revenue Intelligence (se incluye con \ir dentro de una transacción).
-- Casos (icp = nombre del caso): A mismo mes | B ene->mar | C perdida | D reapertura | E cambio de valor |
-- F responsable/canal | H sin valor | I corrección post-cierre | K cierre sin fecha | L ganado->perdido |
-- N cierre importado de una sola fila | M borde de mes en zona horaria Santiago.
set local timezone = 'UTC';
alter table leads disable trigger user;   -- el historial se inserta a mano con fechas controladas

create function pg_temp.mk(p_icp text, p_created timestamptz, p_val numeric, p_stage lead_stage,
                           p_owner uuid default null, p_channel text default 'directo', p_lost text default null)
returns uuid language sql as $$
  insert into leads(first_name, icp, created_at, deal_value_uf, stage, owner_id, channel, lost_reason)
  values ('t_' || p_icp, p_icp, p_created, p_val, p_stage, p_owner, p_channel, p_lost::lost_reason) returning id
$$;
create function pg_temp.h(p_lead uuid, p_at timestamptz, p_to lead_stage, p_approx boolean default false)
returns void language sql as $$
  insert into lead_stage_history(lead_id, from_stage, to_stage, changed_at, approx) values
    (p_lead, null, p_to, p_at, p_approx)
$$;
create function pg_temp.f(p_lead uuid, p_at timestamptz, p_field text, p_old text, p_new text)
returns void language sql as $$
  insert into lead_field_history(lead_id, field, old_value, new_value, changed_at) values (p_lead, p_field, p_old, p_new, p_at)
$$;
create function pg_temp.k(p_from text, p_to text, p_icp text default null, p_owner uuid default null, p_channel text default null)
returns jsonb language sql as $$ select rev_kpis(p_from::timestamptz, p_to::timestamptz, p_owner, p_channel, p_icp) $$;

insert into team_members(id, full_name, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'O1', 'o1@test'), ('00000000-0000-0000-0000-0000000000a2', 'O2', 'o2@test');


do $$
declare
  x uuid;
  o1 constant uuid := '00000000-0000-0000-0000-0000000000a1';
  o2 constant uuid := '00000000-0000-0000-0000-0000000000a2';
begin
  -- A. Creada y ganada en el mismo mes
  x := pg_temp.mk('A', '2026-03-02', 10, 'ganado');
  perform pg_temp.h(x, '2026-03-02', 'nuevo'); perform pg_temp.h(x, '2026-03-20', 'ganado');
  -- B. Creada en enero, ganada en marzo
  x := pg_temp.mk('B', '2026-01-10', 20, 'ganado');
  perform pg_temp.h(x, '2026-01-10', 'nuevo'); perform pg_temp.h(x, '2026-02-01', 'propuesta'); perform pg_temp.h(x, '2026-03-05', 'ganado');
  -- C. Perdida
  x := pg_temp.mk('C', '2026-03-02', 8, 'perdido', null, 'directo', 'precio');
  perform pg_temp.h(x, '2026-03-02', 'nuevo'); perform pg_temp.h(x, '2026-03-15', 'perdido');
  -- D. Reabierta: ganada en feb, reabierta en mar, ganada de nuevo en mar
  x := pg_temp.mk('D', '2026-01-05', 5, 'ganado');
  perform pg_temp.h(x, '2026-01-05', 'nuevo'); perform pg_temp.h(x, '2026-02-10', 'ganado');
  perform pg_temp.h(x, '2026-03-03', 'negociacion'); perform pg_temp.h(x, '2026-03-25', 'ganado');
  -- E. Cambio de valor antes del cierre (4 -> 9 el 10-mar)
  x := pg_temp.mk('E', '2026-02-01', 9, 'ganado');
  perform pg_temp.h(x, '2026-02-01', 'nuevo'); perform pg_temp.h(x, '2026-03-20', 'ganado');
  perform pg_temp.f(x, '2026-03-10', 'deal_value_uf', '4', '9');
  -- F. Cambio de responsable y de canal (hoy: O2 / directo; antes: O1 / meta_ads)
  x := pg_temp.mk('F', '2026-03-01', 7, 'ganado', o2, 'directo');
  perform pg_temp.h(x, '2026-03-01', 'nuevo'); perform pg_temp.h(x, '2026-03-12', 'ganado');
  perform pg_temp.f(x, '2026-03-05', 'owner_id', o1::text, o2::text);
  perform pg_temp.f(x, '2026-03-05', 'channel', 'meta_ads', 'directo');
  -- H. Sin valor UF
  x := pg_temp.mk('H', '2026-03-02', null, 'ganado');
  perform pg_temp.h(x, '2026-03-02', 'nuevo'); perform pg_temp.h(x, '2026-03-20', 'ganado');
  -- I. Ganada y luego corregido el valor (6 -> 7 el 20-mar): el mes de cierre conserva 6
  x := pg_temp.mk('I', '2026-03-01', 7, 'ganado');
  perform pg_temp.h(x, '2026-03-01', 'nuevo'); perform pg_temp.h(x, '2026-03-10', 'ganado');
  perform pg_temp.f(x, '2026-03-20', 'deal_value_uf', '6', '7');
  -- K. Cierre importado sin fecha (approx)
  x := pg_temp.mk('K', '2026-03-02', 3, 'ganado');
  perform pg_temp.h(x, '2026-03-02', 'ganado', true);
  -- L. Corregida ganado -> perdido
  x := pg_temp.mk('L', '2026-03-01', 5, 'perdido', null, 'directo', 'otro');
  perform pg_temp.h(x, '2026-03-01', 'nuevo'); perform pg_temp.h(x, '2026-03-10', 'ganado'); perform pg_temp.h(x, '2026-03-12', 'perdido');

  -- N. Cierre importado: la PRIMERA fila de historial ya es el cierre (como los leads de la hoja)
  x := pg_temp.mk('N', '2026-03-01', 4, 'ganado');
  perform pg_temp.h(x, '2026-03-09', 'ganado');
  -- M. Cierre en el borde de mes por zona horaria: 2026-03-01 02:00 UTC = 28-feb 23:00 en Santiago
  x := pg_temp.mk('M', '2026-02-10', 6, 'ganado');
  perform pg_temp.h(x, '2026-02-10', 'nuevo'); perform pg_temp.h(x, '2026-03-01 02:00:00+00', 'ganado');

end $$;
