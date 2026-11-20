<script setup lang="ts">
// Productividad comercial por responsable: no se mide por cantidad de leads sino por UF cerradas, conversión,
// ciclo y disciplina de seguimiento. Hacer clic en una persona filtra todo el dashboard.
const filters = useRevFilters()
const team = useTeam()

const rows = ref<RevPerfRow[]>([])
const loading = ref(true)
const error = ref('')
let seq = 0

async function load() {
  const mine = ++seq
  loading.value = true
  error.value = ''
  try {
    const r = await fetchRevPerformance('owner', filters.value)
    if (mine === seq)
      rows.value = r
  }
  catch (e: any) {
    if (mine === seq)
      error.value = e.message
  }
  if (mine === seq)
    loading.value = false
}
onMounted(load)
watch(filters, load, { deep: true })

const name = (id: string | null) => (id ? (team.value.find(m => m.id === id)?.full_name ?? 'Responsable inactivo') : 'Sin responsable')
// El SQL ya ordena por UF ganadas (ranking de vendedores por UF cerradas).
const pct = (v: number | null) => (v === null ? '—' : `${fmtUf(v, 0)}%`)

function pick(id: string | null) {
  if (id)
    filters.value.owner = filters.value.owner === id ? '' : id
}

function exportCsv() {
  downloadCsv('productividad-por-responsable.csv', [
    ['Responsable', 'Leads asignados', 'Oportunidades abiertas', 'UF en negociación', 'UF ganadas', 'UF perdidas', 'Conversión cantidad %', 'Conversión valor %',
      'Ticket promedio', 'Días a cierre', `Sin seguimiento (>${STALE_DAYS} d)`, 'UF sin seguimiento', 'Acciones vencidas'],
    ...rows.value.map(r => [name(r.clave), r.creados, r.abiertas, r.uf_abiertas, r.gan_uf, r.per_uf, r.conv_cantidad, r.conv_valor, r.ticket, r.dias_cierre, r.sin_seguimiento, r.uf_sin_seguimiento, r.vencidas]),
  ])
}
</script>

<template>
  <section class="card chart">
    <div class="chart-head">
      <div>
        <h2>Productividad por responsable</h2>
        <small class="muted">Ranking por UF ganadas. Haz clic en una persona para filtrar todo el dashboard; la tabla siempre compara a todo el equipo.</small>
      </div>
      <button class="btn sm ghost" type="button" :disabled="!rows.length" @click="exportCsv">CSV</button>
    </div>

    <p v-if="error" class="err">No pudimos cargar la productividad: {{ error }}. ¿Ya ejecutaste la migración 012?</p>
    <p v-else-if="!loading && !rows.length" class="muted">No hay actividad por responsable en este período para los filtros elegidos.</p>

    <div v-if="rows.length" class="tbl-scroll" style="max-height: none">
      <table class="tbl num l2">
        <thead>
          <tr>
            <th>#</th><th>Responsable</th><th title="Leads creados en el período que hoy tiene asignados">Leads asignados</th><th>Abiertas</th>
            <th>UF en negociación</th><th>UF ganadas</th><th>UF perdidas</th><th>Conv. cantidad</th><th>Conv. valor</th>
            <th>Ticket prom.</th><th>Días a cierre</th><th :title="`Sin actividad ni cambio de etapa hace más de ${STALE_DAYS} días`">Sin seguimiento</th><th title="Próxima acción ya vencida">Acciones vencidas</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="(r, i) in rows" :key="r.clave ?? 'none'" class="click" :class="{ sel: filters.owner === r.clave }" tabindex="0" @click="pick(r.clave)" @keydown.enter="pick(r.clave)">
            <td class="muted">{{ i + 1 }}</td>
            <td>{{ name(r.clave) }}</td>
            <td>{{ r.creados }}</td>
            <td>{{ r.abiertas }}</td>
            <td>{{ fmtUf(r.uf_abiertas) }}</td>
            <td class="ok">{{ fmtUf(r.gan_uf) }}<small class="muted"> · {{ r.gan_n }}</small></td>
            <td>{{ fmtUf(r.per_uf) }}<small class="muted"> · {{ r.per_n }}</small></td>
            <td>{{ pct(r.conv_cantidad) }}</td>
            <td>{{ pct(r.conv_valor) }}</td>
            <td>{{ r.ticket === null ? '—' : fmtUf(r.ticket) }}</td>
            <td>{{ r.dias_cierre === null ? '—' : fmtUf(r.dias_cierre, 0) }}</td>
            <td :class="{ 'warn-text': r.sin_seguimiento }">{{ r.sin_seguimiento }}<small v-if="r.sin_seguimiento" class="muted"> · {{ fmtUf(r.uf_sin_seguimiento, 0) }} UF</small></td>
            <td :class="{ 'warn-text': r.vencidas }">{{ r.vencidas }}</td>
          </tr>
        </tbody>
      </table>
      <p class="note-line muted">
        Conversión = ganadas / (ganadas + perdidas) de los cierres del período, por cantidad y por valor. Días a cierre = desde la creación del lead hasta que se ganó.
        Sin seguimiento: más de {{ STALE_DAYS }} días sin actividad ni cambio de etapa. Acciones vencidas: la próxima acción ya pasó.
        Un lead cuenta para quien lo tiene asignado hoy.
      </p>
    </div>
  </section>
</template>

<style scoped>
tr.sel td { background: var(--navy-3); }
tr.sel td:nth-child(2) { color: var(--green); }
.warn-text { color: var(--amber); }
</style>
