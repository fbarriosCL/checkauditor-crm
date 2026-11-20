<script setup lang="ts">
// Rendimiento por canal: ranking, conversión y evolución mensual. Hacer clic en un canal filtra todo el dashboard.
// No hay datos de inversión publicitaria en el CRM: no se calcula costo por lead ni CAC (no se inventan).
const filters = useRevFilters()
const { wrap, width } = useChartWidth()

type SortKey = 'gan_uf' | 'conv' | 'volumen'
const sort = ref<SortKey>('gan_uf')
const metric = ref<'uf' | 'leads'>('uf')
const rows = ref<RevPerfRow[]>([])
const monthly = ref<RevChannelMonth[]>([])
const loading = ref(true)
const error = ref('')
const hover = ref<number | null>(null)
let seq = 0

async function load() {
  const mine = ++seq
  loading.value = true
  error.value = ''
  try {
    const [r, m] = await Promise.all([fetchRevPerformance('channel', filters.value), fetchRevChannelMonthly(filters.value)])
    if (mine === seq) {
      rows.value = r
      monthly.value = m
    }
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

const label = (k: string | null) => (k ? (CHANNELS[k] ?? k) : 'Sin canal')

const SORTS: { key: SortKey, label: string }[] = [
  { key: 'gan_uf', label: 'UF ganadas' },
  { key: 'conv', label: 'Conversión' },
  { key: 'volumen', label: 'Volumen' },
]
const ranked = computed(() => {
  const list = [...rows.value]
  const conv = (r: RevPerfRow) => r.conv_cantidad ?? -1
  // Volumen de oportunidades = leads creados en el período; el desempate es siempre UF ganadas.
  if (sort.value === 'conv')
    list.sort((a, b) => conv(b) - conv(a) || b.gan_uf - a.gan_uf)
  else if (sort.value === 'volumen')
    list.sort((a, b) => b.creados - a.creados || b.gan_uf - a.gan_uf)
  else
    list.sort((a, b) => b.gan_uf - a.gan_uf || b.creados - a.creados)
  return list
})
const maxWon = computed(() => Math.max(1, ...rows.value.map(r => r.gan_uf)))

function pick(k: string | null) {
  if (k)
    filters.value.channel = filters.value.channel === k ? '' : k
}

// ---- Evolución mensual apilada por canal ----
const PALETTE = ['#5AA2F0', '#B58CF2', '#4FC3D9', '#F29B6B', '#E58BB5', '#E8C547']
const OTHER = '#9AA4B2'
const value = (m: RevChannelMonth) => (metric.value === 'uf' ? m.gan_uf : m.ing_n)

const channelOrder = computed(() => {
  const tot = new Map<string, number>()
  for (const m of monthly.value)
    tot.set(m.canal, (tot.get(m.canal) ?? 0) + Math.max(0, value(m)))
  return [...tot.entries()].sort((a, b) => b[1] - a[1]).map(e => e[0])
})
const top = computed(() => channelOrder.value.slice(0, PALETTE.length))
const hasOther = computed(() => channelOrder.value.length > PALETTE.length)
const colorOf = (c: string) => (top.value.includes(c) ? PALETTE[top.value.indexOf(c)] : OTHER)

const monthKeys = computed(() => {
  const ks = [...new Set(monthly.value.map(m => monthKey(m.inicio)))].sort()
  if (!ks.length)
    return []
  const out: string[] = []
  for (let k = ks[0]; k <= ks.at(-1)!; k = nextMonthKey(k)) out.push(k)
  return out
})
const stacks = computed(() => monthKeys.value.map((k) => {
  const part = new Map<string, number>()
  for (const m of monthly.value) {
    if (monthKey(m.inicio) !== k)
      continue
    const key = top.value.includes(m.canal) ? m.canal : '__otros'
    part.set(key, (part.get(key) ?? 0) + value(m))
  }
  const segs = [...top.value, '__otros'].map(c => ({ canal: c, v: Math.max(0, part.get(c) ?? 0) })).filter(s => s.v > 0)
  return { key: k, segs, total: segs.reduce((s, x) => s + x.v, 0) }
}))

const H = 240
const M = { l: 44, r: 14, t: 14, b: 30 }
const iw = computed(() => Math.max(10, width.value - M.l - M.r))
const ih = H - M.t - M.b
const slot = computed(() => iw.value / Math.max(1, stacks.value.length))
const barW = computed(() => Math.min(48, slot.value * 0.62))
const cx = (i: number) => M.l + slot.value * (i + 0.5)
const scale = computed(() => niceScale(Math.max(0, ...stacks.value.map(s => s.total))))
const y = (v: number) => M.t + ih - (v / scale.value.max) * ih
const labelEvery = computed(() => Math.max(1, Math.ceil(stacks.value.length / Math.max(2, Math.floor(iw.value / 56)))))
const tipLeft = computed(() => (hover.value === null ? 0 : Math.min(Math.max(cx(hover.value), 105), width.value - 105)))
const fmtVal = (v: number) => (metric.value === 'uf' ? `${fmtUf(v, 1)} UF` : String(v))

function exportCsv() {
  downloadCsv('rendimiento-por-canal.csv', [
    ['Canal', 'Leads', 'Oportunidades abiertas', 'UF pipeline', 'UF ganadas', 'Ganadas', 'UF perdidas', 'Perdidas', 'Conversión cantidad %', 'Conversión valor %', 'Ticket promedio'],
    ...ranked.value.map(r => [label(r.clave), r.creados, r.abiertas, r.uf_abiertas, r.gan_uf, r.gan_n, r.per_uf, r.per_n, r.conv_cantidad, r.conv_valor, r.ticket]),
  ])
}
</script>

<template>
  <section class="card chart">
    <div class="chart-head">
      <div>
        <h2>Rendimiento por canal</h2>
        <small class="muted">Haz clic en un canal para filtrar todo el dashboard. La tabla siempre compara todos los canales.</small>
      </div>
      <div class="chart-tools">
        <span class="muted">Ordenar por</span>
        <button v-for="s in SORTS" :key="s.key" class="chip" type="button" :aria-pressed="sort === s.key" @click="sort = s.key">{{ s.label }}</button>
        <button class="btn sm ghost" type="button" :disabled="!rows.length" @click="exportCsv">CSV</button>
      </div>
    </div>

    <p v-if="error" class="err">No pudimos cargar el rendimiento por canal: {{ error }}. ¿Ya ejecutaste la migración 012?</p>
    <p v-else-if="!loading && !rows.length" class="muted">No hay actividad por canal en este período para los filtros elegidos.</p>

    <div v-if="rows.length" class="tbl-scroll" style="max-height: none">
      <table class="tbl num l2">
        <thead>
          <tr><th>#</th><th>Canal</th><th>Leads</th><th>UF pipeline</th><th>UF ganadas</th><th>Conversión</th><th>Ticket prom.</th></tr>
        </thead>
        <tbody>
          <tr v-for="(r, i) in ranked" :key="r.clave ?? 'none'" class="click" :class="{ sel: filters.channel === r.clave }" tabindex="0" @click="pick(r.clave)" @keydown.enter="pick(r.clave)">
            <td class="muted">{{ i + 1 }}</td>
            <td>{{ label(r.clave) }}</td>
            <td>{{ r.creados }}</td>
            <td>{{ fmtUf(r.uf_abiertas) }}<small class="muted"> · {{ r.abiertas }}</small></td>
            <td>
              <div class="wcell"><span>{{ fmtUf(r.gan_uf) }}<small class="muted"> · {{ r.gan_n }}</small></span><div class="bar"><i class="best" :style="{ width: `${Math.max(0, (r.gan_uf / maxWon) * 100)}%` }" /></div></div>
            </td>
            <td>{{ r.conv_cantidad === null ? '—' : `${fmtUf(r.conv_cantidad, 0)}%` }}<small class="muted"> · {{ r.conv_valor === null ? '—' : `${fmtUf(r.conv_valor, 0)}% UF` }}</small></td>
            <td>{{ r.ticket === null ? '—' : fmtUf(r.ticket) }}</td>
          </tr>
        </tbody>
      </table>
      <p class="note-line muted">
        Leads = creados en el período. UF pipeline = abiertas hoy (cantidad al lado). Conversión = ganadas / (ganadas + perdidas) de los cierres del período,
        por cantidad y por valor. Sin datos de inversión publicitaria en el CRM: no se calculan costo por lead ni costo de adquisición.
      </p>
    </div>

    <template v-if="stacks.length">
      <div class="chart-head" style="margin-top: 18px">
        <h2 style="font-size: 15px">Evolución mensual por canal</h2>
        <div class="chart-tools" role="group" aria-label="Métrica mensual">
          <button class="chip" type="button" :aria-pressed="metric === 'uf'" @click="metric = 'uf'">UF ganadas</button>
          <button class="chip" type="button" :aria-pressed="metric === 'leads'" @click="metric = 'leads'">Leads ingresados</button>
        </div>
      </div>
      <div class="chart-tools" style="margin-bottom: 6px">
        <span v-for="c in top" :key="c" class="chip" style="cursor: default"><i :style="{ background: colorOf(c) }" />{{ label(c) }}</span>
        <span v-if="hasOther" class="chip" style="cursor: default"><i :style="{ background: OTHER }" />Otros</span>
      </div>
      <div ref="wrap" class="chart-wrap">
        <svg :viewBox="`0 0 ${width} ${H}`" :height="H" role="img" :aria-label="`Barras apiladas por canal: ${metric === 'uf' ? 'UF ganadas' : 'leads ingresados'} por mes.`" @pointerleave="hover = null">
          <line v-for="t in scale.ticks" :key="t" class="grid-line" :x1="M.l" :x2="width - M.r" :y1="y(t)" :y2="y(t)" />
          <text v-for="t in scale.ticks" :key="`t${t}`" class="axis-text" :x="M.l - 8" :y="y(t) + 4" text-anchor="end">{{ fmtUf(t, 0) }}</text>
          <g v-for="(s, i) in stacks" :key="s.key" @pointermove="hover = i">
            <rect :x="M.l + slot * i" :y="M.t" :width="slot" :height="ih" fill="transparent" />
            <template v-for="(seg, j) in s.segs" :key="seg.canal">
              <rect
                :x="cx(i) - barW / 2"
                :y="y(s.segs.slice(0, j + 1).reduce((a, b) => a + b.v, 0))"
                :width="barW"
                :height="Math.max(0, (seg.v / scale.max) * ih)"
                :fill="seg.canal === '__otros' ? OTHER : colorOf(seg.canal)"
                :opacity="hover === null || hover === i ? 1 : 0.55"
              />
            </template>
            <text v-if="i % labelEvery === 0" class="axis-text" :x="cx(i)" :y="H - 8" text-anchor="middle">{{ monthKeyLabel(s.key) }}</text>
          </g>
        </svg>
        <div v-if="hover !== null && stacks[hover]" class="tip" :style="{ left: `${tipLeft}px` }">
          <b>{{ monthKeyLabel(stacks[hover].key, true) }}</b>
          <div v-for="seg in stacks[hover].segs" :key="seg.canal">
            <span><i :style="{ background: seg.canal === '__otros' ? OTHER : colorOf(seg.canal) }" />{{ seg.canal === '__otros' ? 'Otros' : label(seg.canal) }}</span><span>{{ fmtVal(seg.v) }}</span>
          </div>
          <div v-if="!stacks[hover].segs.length"><span class="muted">Sin datos</span></div>
          <div class="muted"><span>Total</span><span>{{ fmtVal(stacks[hover].total) }}</span></div>
        </div>
      </div>
    </template>
  </section>
</template>

<style scoped>
tr.sel td { background: var(--navy-3); }
tr.sel td:nth-child(2) { color: var(--green); }
.wcell { display: grid; gap: 3px; justify-items: end; }
.wcell .bar { width: 90px; height: 5px; }
</style>
