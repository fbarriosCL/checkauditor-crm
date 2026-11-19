<script setup lang="ts">
// Puente para el botón "Llamar" de Slack: Slack solo acepta https en botones,
// así que el botón apunta aquí y esta página abre el marcador (tel:).
const n = String(useRoute().query.n ?? '').replace(/\D/g, '')
const valid = /^\d{8,15}$/.test(n)
const tel = `tel:+${n}`
onMounted(() => {
  if (valid)
    window.location.href = tel
})
</script>

<template>
  <div class="login">
    <div class="card">
      <p class="eyebrow">Check Auditor · CRM</p>
      <template v-if="valid">
        <h1>Llamando a +{{ n }}</h1>
        <p class="muted">Si no se abrió el teléfono, toca el botón.</p>
        <a class="btn" :href="tel">Llamar</a>
      </template>
      <h1 v-else>Número no válido</h1>
    </div>
  </div>
</template>
