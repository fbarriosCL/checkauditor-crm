<script setup lang="ts">
// Fila ejecutiva de Revenue Intelligence: seis KPIs en UF/mes con sus filtros.
// Stock (pipeline) se mide a una fecha de corte; flujo (ganadas/perdidas) en el intervalo del período.
const filters = useRevFilters()
const drill = useDrill()
const kpis = ref<RevKpis | null>(null)
const loading = ref(true)
const error = ref('')
let seq = 0

async function load() {
  const mine = ++seq
  loading.value = true
  error.value = ''
  try {
    const r = await fetchRevKpis({ ...filters.value })
    if (mine === seq)
      kpis.value = r
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

const uf = (n: number | null | undefined) => (n == null ? '—' : n.toLocaleString('es-CL', { maximumFractionDigits: 1 }))
const pct = (n: number | null | undefined) => (n == null ? '—' : `${n.toLocaleString('es-CL', { maximumFractionDigits: 1 })}%`)

/** Variación porcentual; null si no hay base de comparación. */
function change(now: number | null | undefined, before: number | null | undefined) {
  if (now == null || !before)
    return null
  return Math.round(((now - before) / before) * 100)
}
function deltaText(c: number | null, label: string) {
  return c === null ? `Sin base de comparación (${label})` : `${c >= 0 ? '+' : ''}${c}% ${label}`
}
/** Clase de color: `upIsGood` indica si subir es bueno (ganadas) o malo (perdidas). */
function tone(c: number | null, upIsGood: boolean) {
  if (c === null || c === 0)
    return 'muted'
  return (c > 0) === upIsGood ? 'ok' : 'warn-text'
}

const cards = computed(() => {
  const k = kpis.value
  if (!k)
    return []
  const pipeC = change(k.pipeline.uf, k.pipeline.uf_inicio)
  const wonC = change(k.ganadas.uf, k.ganadas.uf_prev)
  const lostC = change(k.perdidas.uf, k.perdidas.uf_prev)
  // Hasta tres motivos principales, con su cantidad: «Precio (8) · Timing (5)»
  const reasonsText = k.perdidas.motivos.length
    ? `Motivos: ${k.perdidas.motivos.slice(0, 3).map(m => `${LOST_REASONS[m.motivo] ?? m.motivo} (${m.n})`).join(' · ')}`
    : 'Sin pérdidas en el período'
  const convDiff = k.conversion.por_cantidad !== null && k.conversion.prev_por_cantidad !== null
    ? Math.round((k.conversion.por_cantidad - k.conversion.prev_por_cantidad) * 10) / 10
    : null
  const ticketC = change(k.ticket.uf, k.ticket.uf_prev)
  return [
    {
      key: 'pipeline',
      drill: 'abiertas' as DrillKind,
      label: 'Pipeline activo',
      value: `${uf(k.pipeline.uf)} UF`,
      lines: [
        { text: `${k.pipeline.n} oportunidades abiertas${k.pipeline.sin_valor ? ` · ${k.pipeline.sin_valor} sin valor` : ''}`, cls: 'muted' },
        { text: deltaText(pipeC, 'vs. cierre anterior'), cls: tone(pipeC, true) },
      ],
    },
    {
      key: 'ganadas',
      drill: 'ganadas' as DrillKind,
      label: 'UF ganadas',
      value: `${uf(k.ganadas.uf)} UF`,
      lines: [
        { text: `${k.ganadas.n} ${k.ganadas.n === 1 ? 'cliente ganado' : 'clientes ganados'}`, cls: 'muted' },
        { text: deltaText(wonC, 'vs. período anterior'), cls: tone(wonC, true) },
      ],
    },
    {
      key: 'perdidas',
      drill: 'perdidas' as DrillKind,
      label: 'UF perdidas',
      value: `${uf(k.perdidas.uf)} UF`,
      lines: [
        { text: `${k.perdidas.n} ${k.perdidas.n === 1 ? 'oportunidad perdida' : 'oportunidades perdidas'}`, cls: 'muted' },
        { text: reasonsText, cls: 'muted' },
        { text: deltaText(lostC, 'vs. período anterior'), cls: tone(lostC, false) },
      ],
    },
    {
      key: 'ponderado',
      drill: null,
      label: 'Pipeline ponderado',
      value: `${uf(k.ponderado.uf)} UF`,
      lines: [
        { text: 'UF × probabilidad de su etapa', cls: 'muted' },
        { text: 'Probabilidades configurables, no calibradas', cls: 'muted' },
      ],
    },
    {
      key: 'conversion',
      drill: null,
      label: 'Conversión comercial',
      value: pct(k.conversion.por_cantidad),
      lines: [
        { text: `Por valor: ${pct(k.conversion.por_valor)} · Histórica: ${pct(k.conversion.historica)}`, cls: 'muted' },
        {
          text: convDiff === null ? 'Sin cierres en uno de los períodos' : `${convDiff >= 0 ? '+' : ''}${convDiff} pp vs. período anterior`,
          cls: tone(convDiff, true),
        },
      ],
    },
    {
      key: 'ticket',
      drill: null,
      label: 'Ticket promedio',
      value: k.ticket.uf == null ? '—' : `${uf(k.ticket.uf)} UF`,
      lines: [
        { text: 'UF/mes por oportunidad ganada', cls: 'muted' },
        { text: deltaText(ticketC, 'vs. período anterior'), cls: tone(ticketC, true) },
      ],
    },
  ]
})

const DRILL_TITLE: Record<string, string> = {
  abiertas: 'Pipeline activo: oportunidades abiertas',
  ganadas: 'UF ganadas: clientes del período',
  perdidas: 'UF perdidas: oportunidades del período',
}
function openDrill(kind: DrillKind) {
  if (kpis.value)
    drill.value = { kind, from: kpis.value.desde, to: kpis.value.hasta, title: DRILL_TITLE[kind] }
}
</script>

<template>
  <section class="rev">
    <p v-if="error" class="err">No pudimos calcular los indicadores: {{ error }}. ¿Ya ejecutaste las migraciones 007 a 010 en Supabase?</p>
    <div v-else class="kpis six" :aria-busy="loading">
      <component
        :is="c.drill ? 'button' : 'div'"
        v-for="c in cards"
        :key="c.key"
        class="card kpi"
        :class="{ click: c.drill }"
        :type="c.drill ? 'button' : undefined"
        :title="c.drill ? 'Ver las oportunidades de este indicador' : undefined"
        @click="c.drill && openDrill(c.drill)"
      >
        <span class="muted">{{ c.label }}</span>
        <strong>{{ c.value }}</strong>
        <small v-for="(l, i) in c.lines" :key="i" :class="l.cls">{{ l.text }}</small>
      </component>
      <div v-if="loading && !cards.length" class="card muted" style="grid-column: 1 / -1">Calculando…</div>
    </div>

    <small v-if="kpis?.sin_fecha.n" class="muted note">
      {{ kpis.sin_fecha.n }} {{ kpis.sin_fecha.n === 1 ? 'cierre importado no tiene' : 'cierres importados no tienen' }} fecha
      ({{ uf(kpis.sin_fecha.uf) }} UF): no se asignan a ningún mes ni al pipeline.
    </small>
  </section>
</template>

<style scoped>
.rev { display: grid; gap: 10px; }
.note { display: block; }
.warn-text { color: var(--amber); }
</style>
