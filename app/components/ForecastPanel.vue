<script setup lang="ts">
// Proyección comercial. Es una ESTIMACIÓN, no ingreso garantizado:
//   Pipeline total   = todas las oportunidades abiertas.
//   Pipeline ponderado = valor × probabilidad de su etapa.
//   Forecast del mes = ponderado de las oportunidades con fecha estimada de cierre en ese mes.
// Sin fecha estimada, o con la fecha ya vencida, van en bloques aparte: nunca se asignan a un mes.
const filters = useRevFilters()

const observed = ref(false)
const fc = ref<RevForecast | null>(null)
const loading = ref(true)
const error = ref('')
let seq = 0

async function load() {
  const mine = ++seq
  loading.value = true
  error.value = ''
  try {
    const r = await fetchRevForecast(filters.value, observed.value)
    if (mine === seq)
      fc.value = r
  }
  catch (e: any) {
    if (mine === seq)
      error.value = e.message
  }
  if (mine === seq)
    loading.value = false
}
onMounted(load)
watch([filters, observed], load, { deep: true })

const uf = (n: number | null | undefined) => fmtUf(n, 1)
const stageLabel = (k: string) => STAGES.find(s => s.key === k)?.label ?? k
const fmtDay = (iso: string) => new Date(`${iso}T12:00:00`).toLocaleDateString('es-CL', { day: 'numeric', month: 'short' })

/** Nombre del mes actual + offset según la fecha de corte del forecast (hora de Santiago). */
function monthAt(offset: number) {
  const base = fc.value ? new Date(fc.value.al) : new Date()
  const d = new Date(base.toLocaleString('en-US', { timeZone: 'America/Santiago' }))
  d.setDate(1)
  d.setMonth(d.getMonth() + offset)
  const s = d.toLocaleDateString('es-CL', { month: 'long' })
  return s.charAt(0).toUpperCase() + s.slice(1)
}

const cards = computed(() => {
  const b = fc.value?.bloques
  if (!b)
    return []
  const three = b.mes0.pond + b.mes1.pond + b.mes2.pond
  return [
    { key: 'm0', label: `${monthAt(0)} (mes actual)`, pond: b.mes0.pond, pipe: b.mes0.uf, n: b.mes0.n, extra: fc.value!.ganado_mes.uf > 0 ? `Ya ganado este mes: ${uf(fc.value!.ganado_mes.uf)} UF` : 'Aún sin cierres este mes' },
    { key: 'm1', label: monthAt(1), pond: b.mes1.pond, pipe: b.mes1.uf, n: b.mes1.n, extra: '' },
    { key: 'm3', label: 'Próximos 3 meses', pond: three, pipe: b.mes0.uf + b.mes1.uf + b.mes2.uf, n: b.mes0.n + b.mes1.n + b.mes2.n, extra: '' },
  ]
})

const rows = computed(() => {
  const b = fc.value?.bloques
  if (!b)
    return []
  return [
    { label: `${monthAt(0)} (mes actual)`, v: b.mes0 },
    { label: monthAt(1), v: b.mes1 },
    { label: monthAt(2), v: b.mes2 },
    { label: 'Después de 3 meses', v: b.despues },
    { label: 'Fecha estimada vencida', v: b.vencida, warn: true },
    { label: 'Sin fecha estimada de cierre', v: b.sin_fecha, warn: true },
  ]
})
const cal = computed(() => fc.value?.calibracion)
</script>

