export default defineNuxtRouteMiddleware(async (to) => {
  if (to.path === '/llamar')
    return
  const sb = useSupabase()
  const { data: { session } } = await sb.auth.getSession()
  if (!session)
    return to.path === '/login' ? undefined : navigateTo('/login')
  if (!useMe().value)
    await loadTeam()
  if (to.path === '/login')
    return navigateTo('/')
})
