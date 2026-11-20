<script setup lang="ts">
// Filtros globales del dashboard comercial: los usan KPIs, gráficos y tablas por igual.
const team = useTeam()
const filters = useRevFilters()

const PERIODS = [
  { days: 30, label: 'Últimos 30 días' },
  { days: 90, label: 'Últimos 90 días' },
  { days: 180, label: 'Últimos 6 meses' },
  { days: 365, label: 'Últimos 12 meses' },
  { days: 730, label: 'Últimos 24 meses' },
  { days: 0, label: 'Histórico completo' },
]
</script>

<template>
  <div class="toolbar" role="group" aria-label="Filtros del dashboard">
    <select v-model.number="filters.days" aria-label="Período">
      <option v-for="p in PERIODS" :key="p.days" :value="p.days">{{ p.label }}</option>
    </select>
    <select v-model="filters.owner" aria-label="Responsable">
      <option value="">Todos los responsables</option>
      <option v-for="m in team" :key="m.id" :value="m.id">{{ m.full_name }}</option>
    </select>
    <select v-model="filters.channel" aria-label="Canal">
      <option value="">Todos los canales</option>
      <option v-for="(label, key) in CHANNELS" :key="key" :value="key">{{ label }}</option>
    </select>
  </div>
</template>
