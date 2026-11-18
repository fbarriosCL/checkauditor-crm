<script setup lang="ts">
const sb = useSupabase()
const email = ref('')
const state = ref<'idle' | 'sending' | 'sent' | 'error'>('idle')
const error = ref('')

async function send() {
  state.value = 'sending'
  const { error: e } = await sb.auth.signInWithOtp({
    email: email.value.trim().toLowerCase(),
    // Solo correos ya invitados: el registro público está cerrado en Supabase.
    options: { shouldCreateUser: false, emailRedirectTo: window.location.origin },
  })
  if (e) {
    state.value = 'error'
    error.value = 'Ese correo no tiene acceso al CRM. Pide una invitación.'
    return
  }
  state.value = 'sent'
}
</script>

<template>
  <div class="login">
    <form class="card" @submit.prevent="send">
      <p class="eyebrow">Check Auditor · CRM</p>
      <h1>Entra con tu correo</h1>
      <p class="muted">Te enviamos un enlace para iniciar sesión. Sin contraseñas.</p>
      <template v-if="state !== 'sent'">
        <input v-model="email" type="email" required placeholder="nombre@checkauditor.com" autocomplete="email">
        <button class="btn" :disabled="state === 'sending'">{{ state === 'sending' ? 'Enviando…' : 'Enviar enlace' }}</button>
        <p v-if="state === 'error'" class="err">{{ error }}</p>
      </template>
      <p v-else class="ok">Listo. Revisa tu correo y abre el enlace en este mismo navegador.</p>
    </form>
  </div>
</template>