<template>
  <section class="card chart">
    <div class="chart-head">
      <div>
        <h2>Proyección comercial</h2>
        <small class="muted">Valor esperado según etapa, probabilidad y fecha estimada de cierre. No es ingreso garantizado.</small>
      </div>
      <label class="check" :title="cal?.disponible ? '' : `Se necesitan al menos 30 cierres con trayectoria completa (hoy: ${cal?.cierres_completos ?? 0})`">
        <input v-model="observed" type="checkbox" :disabled="!cal?.disponible"> Usar probabilidades observadas
      </label>
    </div>

    <p v-if="error" class="err">No pudimos calcular la proyección: {{ error }}. ¿Ya ejecutaste la migración 011?</p>

    <template v-if="fc">
      <div class="fc-cards">
        <div v-for="c in cards" :key="c.key" class="fc-card">
          <span class="muted">{{ c.label }}</span>
          <strong>{{ uf(c.pond) }} UF</strong>
          <small class="muted">esperado · pipeline {{ uf(c.pipe) }} UF · {{ c.n }} {{ c.n === 1 ? 'oportunidad' : 'oportunidades' }}</small>
          <small v-if="c.extra" class="muted">{{ c.extra }}</small>
        </div>
      </div>

      <table class="tbl num">
        <thead><tr><th>Bloque</th><th>Oportunidades</th><th>Pipeline UF</th><th>Ponderado UF</th></tr></thead>
        <tbody>
          <tr v-for="r in rows" :key="r.label">
            <td :class="{ 'warn-text': r.warn && r.v.n }">{{ r.label }}</td>
            <td>{{ r.v.n }}</td>
            <td>{{ uf(r.v.uf) }}<small v-if="r.v.sin_valor" class="muted"> (+{{ r.v.sin_valor }} sin valor)</small></td>
            <td>{{ uf(r.v.pond) }}</td>
          </tr>
          <tr class="total">
            <td>Pipeline total abierto</td><td>{{ fc.total.n }}</td><td>{{ uf(fc.total.uf) }}</td><td>{{ uf(fc.total.pond) }}</td>
          </tr>
          <tr>
            <td>De ellos, comprometido <small class="muted">(etapas con prob. ≥ 70 %)</small></td>
            <td>{{ fc.comprometido.n }}</td><td>{{ uf(fc.comprometido.uf) }}</td><td>{{ uf(fc.comprometido.pond) }}</td>
          </tr>
        </tbody>
      </table>
      <p class="note-line muted">
        Cada oportunidad aparece en un solo bloque. Las que no tienen fecha estimada o la tienen vencida no se asignan a ningún mes: completa
        «Cierre estimado» en la ficha del lead para incluirlas.
      </p>
      <p class="note-line muted">
        <template v-if="cal?.usando_observado">Probabilidades observadas: ganadas / alcanzaron la etapa, calculadas con {{ cal.cierres_completos }} cierres con trayectoria completa.</template>
        <template v-else-if="cal?.disponible">Probabilidades configurables por etapa (supuestos, no calibrados). Hay historial suficiente para usar las observadas.</template>
        <template v-else>Probabilidades configurables por etapa (supuestos, no calibrados). Historial insuficiente para estimarlas: {{ cal?.cierres_completos ?? 0 }} de 30 cierres con trayectoria completa.</template>
      </p>

      <h2 style="margin-top: 14px">Próximas a cerrar (30 días)</h2>
      <p v-if="!fc.proximas.length" class="muted">Ninguna oportunidad abierta tiene fecha estimada de cierre en los próximos 30 días.</p>
      <table v-else class="tbl left">
        <tbody>
          <tr v-for="p in fc.proximas" :key="p.id">
            <td>{{ fmtDay(p.fecha) }}</td>
            <td><NuxtLink :to="`/lead/${p.id}`">{{ p.empresa || p.nombre || 'Sin nombre' }}</NuxtLink></td>
            <td>{{ stageLabel(p.etapa) }}</td>
            <td class="r">{{ p.uf ? `${uf(p.uf)} UF` : 'sin valor' }} <small class="muted">· {{ Math.round(p.prob * 100) }}%</small></td>
          </tr>
        </tbody>
      </table>
    </template>
    <p v-else-if="loading" class="muted">Calculando…</p>
  </section>
</template>

<style scoped>
.fc-cards { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 10px; margin-bottom: 12px; }
.fc-card { display: grid; gap: 2px; background: var(--navy-3); border: 1px solid var(--border); border-radius: 10px; padding: 12px; min-width: 0; }
.fc-card strong { font-size: 20px; font-weight: 500; }
.fc-card small { font-size: 11.5px; }
.warn-text { color: var(--amber); }
tr.total td { border-top: 1px solid var(--muted); font-weight: 500; }
td.r { text-align: right !important; }
@media (max-width: 900px) { .fc-cards { grid-template-columns: 1fr; } }
</style>
