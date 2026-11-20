<script setup lang="ts">
// Embudo comercial en UF. Dos lecturas que NO se mezclan:
//   Cohorte: sigue a los leads creados en el período y cuenta a los que alcanzaron cada etapa alguna vez.
//   Distribución actual: cuántas oportunidades abiertas hay en cada etapa hoy.
const filters = useRevFilters()

const view = ref<'cohorte' | 'actual'>('cohorte')
const funnel = ref<RevFunnel | null>(null)
const funnelAll = ref<RevFunnel | null>(null)
const dist = ref<RevDistribution | null>(null)
const loading = ref(true)
const error = ref('')
let seq = 0

async function load() {
  const mine = ++seq
  loading.value = true
  error.value = ''
  try {
    const [f, fa, d] = await Promise.all([
      fetchRevFunnel(filters.value.days, filters.value),
      fetchRevFunnel(0, filters.value, true),
      fetchRevDistribution(filters.value),
    ])
    if (mine !== seq)
      return
    funnel.value = f
    funnelAll.value = fa
    dist.value = d
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

const stageLabel = (k: string) => STAGES.find(s => s.key === k)?.label ?? k
const uf = (n: number | null | undefined) => fmtUf(n, 1)
const pct = (a: number, b: number) => (b > 0 ? Math.round((a / b) * 100) : null)

const cohortRows = computed(() => {
  const f = funnel.value?.etapas
  if (!f?.length)
    return []
  const total = f[0].alcanzaron
  let worst = -1
  let worstRate = Infinity
  f.forEach((e, i) => {
    const p = i && f[i - 1].alcanzaron ? e.alcanzaron / f[i - 1].alcanzaron : null
    if (p !== null && p < worstRate && i < f.length - 1) {
      worstRate = p
      worst = i
    }
  })
  return f.map((e, i) => {
    const all = funnelAll.value?.etapas
    return {
      ...e,
      label: stageLabel(e.etapa),
      width: total ? Math.max(2, (e.alcanzaron / total) * 100) : 0,
      share: pct(e.alcanzaron, total),
      step: i ? pct(e.alcanzaron, f[i - 1].alcanzaron) : null,
      stepAll: i && all ? pct(all[i].alcanzaron, all[i - 1].alcanzaron) : null,
      worst: i === worst,
      won: e.etapa === 'ganado',
    }
  })
})

const distRows = computed(() => {
  const d = dist.value
  if (!d)
    return []
  const max = Math.max(1, ...d.etapas.map(e => e.uf))
  return d.etapas.map(e => ({ ...e, label: stageLabel(e.etapa), width: e.uf > 0 ? Math.max(2, (e.uf / max) * 100) : 0, share: d.total_uf > 0 ? Math.round((e.uf / d.total_uf) * 100) : null }))
})
</script>

<template>
  <section class="card chart">
    <div class="chart-head">
      <div>
        <h2>Embudo comercial en UF</h2>
        <small class="muted">
          <template v-if="view === 'cohorte'">Leads creados en el período y la etapa más avanzada que alcanzó cada uno.</template>
          <template v-else>Oportunidades abiertas hoy, por etapa en que se encuentran.</template>
        </small>
      </div>
      <div class="chart-tools" role="group" aria-label="Tipo de embudo">
        <button class="chip" type="button" :aria-pressed="view === 'cohorte'" @click="view = 'cohorte'">Cohorte</button>
        <button class="chip" type="button" :aria-pressed="view === 'actual'" @click="view = 'actual'">Distribución actual</button>
      </div>
    </div>

    <p v-if="error" class="err">No pudimos cargar el embudo: {{ error }}. ¿Ya ejecutaste la migración 011?</p>

    <template v-else-if="view === 'cohorte' && funnel">
      <p v-if="!funnel.total" class="muted">No hay leads creados en este período para los filtros elegidos.</p>
      <template v-else>
        <table class="tbl num">
          <thead><tr><th>Etapa</th><th>Leads</th><th>UF/mes</th><th>% cohorte</th><th>Paso</th><th title="Conversión histórica a la etapa desde la anterior (todos los leads)">Paso hist.</th><th>Días en etapa</th></tr></thead>
          <tbody>
            <template v-for="r in cohortRows" :key="r.etapa">
              <tr>
                <td>{{ r.label }}</td><td>{{ r.alcanzaron }}</td><td>{{ uf(r.uf) }}</td><td>{{ r.share === null ? '—' : `${r.share}%` }}</td>
                <td :class="{ 'warn-text': r.worst, ok: r.won }">{{ r.step === null ? '—' : `${r.step}%` }}</td>
                <td class="muted">{{ r.stepAll === null ? '—' : `${r.stepAll}%` }}</td>
                <td>{{ r.dias_prom === null ? '—' : uf(r.dias_prom) }}</td>
              </tr>
              <tr class="barrow"><td colspan="7"><div class="bar"><i :class="{ warn: r.worst, best: r.won }" :style="{ width: `${r.width}%` }" /></div></td></tr>
            </template>
          </tbody>
        </table>
        <p class="note-line muted">
          «Paso» es el % de la etapa anterior que llegó a esta. Ámbar: donde más se pierde. «Días en etapa» promedia las estadías ya terminadas.
          Perdido no cuenta como avance.
        </p>
        <p v-if="funnel.incompletos" class="note-line muted">
          {{ funnel.incompletos }} {{ funnel.incompletos === 1 ? 'lead importado solo conserva' : 'leads importados solo conservan' }} su etapa final (sin etapas intermedias):
          el embudo subestima los pasos intermedios de quienes se perdieron.
        </p>
      </template>
    </template>

    <template v-else-if="view === 'actual' && dist">
      <p v-if="!dist.total_n" class="muted">No hay oportunidades abiertas para los filtros elegidos.</p>
      <template v-else>
        <table class="tbl num">
          <thead><tr><th>Etapa</th><th>Oportunidades</th><th>UF/mes</th><th>% del pipeline</th></tr></thead>
          <tbody>
            <template v-for="r in distRows" :key="r.etapa">
              <tr>
                <td>{{ r.label }}</td><td>{{ r.n }}</td>
                <td>{{ uf(r.uf) }}<small v-if="r.sin_valor" class="muted"> (+{{ r.sin_valor }} sin valor)</small></td>
                <td>{{ r.share === null ? '—' : `${r.share}%` }}</td>
              </tr>
              <tr class="barrow"><td colspan="4"><div class="bar"><i :style="{ width: `${r.width}%` }" /></div></td></tr>
            </template>
            <tr class="total"><td>Total abierto</td><td>{{ dist.total_n }}</td><td>{{ uf(dist.total_uf) }}</td><td>100%</td></tr>
          </tbody>
        </table>
        <p class="note-line muted">Es una foto de hoy: no mide conversión entre etapas. Para eso usa la vista Cohorte. No cambia con el período, sí con responsable y canal.</p>
      </template>
    </template>
    <p v-else-if="loading" class="muted">Cargando…</p>
  </section>
</template>

<style scoped>
.warn-text { color: var(--amber); }
tr.barrow td { border-top: 0; padding-top: 0; padding-bottom: 8px; text-align: left !important; }
tr.total td { border-top: 1px solid var(--muted); font-weight: 500; }
</style>
