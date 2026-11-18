<script setup lang="ts">
const emit = defineEmits<{ confirm: [reason: string, detail: string], cancel: [] }>()
const reason = ref('')
const detail = ref('')
</script>

<template>
  <div class="overlay" @click.self="emit('cancel')">
    <form class="card" @submit.prevent="emit('confirm', reason, detail)">
      <h2>¿Por qué se perdió?</h2>
      <select v-model="reason" required>
        <option value="" disabled>Elige un motivo</option>
        <option v-for="(label, key) in LOST_REASONS" :key="key" :value="key">{{ label }}</option>
      </select>
      <textarea v-model="detail" rows="3" placeholder="Detalle (opcional)" />
      <div class="row">
        <button type="button" class="btn ghost" @click="emit('cancel')">Cancelar</button>
        <button class="btn">Marcar como perdido</button>
      </div>
    </form>
  </div>
</template>
