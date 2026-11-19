// CRM interno de Check Auditor (crm.checkauditor.com). SPA: todo pasa en el navegador
// contra Supabase con la clave anon; la seguridad la da RLS (solo los 4 miembros del equipo).
export default defineNuxtConfig({
  compatibilityDate: '2025-01-01',
  future: { compatibilityVersion: 4 },
  ssr: false,
  css: ['~/assets/main.css'],
  runtimeConfig: {
    public: {
      // NUXT_PUBLIC_SUPABASE_URL y NUXT_PUBLIC_SUPABASE_ANON_KEY (clave anon, pública por diseño)
      supabaseUrl: '',
      supabaseAnonKey: '',
    },
  },
  app: {
    head: {
      title: 'CRM · Check Auditor',
      htmlAttrs: { lang: 'es' },
      meta: [{ name: 'robots', content: 'noindex, nofollow' }],
      link: [
        { rel: 'preconnect', href: 'https://fonts.googleapis.com' },
        { rel: 'stylesheet', href: 'https://fonts.googleapis.com/css2?family=Outfit:wght@500;600;700&family=Inter:wght@300;400;500;600&display=swap' },
      ],
    },
  },
})
