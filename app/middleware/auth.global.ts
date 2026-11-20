export default defineNuxtRouteMiddleware(async (to) => {
  if (to.path === '/llamar')
    return
  // Supabase devuelve los fallos del enlace en el hash (#error=otp_expired); sin esto se perdían en silencio.
  const hashErr = /error_code=([a-z_]+)/.exec(to.hash || '')?.[1]
  if (hashErr)
    return navigateTo({ path: '/login', query: { e: hashErr } })
  const sb = useSupabase()
  const { data: { session } } = await sb.auth.getSession()
  if (!session)
    return to.path === '/login' ? undefined : navigateTo('/login')
  if (!useMe().value)
    await loadTeam()
  if (to.path === '/login')
    return navigateTo('/')
})
