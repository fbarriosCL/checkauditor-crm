<script setup lang="ts">
const sb = useSupabase()
const password = ref('')
const state = ref<'idle' | 'saving' | 'error'>('idle')
const error = ref('')

async function save() {
  if (password.value.length < 8) {
    state.value = 'error'
    error.value = 'Usa al menos 8 caracteres.'
    return
  }
  state.value = 'saving'
  error.value = ''
  const { error: e } = await sb.auth.updateUser({ password: password.value })
  if (e) {
    state.value = 'error'
    error.value = `No pudimos guardar la contraseña (${e.message}).`
    return
  }
  await navigateTo('/')
}
</script>

<template>
  <div class="login">
    <form class="card" @submit.prevent="save">
      <p class="eyebrow">Check Auditor · CRM</p>
      <h1>Elige tu contraseña</h1>
      <p class="muted">La usarás para entrar al CRM.</p>
      <input v-model="password" type="password" required minlength="8" placeholder="Nueva contraseña (mín. 8)" autocomplete="new-password">
      <button class="btn" :disabled="state === 'saving'">{{ state === 'saving' ? 'Guardando…' : 'Guardar y entrar' }}</button>
      <p v-if="error" class="err">{{ error }}</p>
    </form>
  </div>
</template>
