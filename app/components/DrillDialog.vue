<script setup lang="ts">
// Detalle de oportunidades detrás de un número del dashboard (drill-down), con exportación a CSV.
const drill = useDrill()
const filters = useRevFilters()
const team = useTeam()

const HEALTH: DrillKind[] = ['estancadas', 'vencidas', 'riesgo']
const isHealth = computed(() => !!drill.value && HEALTH.includes(drill.value.kind))
const RISK_LABEL: Record<string, string> = {
  inactividad: 'Sin actividad',
  fecha_vencida: 'Fecha de cierre vencida',
  postergaciones: 'Fecha pospuesta',
  exceso_etapa: 'Demasiado tiempo en la etapa',
}
const daysLabel = computed(() => (drill.value?.kind === 'vencidas' ? 'Días de atraso' : 'Días sin seguimiento'))
const rows = ref<DrillRow[]>([])
const loading = ref(false)
const error = ref('')
let seq = 0

watch(drill, async (d) => {
  if (!d)
    return
  const mine = ++seq
  loading.value = true
  error.value = ''
  rows.value = []
  try {
    const r = HEALTH.includes(d.kind)
      ? await fetchRevHealthDrill(d.kind, d.days ?? 7, filters.value)
      : await fetchRevDrill(d.kind, d.from, d.to, filters.value)
    if (mine === seq)
      rows.value = r
  }
  catch (e: any) {
    if (mine === seq)
      error.value = e.message
  }
  if (mine === seq)
    loading.value = false
})

const stageLabel = (k: string) => STAGES.find(s => s.key === k)?.label ?? k
const ownerName = (id: string | null) => team.value.find(m => m.id === id)?.full_name ?? '—'
const total = computed(() => rows.value.reduce((s, r) => s + (r.uf ?? 0), 0))
const dateLabel = computed(() => (drill.value?.kind === 'abiertas' || isHealth.value ? '' : 'Fecha'))
const fmtDay = (iso: string | null) => (iso ? new Date(iso).toLocaleDateString('es-CL', { timeZone: 'America/Santiago' }) : '—')

function close() {
  drill.value = null
}
function exportCsv() {
  const d = drill.value
  if (!d)
    return
  downloadCsv(`oportunidades-${d.kind}-${d.from.slice(0, 10)}-${d.to.slice(0, 10)}.csv`, [
    ['Empresa', 'Contacto', 'Etapa', 'Canal', 'Responsable', 'UF/mes', isHealth.value ? daysLabel.value : 'Fecha'],
    ...rows.value.map(r => [r.empresa, r.nombre, stageLabel(r.etapa), CHANNELS[r.canal] ?? r.canal, ownerName(r.owner_id), r.uf, isHealth.value ? (r.dias ?? '') : (r.fecha ? fmtDay(r.fecha) : '')]),
  ])
}
function onKey(e: KeyboardEvent) {
  if (e.key === 'Escape')
    close()
}
onMounted(() => window.addEventListener('keydown', onKey))
onBeforeUnmount(() => window.removeEventListener('keydown', onKey))
</script>

<template>
  <div v-if="drill" class="overlay" role="dialog" aria-modal="true" :aria-label="drill.title" @click.self="close">
    <div class="card drill">
      <div class="chart-head">
        <div>
          <h2>{{ drill.title }}</h2>
          <small v-if="isHealth" class="muted">Foto de hoy · se respetan responsable y canal</small>
          <small v-else class="muted">{{ fmtDay(drill.from) }} – {{ fmtDay(drill.to) }} · se respetan los filtros activos</small>
        </div>
        <div class="chart-tools">
          <button class="btn sm ghost" type="button" :disabled="!rows.length" @click="exportCsv">Exportar CSV</button>
          <button class="btn sm" type="button" @click="close">Cerrar</button>
        </div>
      </div>

      <p v-if="error" class="err">{{ error }}</p>
      <p v-else-if="loading" class="muted">Cargando…</p>
      <p v-else-if="!rows.length" class="muted">No hay oportunidades para este indicador en el período.</p>
      <div v-else class="tbl-scroll">
        <table class="tbl">
          <thead>
            <tr>
              <th>Empresa</th><th>Contacto</th><th>Etapa</th><th>Canal</th><th>Responsable</th><th class="r">UF/mes</th><th v-if="isHealth" class="r">{{ daysLabel }}</th><th v-if="isHealth && drill.kind === 'riesgo'">Señales</th><th v-if="dateLabel">{{ dateLabel }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="r in rows" :key="r.id">
              <td><NuxtLink :to="`/lead/${r.id}`">{{ r.empresa || 'Sin empresa' }}</NuxtLink></td>
              <td>{{ r.nombre || '—' }}</td>
              <td>{{ stageLabel(r.etapa) }}</td>
              <td>{{ CHANNELS[r.canal] ?? r.canal }}</td>
              <td>{{ ownerName(r.owner_id) }}</td>
              <td class="r">{{ r.uf ? fmtUf(r.uf, 2) : '—' }}</td>
              <td v-if="isHealth" class="r">{{ r.dias ?? '—' }}</td>
              <td v-if="isHealth && drill.kind === 'riesgo'">{{ (r.motivos ?? []).map(m => RISK_LABEL[m] ?? m).join(' · ') }}</td>
              <td v-if="dateLabel">{{ fmtDay(r.fecha) }}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <small v-if="rows.length" class="muted">
        {{ rows.length }} {{ rows.length === 1 ? 'oportunidad' : 'oportunidades' }} · {{ fmtUf(total, 2) }} UF/mes
        <template v-if="rows.length >= 1000"> · se muestran las 1.000 de mayor valor</template>
      </small>
    </div>
  </div>
</template>
