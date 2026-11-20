<script setup lang="ts">
// Evolución comercial — UF/mes. Cuatro series sobre un mismo eje:
//   FLUJOS del intervalo (UF ingresadas, ganadas, perdidas) y STOCK al cierre del intervalo (pipeline activo).
// Los flujos y el stock NO se suman entre sí.
const filters = useRevFilters()
const drill = useDrill()
const { wrap, width } = useChartWidth()

const GRANS: { key: RevGran, label: string, days: number }[] = [
  { key: 'day', label: 'Diaria', days: 1 },
  { key: 'week', label: 'Semanal', days: 7 },
  { key: 'month', label: 'Mensual', days: 30 },
  { key: 'quarter', label: 'Trimestral', days: 91 },
]
const SERIES = [
  { key: 'ing', label: 'UF ingresadas', color: 'var(--blue)', kind: 'flujo', uf: (b: RevBucket) => b.ing_uf, n: (b: RevBucket) => b.ing_n },
  { key: 'gan', label: 'UF ganadas', color: 'var(--green)', kind: 'flujo', uf: (b: RevBucket) => b.gan_uf, n: (b: RevBucket) => b.gan_n },
  { key: 'per', label: 'UF perdidas', color: 'var(--red)', kind: 'flujo', uf: (b: RevBucket) => b.per_uf, n: (b: RevBucket) => b.per_n },
  { key: 'pip', label: 'Pipeline activo', color: 'var(--yellow)', kind: 'stock', uf: (b: RevBucket) => b.pip_uf, n: (b: RevBucket) => b.pip_n },
] as const
type SeriesKey = typeof SERIES[number]['key']

const spanDays = computed(() => (filters.value.days > 0 ? filters.value.days : 1500))
const autoGran = (d: number): RevGran => (d <= 31 ? 'day' : d <= 200 ? 'week' : 'month')
const allowed = (g: { days: number }) => spanDays.value / g.days <= 150

const gran = ref<RevGran>(autoGran(spanDays.value))
const touched = ref(false)
const compare = ref(false)
// Eje derecho propio para el pipeline (stock): evita que su magnitud aplaste los flujos. Desactivado = un solo eje.
const dual = ref(false)
const visible = reactive<Record<SeriesKey, boolean>>({ ing: true, gan: true, per: true, pip: true })

const buckets = ref<RevBucket[]>([])
const prev = ref<RevBucket[]>([])
const loading = ref(true)
const error = ref('')
const hover = ref<number | null>(null)
const pinned = ref<number | null>(null)
let seq = 0

watch(() => filters.value.days, () => {
  const current = GRANS.find(g => g.key === gran.value)!
  if (!touched.value || !allowed(current))
    gran.value = autoGran(spanDays.value)
  if (!allowed(GRANS.find(g => g.key === gran.value)!))
    gran.value = 'month'
})

async function load() {
  const mine = ++seq
  loading.value = true
  error.value = ''
  try {
    const { from, to } = revRange(filters.value.days)
    const cur = await fetchRevSeries(from, to, gran.value, filters.value)
    let before: RevBucket[] = []
    if (compare.value && filters.value.days > 0)
      before = await fetchRevSeries(new Date(from.getTime() - (to.getTime() - from.getTime())), from, gran.value, filters.value)
    if (mine !== seq)
      return
    buckets.value = cur
    prev.value = before
    pinned.value = null
    hover.value = null
  }
  catch (e: any) {
    if (mine === seq)
      error.value = e.message
  }
  if (mine === seq)
    loading.value = false
}
onMounted(load)
watch([filters, gran, compare], load, { deep: true })

// Geometría
const H = 300
const M = { l: 48, t: 14, b: 30 }
const mr = computed(() => (dual.value ? 52 : 14))
const iw = computed(() => Math.max(10, width.value - M.l - mr.value))
const ih = H - M.t - M.b
const n = computed(() => buckets.value.length)
const x = (i: number) => M.l + (n.value <= 1 ? iw.value / 2 : (i * iw.value) / (n.value - 1))

const onRight = (key: SeriesKey) => dual.value && key === 'pip'
function maxOf(keys: readonly SeriesKey[]) {
  let max = 0
  for (const s of SERIES) {
    if (!visible[s.key] || !keys.includes(s.key))
      continue
    for (const b of buckets.value) max = Math.max(max, s.uf(b))
    if (compare.value)
      for (const b of prev.value) max = Math.max(max, s.uf(b))
  }
  return max
}
const scale = computed(() => niceScale(maxOf(dual.value ? ['ing', 'gan', 'per'] : ['ing', 'gan', 'per', 'pip'])))
const scaleR = computed(() => niceScale(maxOf(['pip'])))
const y = (v: number, key?: SeriesKey) => M.t + ih - (v / (key && onRight(key) ? scaleR.value.max : scale.value.max)) * ih

