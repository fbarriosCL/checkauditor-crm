// Al abrir el enlace de "crear/recuperar contraseña", Supabase emite PASSWORD_RECOVERY:
// llevamos a la persona a elegir su contraseña en vez de dejarla caer en el pipeline.
export default defineNuxtPlugin(() => {
  useSupabase().auth.onAuthStateChange((event) => {
    if (event === 'PASSWORD_RECOVERY')
      setTimeout(() => navigateTo('/nueva-clave'), 0)
  })
})
