<script setup lang="ts">
// Observaciones automáticas: reglas determinísticas sobre los datos reales (no usa IA ni inventa causas).
// Cada regla exige un mínimo de datos; si no se cumple ninguna, se dice explícitamente.
const filters = useRevFilters()

const items = ref<RevInsight[]>([])
const loading = ref(true)
const error = ref('')
let seq = 0

async function load() {
  const mine = ++seq
  loading.value = true
  error.value = ''
  try {
    const r = await fetchRevInsights(filters.value)
    if (mine === seq)
      items.value = r
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

const n = (v: number | string | undefined, d = 1) => fmtUf(Number(v ?? 0), d)
const channel = (k: unknown) => CHANNELS[String(k)] ?? String(k)

function text(i: RevInsight): string {
  const d = i.datos
  switch (i.codigo) {
    case 'conversion_sube': return `La conversión comercial subió: ${n(d.actual, 0)}% en el período frente a ${n(d.previo, 0)}% en el anterior.`
    case 'conversion_baja': return `La conversión comercial bajó: ${n(d.actual, 0)}% en el período frente a ${n(d.previo, 0)}% en el anterior.`
    case 'ganadas_suben': return `Las UF ganadas crecieron durante los últimos tres meses completos, de ${n(d.primero)} a ${n(d.ultimo)} UF.`
    case 'ganadas_bajan': return `Las UF ganadas disminuyeron durante los últimos tres meses completos, de ${n(d.primero)} a ${n(d.ultimo)} UF.`
    case 'canal_concentra': return `${channel(d.canal)} concentra el ${n(d.pct, 0)}% de las UF ganadas del período (${n(d.uf)} UF).`
    case 'alto_valor_sin_seguimiento': return `${n(d.n, 0)} ${Number(d.n) === 1 ? 'oportunidad de alto valor lleva' : 'oportunidades de alto valor llevan'} más de 7 días sin seguimiento (${n(d.uf)} UF).`
    case 'pipeline_cae': return `El pipeline activo cayó ${n(Math.abs(Number(d.pct)), 0)}% desde el cierre anterior (${n(d.previo)} → ${n(d.actual)} UF).`
    case 'pipeline_crece': return `El pipeline activo creció ${n(d.pct, 0)}% desde el cierre anterior (${n(d.previo)} → ${n(d.actual)} UF).`
    case 'motivo_domina': return `«${LOST_REASONS[String(d.motivo)] ?? d.motivo}» explica el ${n(d.pct, 0)}% de las oportunidades perdidas del período (${n(d.n, 0)}).`
    case 'forecast_sin_fecha': return `El ${n(d.pct, 0)}% del pipeline en UF (${n(d.uf)} UF) no tiene fecha estimada de cierre: la proyección mensual queda incompleta.`
    case 'acciones_vencidas': return `${n(d.n, 0)} ${Number(d.n) === 1 ? 'oportunidad tiene' : 'oportunidades tienen'} la próxima acción vencida (${n(d.uf)} UF).`
    default: return i.codigo
  }
}
const MARK: Record<string, string> = { alerta: 'Atención', positivo: 'Mejora', info: 'Dato' }
</script>

<template>
  <section class="card chart">
    <div class="chart-head">
      <div>
        <h2>Insights</h2>
        <small class="muted">Observaciones calculadas con reglas fijas sobre tus datos del período y filtros activos. No son predicciones.</small>
      </div>
    </div>
    <p v-if="error" class="err">No pudimos calcular los insights: {{ error }}. ¿Ya ejecutaste la migración 013?</p>
    <p v-else-if="!loading && !items.length" class="muted">Sin observaciones destacadas: ninguna regla se cumple con los datos de este período (varias exigen un mínimo de cierres para no sacar conclusiones con muestras pequeñas).</p>
    <ul v-else class="insights">
      <li v-for="i in items" :key="i.codigo" :class="i.tipo">
        <span class="tag">{{ MARK[i.tipo] }}</span>
        <span>{{ text(i) }}</span>
      </li>
    </ul>
  </section>
</template>

<style scoped>
.insights { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; }
.insights li { display: flex; gap: 10px; align-items: baseline; padding: 10px 12px; background: var(--navy-3); border: 1px solid var(--border); border-left-width: 3px; border-radius: 8px; }
.insights li.alerta { border-left-color: var(--amber); }
.insights li.positivo { border-left-color: var(--green); }
.insights li.info { border-left-color: var(--muted); }
.insights .tag { flex: none; }
.insights li.alerta .tag { color: var(--amber); border-color: var(--amber); }
.insights li.positivo .tag { color: var(--green); border-color: var(--green); }
</style>