function path(list: RevBucket[], get: (b: RevBucket) => number, key: SeriesKey) {
  return list.map((b, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)},${y(get(b), key).toFixed(1)}`).join(' ')
}

const labelEvery = computed(() => Math.max(1, Math.ceil(n.value / Math.max(2, Math.floor(iw.value / 70)))))
const showDots = computed(() => n.value <= 40)

function indexAt(ev: PointerEvent) {
  const svg = ev.currentTarget as SVGElement
  const px = ev.clientX - svg.getBoundingClientRect().left
  if (n.value <= 1)
    return 0
  return Math.min(n.value - 1, Math.max(0, Math.round(((px - M.l) / iw.value) * (n.value - 1))))
}
function onMove(ev: PointerEvent) {
  hover.value = indexAt(ev)
}
function onClick(ev: PointerEvent) {
  const i = indexAt(ev)
  pinned.value = pinned.value === i ? null : i
}
function onKey(ev: KeyboardEvent) {
  if (!n.value)
    return
  if (ev.key === 'ArrowRight' || ev.key === 'ArrowLeft') {
    ev.preventDefault()
    const cur = pinned.value ?? (ev.key === 'ArrowRight' ? -1 : n.value)
    pinned.value = Math.min(n.value - 1, Math.max(0, cur + (ev.key === 'ArrowRight' ? 1 : -1)))
    hover.value = pinned.value
  }
  else if (ev.key === 'Escape') {
    pinned.value = null
  }
}

const active = computed(() => hover.value ?? pinned.value)
const tipLeft = computed(() => (active.value === null ? 0 : Math.min(Math.max(x(active.value), 105), width.value - 105)))

const DRILL_TITLE: Record<string, string> = {
  ing: 'UF ingresadas',
  gan: 'UF ganadas',
  per: 'UF perdidas',
  pip: 'Pipeline activo al cierre del intervalo',
}
const DRILL_KIND: Record<SeriesKey, DrillKind> = { ing: 'ingresadas', gan: 'ganadas', per: 'perdidas', pip: 'abiertas' }
function openDrill(key: SeriesKey) {
  const b = pinned.value === null ? null : buckets.value[pinned.value]
  if (b)
    drill.value = { kind: DRILL_KIND[key], from: b.desde, to: b.hasta, title: `${DRILL_TITLE[key]} · ${bucketLabel(b.inicio, gran.value)}` }
}

function exportCsv() {
  downloadCsv(`evolucion-comercial-${gran.value}.csv`, [
    ['Inicio', 'UF ingresadas', 'Oport. ingresadas', 'UF ganadas', 'Clientes ganados', 'UF perdidas', 'Oport. perdidas', 'Pipeline activo UF', 'Oport. abiertas'],
    ...buckets.value.map(b => [b.inicio.slice(0, 10), b.ing_uf, b.ing_n, b.gan_uf, b.gan_n, b.per_uf, b.per_n, b.pip_uf, b.pip_n]),
  ])
}

const summary = computed(() => {
  const t = (k: 'gan_uf' | 'per_uf' | 'ing_uf') => buckets.value.reduce((s, b) => s + b[k], 0)
  const last = buckets.value.at(-1)
  return `Gráfico de ${buckets.value.length} intervalos. Total ingresado ${fmtUf(t('ing_uf'))} UF, ganado ${fmtUf(t('gan_uf'))} UF, perdido ${fmtUf(t('per_uf'))} UF. Pipeline activo final ${fmtUf(last?.pip_uf ?? 0)} UF.`
})
</script>

<template>
  <section class="card chart">
    <div class="chart-head">
      <div>
        <h2>Evolución comercial — UF/mes</h2>
        <small class="muted">Ingresadas, ganadas y perdidas son movimientos del intervalo; el pipeline activo es el saldo abierto al cierre de cada intervalo.</small>
      </div>
      <div class="chart-tools">
        <select v-model="gran" aria-label="Granularidad" @change="touched = true">
          <option v-for="g in GRANS" :key="g.key" :value="g.key" :disabled="!allowed(g)">{{ g.label }}</option>
        </select>
        <label class="check" :title="filters.days === 0 ? 'No disponible en histórico completo' : ''">
          <input v-model="compare" type="checkbox" :disabled="filters.days === 0"> Comparar con período anterior
        </label>
        <label class="check" title="El pipeline es un saldo (stock), no un movimiento. Con eje propio se ven mejor los movimientos del período.">
          <input v-model="dual" type="checkbox"> Eje propio para pipeline
        </label>
        <button class="btn sm ghost" type="button" :disabled="!buckets.length" @click="exportCsv">CSV</button>
      </div>
    </div>

    <div class="chart-tools" role="group" aria-label="Series visibles" style="margin-bottom: 8px">
      <button v-for="s in SERIES" :key="s.key" class="chip" type="button" :aria-pressed="visible[s.key]" @click="visible[s.key] = !visible[s.key]">
        <i :style="{ background: s.color }" />{{ s.label }}
      </button>
    </div>

    <p v-if="error" class="err">No pudimos cargar la serie: {{ error }}</p>
    <p v-else-if="!loading && !buckets.length" class="muted">No hay leads en este período para los filtros elegidos.</p>

    <div ref="wrap" class="chart-wrap" :aria-busy="loading">
      <svg
        v-show="buckets.length"
        :viewBox="`0 0 ${width} ${H}`"
        :height="H"
        role="img"
        tabindex="0"
        :aria-label="summary"
        @pointermove="onMove"
        @pointerleave="hover = null"
        @click="onClick"
        @keydown="onKey"
      >
        <g>
          <line v-for="t in scale.ticks" :key="t" class="grid-line" :x1="M.l" :x2="width - mr" :y1="y(t)" :y2="y(t)" />
          <text v-for="t in scale.ticks" :key="`t${t}`" class="axis-text" :x="M.l - 8" :y="y(t) + 4" text-anchor="end">{{ fmtUf(t, 0) }}</text>
          <template v-if="dual">
            <text v-for="t in scaleR.ticks" :key="`r${t}`" class="axis-text" :x="width - mr + 8" :y="y(t, 'pip') + 4" fill="var(--yellow)" style="fill: var(--yellow)">{{ fmtUf(t, 0) }}</text>
          </template>
          <template v-for="(b, i) in buckets" :key="b.inicio">
            <text v-if="i % labelEvery === 0" class="axis-text" :x="x(i)" :y="H - 8" text-anchor="middle">{{ bucketLabel(b.inicio, gran) }}</text>
          </template>
        </g>

        <g v-if="compare">
          <template v-for="s in SERIES" :key="`p${s.key}`">
            <path v-if="visible[s.key] && prev.length" :d="path(prev, s.uf, s.key)" fill="none" :stroke="s.color" stroke-width="1.5" stroke-dasharray="4 4" opacity=".5" />
          </template>
        </g>

        <g>
          <template v-for="s in SERIES" :key="s.key">
            <path v-if="visible[s.key]" :d="path(buckets, s.uf, s.key)" fill="none" :stroke="s.color" stroke-width="2.25" stroke-linejoin="round" />
            <template v-if="visible[s.key] && showDots">
              <circle v-for="(b, i) in buckets" :key="i" :cx="x(i)" :cy="y(s.uf(b), s.key)" r="2.5" :fill="s.color" />
            </template>
          </template>
        </g>

        <g v-if="active !== null">
          <line :x1="x(active)" :x2="x(active)" :y1="M.t" :y2="M.t + ih" stroke="var(--muted)" stroke-dasharray="3 3" />
          <template v-for="s in SERIES" :key="`h${s.key}`">
            <circle v-if="visible[s.key]" :cx="x(active)" :cy="y(s.uf(buckets[active]), s.key)" r="5" :fill="s.color" stroke="var(--navy-2)" stroke-width="2" />
          </template>
        </g>
        <line v-if="pinned !== null" :x1="x(pinned)" :x2="x(pinned)" :y1="M.t" :y2="M.t + ih" stroke="var(--green)" stroke-width="1.5" />
      </svg>

      <div v-if="active !== null && buckets[active]" class="tip" :style="{ left: `${tipLeft}px` }">
        <b>{{ bucketLabel(buckets[active].inicio, gran) }}<template v-if="buckets[active].en_curso"> · en curso</template></b>
        <template v-for="s in SERIES" :key="s.key">
          <div v-if="visible[s.key]">
            <span><i :style="{ background: s.color }" />{{ s.label }}</span>
            <span>{{ fmtUf(s.uf(buckets[active]), 2) }} UF <small class="muted">({{ s.n(buckets[active]) }})</small></span>
          </div>
          <div v-if="visible[s.key] && compare && prev[active]" class="muted">
            <span>&nbsp;&nbsp;período anterior</span><span>{{ fmtUf(s.uf(prev[active]), 2) }} UF</span>
          </div>
        </template>
      </div>
    </div>

    <div v-if="pinned !== null && buckets[pinned]" class="pinned">
      <span class="muted">{{ bucketLabel(buckets[pinned].inicio, gran) }} — ver oportunidades:</span>
      <button v-for="s in SERIES" :key="s.key" class="chip" type="button" :disabled="!s.n(buckets[pinned])" @click="openDrill(s.key)">
        <i :style="{ background: s.color }" />{{ s.label }} ({{ s.n(buckets[pinned]) }})
      </button>
    </div>
    <p v-else-if="buckets.length" class="note-line muted">Haz clic en un intervalo (o usa las flechas del teclado) para ver las oportunidades que lo componen.</p>
  </section>
</template>
