<script setup lang="ts">
const sb = useSupabase()
const route = useRoute()
const me = useMe()
const bare = computed(() => ['/login', '/llamar'].includes(route.path))
async function logout() {
  await sb.auth.signOut()
  navigateTo('/login')
}
</script>

<template>
  <div class="shell">
    <header v-if="!bare" class="top">
      <NuxtLink to="/" class="brand"><i class="dot" />Check Auditor <span>CRM</span></NuxtLink>
      <nav>
        <NuxtLink to="/">Pipeline</NuxtLink>
        <NuxtLink to="/nuevo" class="btn sm">+ Nuevo lead</NuxtLink>
        <span class="muted">{{ me?.full_name }}</span>
        <button class="link" @click="logout">Salir</button>
      </nav>
    </header>
    <main><slot /></main>
  </div>
</template>
