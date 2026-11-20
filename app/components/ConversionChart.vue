<script setup lang="ts">
// Evolución de conversión comercial.
//   Conversión de cierres del mes = ganadas / (ganadas + perdidas) de las oportunidades que cerraron ese mes.
//   Se muestra por cantidad O por valor (nunca mezcladas). Abajo, la conversión por COHORTE (leads creados
//   ese mes) es otra métrica: no se confunde con la de cierres.
const filters = useRevFilters()
const { wrap, width } = useChartWidth()

type Metric = 'cantidad' | 'valor'
const metric = ref<Metric>('cantidad')
const all = ref<RevBucket[]>([])
const cohorts = ref<RevCohort[]>([])
const fromDisplay = ref(new Date())
const loading = ref(true)
const error = ref('')
const hover = ref<number | null>(null)
let seq = 0

async function load() {
  const mine = ++seq
  loading.value = true
  error.value = ''
  try {
    const { from, to } = revMonthlyRange(filters.value.days)
    // Historial completo: el promedio histórico y el móvil de los primeros meses lo necesitan.
    const [a, c] = await Promise.all([
      fetchRevSeries(new Date('2015-01-01T00:00:00Z'), to, 'month', filters.value, true),
      fetchRevCohorts(from, to, filters.value),
    ])
    if (mine !== seq)
      return
    all.value = a
    cohorts.value = c
    fromDisplay.value = from
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

const won = (m: RevBucket) => (metric.value === 'cantidad' ? m.gan_n : m.gan_uf)
const lost = (m: RevBucket) => (metric.value === 'cantidad' ? m.per_n : m.per_uf)
const rateOf = (w: number, l: number) => (w + l > 0 ? (100 * w) / (w + l) : null)

// Serie sobre TODO el historial (para promedios) y luego el tramo visible.
const rateAll = computed(() => all.value.map(m => rateOf(won(m), lost(m))))
const ma3All = computed(() => all.value.map((m, j) => {
  if (j < 2)
    return null
  const w = all.value.slice(j - 2, j + 1)
  return w.some(x => x.en_curso) ? null : rateOf(w.reduce((s, x) => s + won(x), 0), w.reduce((s, x) => s + lost(x), 0))
}))
const hist = computed(() => rateOf(all.value.reduce((s, m) => s + won(m), 0), all.value.reduce((s, m) => s + lost(m), 0)))

const offset = computed(() => Math.max(0, all.value.findIndex(m => new Date(m.fin) > fromDisplay.value)))
const months = computed(() => all.value.slice(offset.value))
const rate = computed(() => rateAll.value.slice(offset.value))
const ma3 = computed(() => ma3All.value.slice(offset.value))

const completeIdx = computed(() => months.value.map((m, i) => i).filter(i => !months.value[i].en_curso))
const withRate = computed(() => completeIdx.value.filter(i => rate.value[i] !== null))
const best = computed(() => (withRate.value.length ? withRate.value.reduce((a, b) => (rate.value[b]! > rate.value[a]! ? b : a)) : null))
const worst = computed(() => (withRate.value.length ? withRate.value.reduce((a, b) => (rate.value[b]! < rate.value[a]! ? b : a)) : null))
const lastChange = computed(() => {
  const c = completeIdx.value
  if (c.length < 2)
    return null
  const a = rate.value[c.at(-2)!]
  const b = rate.value[c.at(-1)!]
  return a === null || b === null ? null : Math.round((b - a) * 10) / 10
})
const trend = computed(() => {
  const c = completeIdx.value.slice(-3)
  if (c.length < 3 || c.some(i => rate.value[i] === null))
    return null
  const d = rate.value[c[2]]! - rate.value[c[0]]!
  return { d: Math.round(d * 10) / 10, label: d > 2 ? 'Al alza' : d < -2 ? 'A la baja' : 'Estable' }
})
const closes = (m: RevBucket) => m.gan_n + m.per_n

// Geometría
const H = 260
const M = { l: 44, r: 14, t: 14, b: 30 }
const iw = computed(() => Math.max(10, width.value - M.l - M.r))
const ih = H - M.t - M.b
const n = computed(() => months.value.length)
const slot = computed(() => iw.value / Math.max(1, n.value))
const cx = (i: number) => M.l + slot.value * (i + 0.5)
const y = (v: number) => M.t + ih - (v / 100) * ih
const TICKS = [0, 25, 50, 75, 100]
function path(values: (number | null)[]) {
  let d = ''
  let open = false
  values.forEach((v, i) => {
    if (v === null) {
      open = false
      return
    }
    d += `${open ? 'L' : 'M'}${cx(i).toFixed(1)},${y(v).toFixed(1)} `
    open = true
  })
  return d
}
const labelEvery = computed(() => Math.max(1, Math.ceil(n.value / Math.max(2, Math.floor(iw.value / 56)))))
const tipLeft = computed(() => (hover.value === null ? 0 : Math.min(Math.max(cx(hover.value), 105), width.value - 105)))
function onMove(ev: PointerEvent) {
  const px = ev.clientX - (ev.currentTarget as SVGElement).getBoundingClientRect().left
  hover.value = Math.min(n.value - 1, Math.max(0, Math.floor((px - M.l) / slot.value)))
}

const pct = (v: number | null | undefined, d = 1) => (v == null ? '—' : `${v.toLocaleString('es-CL', { maximumFractionDigits: d })}%`)
const monthLabel = (i: number | null) => (i === null ? '' : monthName(months.value[i].inicio))

function exportCsv() {
  downloadCsv(`conversion-${metric.value}.csv`, [
    ['Mes', 'Ganadas', 'Perdidas', 'Conversión %', 'Promedio móvil 3 meses %', 'Promedio histórico %'],
    ...months.value.map((m, i) => [monthName(m.inicio), won(m), lost(m), rate.value[i] === null ? '' : Math.round(rate.value[i]! * 10) / 10,
      ma3.value[i] === null ? '' : Math.round(ma3.value[i]! * 10) / 10, hist.value === null ? '' : Math.round(hist.value * 10) / 10]),
  ])
}
</script>

<template>
  <section class="card chart">
    <div class="chart-head">
      <div>
        <h2>Evolución de conversión comercial</h2>
        <small class="muted">Ganadas / (ganadas + perdidas) de las oportunidades que cerraron cada mes.</small>
      </div>
      <div class="chart-tools">
        <select v-model="metric" aria-label="Tipo de conversión">
          <option value="cantidad">Por cantidad</option>
          <option value="valor">Por valor (UF)</option>
        </select>
        <button class="btn sm ghost" type="button" :disabled="!months.length" @click="exportCsv">CSV</button>
      </div>
    </div>

    <p v-if="error" class="err">No pudimos cargar la conversión: {{ error }}</p>
    <p v-else-if="!loading && !months.length" class="muted">Todavía no hay datos para estos filtros.</p>

    <template v-if="months.length">
      <div class="stat-row">
        <div>
          <span class="muted">Mejor / peor mes</span>
          <strong>{{ best === null ? '—' : pct(rate[best], 0) }} <small class="muted">/</small> {{ worst === null ? '—' : pct(rate[worst], 0) }}</strong>
          <small class="muted">{{ best === null ? 'Sin cierres' : `${monthLabel(best)} / ${monthLabel(worst)}` }}</small>
        </div>
        <div>
          <span class="muted">Último mes vs. anterior</span>
          <strong :class="lastChange === null ? '' : lastChange >= 0 ? 'ok' : 'warn-text'">{{ lastChange === null ? '—' : `${lastChange >= 0 ? '+' : ''}${lastChange} pp` }}</strong>
          <small class="muted">Meses completos con cierres</small>
        </div>
        <div>
          <span class="muted">Tendencia (3 meses)</span>
          <strong :class="trend === null ? '' : trend.d > 2 ? 'ok' : trend.d < -2 ? 'warn-text' : ''">{{ trend === null ? '—' : trend.label }}</strong>
          <small class="muted">{{ trend === null ? 'Faltan meses con cierres' : `${trend.d >= 0 ? '+' : ''}${trend.d} pp en 3 meses` }}</small>
        </div>
      </div>

      <div class="chart-tools" style="margin-bottom: 6px">
        <span class="chip" style="cursor: default"><i style="background: var(--green)" />Conversión del mes</span>
        <span class="chip" style="cursor: default"><i style="background: var(--muted)" />Promedio histórico {{ pct(hist, 0) }}</span>
        <span class="chip" style="cursor: default"><i style="background: var(--yellow)" />Promedio móvil 3 meses</span>
      </div>

      <div ref="wrap" class="chart-wrap">
        <svg
          :viewBox="`0 0 ${width} ${H}`"
          :height="H"
          role="img"
          :aria-label="`Conversión mensual ${metric === 'cantidad' ? 'por cantidad' : 'por valor'}. Promedio histórico ${pct(hist, 0)}.`"
          @pointermove="onMove"
          @pointerleave="hover = null"
        >
          <line v-for="t in TICKS" :key="t" class="grid-line" :x1="M.l" :x2="width - M.r" :y1="y(t)" :y2="y(t)" />
          <text v-for="t in TICKS" :key="`t${t}`" class="axis-text" :x="M.l - 8" :y="y(t) + 4" text-anchor="end">{{ t }}%</text>
          <template v-for="(m, i) in months" :key="m.inicio">
            <text v-if="i % labelEvery === 0" class="axis-text" :x="cx(i)" :y="H - 8" text-anchor="middle">{{ bucketLabel(m.inicio, 'month') }}</text>
          </template>

          <line v-if="hist !== null" :x1="M.l" :x2="width - M.r" :y1="y(hist)" :y2="y(hist)" stroke="var(--muted)" stroke-dasharray="5 4" stroke-width="1.5" />
          <path :d="path(ma3)" fill="none" stroke="var(--yellow)" stroke-width="2.25" stroke-linejoin="round" />
          <path :d="path(rate)" fill="none" stroke="var(--green)" stroke-width="2.25" stroke-linejoin="round" />
          <template v-for="(v, i) in rate" :key="`p${i}`">
            <circle v-if="v !== null" :cx="cx(i)" :cy="y(v)" :r="hover === i ? 5 : 3" fill="var(--green)" :opacity="months[i].en_curso ? 0.5 : 1" />
          </template>
          <line v-if="hover !== null" :x1="cx(hover)" :x2="cx(hover)" :y1="M.t" :y2="M.t + ih" stroke="var(--muted)" stroke-dasharray="3 3" />
        </svg>

        <div v-if="hover !== null && months[hover]" class="tip" :style="{ left: `${tipLeft}px` }">
          <b>{{ monthLabel(hover) }}<template v-if="months[hover].en_curso"> · en curso</template></b>
          <div><span><i style="background: var(--green)" />Conversión</span><span>{{ pct(rate[hover]) }}</span></div>
          <div><span>Ganadas / perdidas</span><span>{{ months[hover].gan_n }} / {{ months[hover].per_n }}</span></div>
          <div v-if="metric === 'valor'"><span>UF ganadas / perdidas</span><span>{{ fmtUf(months[hover].gan_uf) }} / {{ fmtUf(months[hover].per_uf) }}</span></div>
          <div v-if="ma3[hover] !== null"><span><i style="background: var(--yellow)" />Móvil 3 meses</span><span>{{ pct(ma3[hover]) }}</span></div>
          <div v-if="closes(months[hover]) <= 2"><small class="muted">Pocos cierres: la tasa es poco representativa</small></div>
        </div>
      </div>
      <p class="note-line muted">El promedio móvil acumula los cierres de 3 meses completos. Los meses sin cierres no tienen tasa y cortan la línea.</p>

      <h2 style="margin-top: 16px">Conversión por cohorte</h2>
      <small class="muted">De los leads creados cada mes, cuántos están hoy ganados. Es otra métrica: mide el destino de los leads que entraron, no los cierres del mes.</small>
      <div class="tbl-scroll">
        <table class="tbl num">
          <thead><tr><th>Cohorte</th><th>Leads</th><th>Ganados</th><th>Perdidos</th><th>Abiertos</th><th>Ganados / leads</th><th>Ganados / resueltos</th></tr></thead>
          <tbody>
            <tr v-for="c in cohorts" :key="c.inicio">
              <td>{{ monthName(c.inicio) }}</td><td>{{ c.n }}</td><td>{{ c.ganados }}</td><td>{{ c.perdidos }}</td>
              <td :class="{ muted: !c.abiertos }">{{ c.abiertos }}</td><td>{{ pct(c.conv_ingresados) }}</td><td>{{ pct(c.conv_resueltos) }}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <small class="muted">Las cohortes recientes aún tienen leads abiertos: su tasa final puede subir.</small>
    </template>
  </section>
</template>

<style scoped>
.warn-text { color: var(--amber); }
</style>
