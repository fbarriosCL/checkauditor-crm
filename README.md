# CRM · Check Auditor

App interna (`crm.checkauditor.com`) para que el equipo vea los leads y los mueva por etapas hasta el cierre.
Nuxt 3 en modo SPA + Supabase (proyecto `ihtkakajwulpyxsonnph`). Sin costo: plan gratis de Supabase y Vercel.

## Pantallas
- **/login**: entrada con correo y contraseña. Solo los 4 usuarios creados en Supabase → Auth → Users (el enlace mágico se descartó: sin SMTP propio no se puede editar la plantilla y el enlace se gasta si el correo lo abre antes).
- **/** (pipeline): kanban por etapa; arrastrar cambia la etapa, "Perdido" exige motivo. Filtros por canal y responsable, buscador, total UF por columna, tiempo real.
- **/lead/:id**: datos, origen (canal, UTMs, IDs de clic), etapa, responsable, ICP, valor UF, próxima acción, notas, actividades e historial.
- **/dashboard**: Revenue Intelligence (UF, conversión, forecast, canales, responsables, salud del pipeline). Ver la sección de abajo.
- **/nuevo**: lead manual (referidos, correos, eventos).
- **/llamar?n=569…**: puente para el botón "Llamar" de Slack (Slack solo acepta https; esta página abre `tel:`).

## Seguridad
- Usa la clave **anon** (pública por diseño). Todo el acceso lo controla RLS en Supabase: solo `team_members` activos ven o editan datos.
- No usa la `service_role`.

## Base de datos
`supabase/` tiene las migraciones en orden (001–004 ya aplicadas; 005 y 006 al publicar; 007–013 son del dashboard comercial y 014 es opcional).
Todas se ejecutan en Supabase → SQL Editor, una vez y en orden.

## Dashboard comercial (Revenue Intelligence)
Todo el cálculo vive en funciones SQL de solo lectura (`security invoker`: respetan el RLS del equipo). El navegador pide
resultados ya agregados (14 consultas al abrir; cache de 60 s); no descarga leads.

| Migración | Qué agrega |
|---|---|
| `007_revenue_intelligence.sql` | Fecha estimada de cierre y de pérdida; foto de valor/responsable/canal en cada cambio de etapa; historial de cambios de campos; `stage_config` (probabilidad por etapa); índices |
| `008_backfill_cierres_importados.sql` | Fecha de cierre de los 44 leads importados ganados/perdidos, tomada de «Última acción» de la hoja (2 quedan «sin fecha», 1 se ajusta a la fecha de creación) |
| `009_rev_kpis.sql` | Base analítica (estado y valor en una fecha, eventos de cierre, stock) y KPIs ejecutivos |
| `010_rev_series.sql` | Series por día/semana/mes/trimestre y detalle de oportunidades (drill-down) |
| `011_rev_conversion_forecast.sql` | Cohortes, embudo, distribución por etapa y forecast |
| `012_rev_performance.sql` | Rendimiento por canal y por responsable |
| `013_rev_health_insights.sql` | Salud del pipeline, riesgo de pérdida (umbrales en `health_config`) e insights |
| `014_actividad_ultima_accion_importada.sql` | **Opcional.** Registra «Última acción» de la hoja como nota para que los importados no figuren «sin seguimiento» |

### Cómo se calcula (resumen; el detalle está en el encabezado de cada archivo)
- **Stock** (pipeline activo/ponderado) = estado en una fecha de corte. **Flujo** (ganadas/perdidas/ingresadas) = eventos en un intervalo. Nunca se suman entre sí.
- **Cierres netos:** cada cambio de etapa suma al estado nuevo y resta al que deja. Una reapertura anula el cierre previo, así que ningún lead cuenta dos veces.
- **UF de un evento** = valor vigente en ese instante; corregir el valor después no reescribe el mes de cierre.
- **Conversión** = ganadas / (ganadas + perdidas) de los cierres del período, por cantidad y por valor (nunca mezcladas). La **conversión por cohorte** (leads creados en el mes) es otra métrica.
- **Responsable/canal** se atribuyen según el valor actual del lead, para que los totales por persona sumen el total global.
- **Forecast** = valor × probabilidad (`stage_config`, supuestos no calibrados) según `expected_close_at`. Sin fecha o con fecha vencida va en bloques aparte.
- **No se inventa nada:** sin datos contractuales no hay MRR ni churn; sin gasto publicitario no hay CPL ni CAC; los cierres sin fecha se informan aparte.
- Horas en `America/Santiago`.

### Pruebas
Las pruebas de las funciones SQL están en `supabase/tests/` y deben correrse **solo en una base local/desechable** (todo ocurre en una transacción con `ROLLBACK`).
Necesitan un Postgres con las migraciones 001, 003, 007, 009–013 y un esquema `auth` mínimo (`auth.users`, `auth.uid()`, rol `authenticated`).
```bash
cd supabase/tests
for t in rev_kpis rev_series rev_forecast rev_perf rev_health rev_consistency; do
  psql -v ON_ERROR_STOP=1 -d <base_local> -f ${t}_test.sql
done
```
`rev_consistency_test.sql` compara, sobre 400 leads con casos difíciles, la serie rápida contra la función de referencia en cada corte y verifica que KPIs, series, forecast, canales, responsables, salud y detalle sumen lo mismo.

## Publicar (Felipe)
1. Proyecto nuevo en Vercel desde este repo (framework Nuxt).
2. Variables: `NUXT_PUBLIC_SUPABASE_URL` y `NUXT_PUBLIC_SUPABASE_ANON_KEY`.
3. Dominio `crm.checkauditor.com` (CNAME a Vercel).
4. Supabase → Auth → URL Configuration: Site URL y Redirect URL `https://crm.checkauditor.com`.
5. Ejecutar `supabase/005_slack_boton_llamar_crm.sql` y `006_realtime.sql`.
6. Invitar a los 4 (Supabase → Auth → Users → Invite).

## Local
```bash
cp .env.example .env   # completar la clave anon
npm install
npm run dev
```
