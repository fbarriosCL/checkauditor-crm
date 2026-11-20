# CRM · Check Auditor

App interna (`crm.checkauditor.com`) para que el equipo vea los leads y los mueva por etapas hasta el cierre.
Nuxt 3 en modo SPA + Supabase (proyecto `ihtkakajwulpyxsonnph`). Sin costo: plan gratis de Supabase y Vercel.

## Pantallas
- **/login**: entrada con correo y contraseña. Solo los 4 usuarios creados en Supabase → Auth → Users (el enlace mágico se descartó: sin SMTP propio no se puede editar la plantilla y el enlace se gasta si el correo lo abre antes).
- **/** (pipeline): kanban por etapa; arrastrar cambia la etapa, "Perdido" exige motivo. Filtros por canal y responsable, buscador, total UF por columna, tiempo real.
- **/lead/:id**: datos, origen (canal, UTMs, IDs de clic), etapa, responsable, ICP, valor UF, próxima acción, notas, actividades e historial.
- **/nuevo**: lead manual (referidos, correos, eventos).
- **/llamar?n=569…**: puente para el botón "Llamar" de Slack (Slack solo acepta https; esta página abre `tel:`).

## Seguridad
- Usa la clave **anon** (pública por diseño). Todo el acceso lo controla RLS en Supabase: solo `team_members` activos ven o editan datos.
- No usa la `service_role`.

## Base de datos
`supabase/` tiene las migraciones en orden (001–004 ya aplicadas; 005 y 006 al publicar).

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
