<script setup lang="ts">
// Ventas mensuales — UF/mes. Una barra por mes calendario (hora de Santiago).
// Promedios y mejor mes se calculan solo con meses COMPLETOS (el mes en curso se muestra aparte, atenuado),
// e incluyen los meses sin cierres como cero.
const filters = useRevFilters()
const drill = useDrill()
const { wrap, width } = useChartWidth()

const months = ref<RevBucket[]>([])
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
    const r = await fetchRevSeries(from, to, 'month', filters.value, true)
    if (mine === seq)
      months.value = r
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

const complete = computed(() => months.value.filter(m => !m.en_curso))
const avg = computed(() => (complete.value.length ? complete.value.reduce((s, m) => s + m.gan_uf, 0) / complete.value.length : null))
const best = computed(() => (complete.value.length ? complete.value.reduce((a, b) => (b.gan_uf > a.gan_uf ? b : a)) : null))
// Promedio móvil de 3 meses completos (null mientras no haya 3 meses).
const ma3 = computed(() => months.value.map((m, i) => {
  if (m.en_curso || i < 2)
    return null
  const w = months.value.slice(i - 2, i + 1)
  return w.some(x => x.en_curso) ? null : w.reduce((s, x) => s + x.gan_uf, 0) / 3
}))
const lastChange = computed(() => {
  const c = complete.value
  if (c.length < 2 || !c.at(-2)!.gan_uf)
    return null
  return Math.round(((c.at(-1)!.gan_uf - c.at(-2)!.gan_uf) / c.at(-2)!.gan_uf) * 100)
})
const variation = (i: number) => {
  const prev = months.value[i - 1]
  // Un mes en curso no es comparable con un mes completo.
  if (!prev || !prev.gan_uf || months.value[i].en_curso)
    return null
  return Math.round(((months.value[i].gan_uf - prev.gan_uf) / prev.gan_uf) * 100)
}

// Geometría
const H = 280
const M = { l: 48, r: 14, t: 14, b: 30 }
const iw = computed(() => Math.max(10, width.value - M.l - M.r))
const ih = H - M.t - M.b
const n = computed(() => months.value.length)
const slot = computed(() => iw.value / Math.max(1, n.value))
const barW = computed(() => Math.min(56, slot.value * 0.62))
const cx = (i: number) => M.l + slot.value * (i + 0.5)
const scale = computed(() => niceScale(Math.max(0, ...months.value.map(m => m.gan_uf), avg.value ?? 0)))
const y = (v: number) => M.t + ih - (v / scale.value.max) * ih
const ma3Path = computed(() => {
  let d = ''
  ma3.value.forEach((v, i) => {
    if (v !== null)
      d += `${d ? 'L' : 'M'}${cx(i).toFixed(1)},${y(v).toFixed(1)} `
  })
  return d
})
const labelEvery = computed(() => Math.max(1, Math.ceil(n.value / Math.max(2, Math.floor(iw.value / 56)))))
const tipLeft = computed(() => (hover.value === null ? 0 : Math.min(Math.max(cx(hover.value), 105), width.value - 105)))

function openDrill(i: number) {
  const m = months.value[i]
  if (m?.gan_n)
    drill.value = { kind: 'ganadas', from: m.desde, to: m.hasta, title: `UF ganadas · ${monthName(m.inicio)}` }
}
const ticket = (m: RevBucket) => (m.gan_vn > 0 ? m.gan_uf / m.gan_vn : null)

function exportCsv() {
  downloadCsv('ventas-mensuales.csv', [
    ['Mes', 'UF ganadas', 'Clientes', 'Ticket promedio', 'Variación %', 'Mes en curso'],
    ...months.value.map((m, i) => [monthName(m.inicio), m.gan_uf, m.gan_n, ticket(m) == null ? '' : Math.round(ticket(m)! * 100) / 100, variation(i) ?? '', m.en_curso ? 'sí' : '']),
  ])
}
</script>

