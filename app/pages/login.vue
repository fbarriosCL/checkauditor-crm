<script setup lang="ts">
const sb = useSupabase()
const route = useRoute()
const email = ref('')
const code = ref('')
const state = ref<'idle' | 'sending' | 'sent' | 'verifying' | 'error'>('idle')
const error = ref(route.query.e
  ? 'El enlace expiró o ya fue usado (a veces el antivirus del correo lo abre antes). Pide uno nuevo y usa el código de 6 dígitos.'
  : '')

async function send() {
  state.value = 'sending'
  error.value = ''
  const { error: e } = await sb.auth.signInWithOtp({
    email: email.value.trim().toLowerCase(),
    // Solo correos ya invitados: el registro público está cerrado en Supabase.
    options: { shouldCreateUser: false, emailRedirectTo: window.location.origin },
  })
  if (e) {
    state.value = 'error'
    error.value = e.status === 422
      ? 'Ese correo no tiene acceso al CRM. Pide una invitación.'
      : `No pudimos enviar el correo (${e.message}). Intenta de nuevo en un minuto.`
    return
  }
  state.value = 'sent'
}

async function verify() {
  state.value = 'verifying'
  error.value = ''
  const { error: e } = await sb.auth.verifyOtp({
    email: email.value.trim().toLowerCase(),
    token: code.value.trim(),
    type: 'email',
  })
  if (e) {
    state.value = 'sent'
    error.value = 'Código incorrecto o vencido. Revisa el último correo o pide uno nuevo.'
    return
  }
  await loadTeam()
  await navigateTo('/')
}
</script>

<template>
  <div class="login">
    <form v-if="state !== 'sent' && state !== 'verifying'" class="card" @submit.prevent="send">
      <p class="eyebrow">Check Auditor · CRM</p>
      <h1>Entra con tu correo</h1>
      <p class="muted">Te enviamos un código para iniciar sesión. Sin contraseñas.</p>
      <input v-model="email" type="email" required placeholder="nombre@checkauditor.com" autocomplete="email">
      <button class="btn" :disabled="state === 'sending'">{{ state === 'sending' ? 'Enviando…' : 'Enviar código' }}</button>
      <p v-if="error" class="err">{{ error }}</p>
    </form>
    <form v-else class="card" @submit.prevent="verify">
      <p class="eyebrow">Check Auditor · CRM</p>
      <h1>Revisa tu correo</h1>
      <p class="muted">Escribe el código de 6 dígitos que enviamos a {{ email }}.</p>
      <input v-model="code" inputmode="numeric" autocomplete="one-time-code" maxlength="8" required placeholder="123456">
      <button class="btn" :disabled="state === 'verifying'">{{ state === 'verifying' ? 'Verificando…' : 'Entrar' }}</button>
      <p v-if="error" class="err">{{ error }}</p>
    </form>
  </div>
</template>
