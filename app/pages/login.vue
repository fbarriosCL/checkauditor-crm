<script setup lang="ts">
const sb = useSupabase()
const email = ref('')
const password = ref('')
const state = ref<'idle' | 'sending' | 'error'>('idle')
const error = ref('')

async function send() {
  state.value = 'sending'
  error.value = ''
  const { error: e } = await sb.auth.signInWithPassword({
    email: email.value.trim().toLowerCase(),
    password: password.value,
  })
  if (e) {
    state.value = 'error'
    error.value = e.status === 400
      ? 'Correo o contraseña incorrectos.'
      : `No pudimos iniciar sesión (${e.message}). Intenta de nuevo en un minuto.`
    return
  }
  await loadTeam()
  await navigateTo('/')
}
</script>

<template>
  <div class="login">
    <form class="card" @submit.prevent="send">
      <p class="eyebrow">Check Auditor · CRM</p>
      <h1>Entra con tu correo</h1>
      <p class="muted">Solo el equipo de Check Auditor tiene acceso.</p>
      <input v-model="email" type="email" required placeholder="nombre@checkauditor.com" autocomplete="email">
      <input v-model="password" type="password" required placeholder="Contraseña" autocomplete="current-password">
      <button class="btn" :disabled="state === 'sending'">{{ state === 'sending' ? 'Entrando…' : 'Entrar' }}</button>
      <p v-if="error" class="err">{{ error }}</p>
    </form>
  </div>
</template>