<template>
  <section class="card chart">
    <div class="chart-head">
      <div>
        <h2>Ventas mensuales — UF/mes</h2>
        <small class="muted">UF/mes ganadas en cada mes. Los meses sin cierres cuentan como 0.</small>
      </div>
      <button class="btn sm ghost" type="button" :disabled="!months.length" @click="exportCsv">CSV</button>
    </div>

    <p v-if="error" class="err">No pudimos cargar las ventas mensuales: {{ error }}</p>
    <p v-else-if="!loading && !months.length" class="muted">Todavía no hay datos para estos filtros.</p>

    <template v-if="months.length">
      <div class="stat-row">
        <div><span class="muted">Promedio mensual de UF ganadas</span><strong>{{ avg === null ? '—' : `${fmtUf(avg)} UF` }}</strong><small class="muted">{{ complete.length }} meses completos</small></div>
        <div><span class="muted">Mejor mes</span><strong>{{ best && best.gan_uf > 0 ? `${fmtUf(best.gan_uf)} UF` : '—' }}</strong><small class="muted">{{ best && best.gan_uf > 0 ? monthName(best.inicio) : 'Sin cierres' }}</small></div>
        <div>
          <span class="muted">Último mes completo vs. anterior</span>
          <strong :class="lastChange === null ? '' : lastChange >= 0 ? 'ok' : 'warn-text'">{{ lastChange === null ? '—' : `${lastChange >= 0 ? '+' : ''}${lastChange}%` }}</strong>
          <small class="muted">{{ complete.length >= 2 ? `${monthName(complete.at(-1)!.inicio)} vs. ${monthName(complete.at(-2)!.inicio)}` : 'Se necesitan 2 meses completos' }}</small>
        </div>
      </div>

      <div class="chart-tools" style="margin-bottom: 6px">
        <span class="chip" style="cursor: default"><i style="background: var(--green)" />UF ganadas</span>
        <span class="chip" style="cursor: default"><i style="background: var(--muted)" />Promedio del período</span>
        <span class="chip" style="cursor: default"><i style="background: var(--yellow)" />Promedio móvil 3 meses</span>
      </div>

      <div ref="wrap" class="chart-wrap">
        <svg
          :viewBox="`0 0 ${width} ${H}`"
          :height="H"
          role="img"
          :aria-label="`Barras de UF ganadas por mes. Promedio mensual ${fmtUf(avg)} UF.`"
          @pointerleave="hover = null"
        >
          <line v-for="t in scale.ticks" :key="t" class="grid-line" :x1="M.l" :x2="width - M.r" :y1="y(t)" :y2="y(t)" />
          <text v-for="t in scale.ticks" :key="`t${t}`" class="axis-text" :x="M.l - 8" :y="y(t) + 4" text-anchor="end">{{ fmtUf(t, 0) }}</text>

          <g v-for="(m, i) in months" :key="m.inicio" style="cursor: pointer" @pointermove="hover = i" @click="openDrill(i)">
            <rect :x="M.l + slot * i" :y="M.t" :width="slot" :height="ih" fill="transparent" />
            <rect
              :x="cx(i) - barW / 2" :y="y(m.gan_uf)" :width="barW" :height="Math.max(0, M.t + ih - y(m.gan_uf))" rx="3"
              :fill="m.en_curso ? 'none' : 'var(--green)'" stroke="var(--green)" :stroke-dasharray="m.en_curso ? '4 3' : undefined"
              :opacity="hover === null || hover === i ? 1 : 0.55"
            />
            <text v-if="i % labelEvery === 0" class="axis-text" :x="cx(i)" :y="H - 8" text-anchor="middle">{{ bucketLabel(m.inicio, 'month') }}</text>
          </g>

          <line v-if="avg !== null" :x1="M.l" :x2="width - M.r" :y1="y(avg)" :y2="y(avg)" stroke="var(--muted)" stroke-dasharray="5 4" stroke-width="1.5" />
          <path v-if="ma3Path" :d="ma3Path" fill="none" stroke="var(--yellow)" stroke-width="2.25" stroke-linejoin="round" />
        </svg>

        <div v-if="hover !== null && months[hover]" class="tip" :style="{ left: `${tipLeft}px` }">
          <b>{{ monthName(months[hover].inicio) }}<template v-if="months[hover].en_curso"> · en curso</template></b>
          <div><span><i style="background: var(--green)" />UF ganadas</span><span>{{ fmtUf(months[hover].gan_uf, 2) }} UF</span></div>
          <div><span>Clientes</span><span>{{ months[hover].gan_n }}</span></div>
          <div v-if="ma3[hover] !== null"><span><i style="background: var(--yellow)" />Móvil 3 meses</span><span>{{ fmtUf(ma3[hover], 2) }} UF</span></div>
          <div v-if="months[hover].gan_n"><small class="muted">Clic para ver los clientes</small></div>
        </div>
      </div>

      <div class="tbl-scroll">
        <table class="tbl num">
          <thead><tr><th>Mes</th><th>UF ganadas</th><th>Clientes</th><th>Ticket promedio</th><th>Variación</th></tr></thead>
          <tbody>
            <tr v-for="(m, i) in months" :key="m.inicio" :class="{ click: m.gan_n }" @click="openDrill(i)">
              <td>{{ monthName(m.inicio) }}<small v-if="m.en_curso" class="muted"> · en curso</small></td>
              <td>{{ fmtUf(m.gan_uf, 2) }}</td>
              <td>{{ m.gan_n }}</td>
              <td>{{ ticket(m) == null ? '—' : fmtUf(ticket(m), 2) }}</td>
              <td :class="variation(i) === null ? 'muted' : variation(i)! >= 0 ? 'ok' : 'warn-text'">{{ variation(i) === null ? '—' : `${variation(i)! >= 0 ? '+' : ''}${variation(i)}%` }}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </template>
  </section>
</template>

<style scoped>
.warn-text { color: var(--amber); }
</style>
