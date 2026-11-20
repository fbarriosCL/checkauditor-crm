<script setup lang="ts">
// Dashboard de canales: de dónde vienen los leads, dónde se caen y qué canal trae clientes.
// Todo se calcula en el navegador con los datos que ya están en Supabase (RLS: solo el equipo).
const sb = useSupabase()
const team = useTeam()

const PERIODS = [
  { days: 30, label: 'Últimos 30 días' },
  { days: 90, label: 'Últimos 90 días' },
  { days: 365, label: 'Último año' },
]
const days = ref(90)
const loading = ref(true)
const error = ref('')
const leads = ref<any[]>([])
const history = ref<any[]>([])
const activities = ref<any[]>([])

// Embudo: cada lead cuenta en todas las etapas que alcanzó alguna vez.
const FUNNEL = [
  { key: 'nuevo', label: 'Nuevo' },
  { key: 'contactado', label: 'Contactado' },
  { key: 'demo_agendada', label: 'Demo' },
  { key: 'propuesta', label: 'Propuesta' },
  { key: 'ganado', label: 'Ganado' },
]
const ORDER: string[] = STAGES.map(s => s.key).filter(k => k !== 'perdido')
const OPEN_STALE_DAYS = 3

async function load() {
  loading.value = true
  error.value = ''
  // Se trae el doble del período para comparar contra el período anterior.
  const since = new Date(Date.now() - 2 * days.value * 86_400_000).toISOString()
  const l = await sb.from('leads')
    .select('id, created_at, channel, stage, owner_id, lost_reason, deal_value_uf, first_contact_at, won_at, stage_changed_at')
    .gte('created_at', since)
  if (l.error) {
    error.value = l.error.message
    loading.value = false
    return
  }
  leads.value = l.data ?? []
  const ids = leads.value.map(x => x.id)
  if (ids.length) {
    const [h, a] = await Promise.all([
      sb.from('lead_stage_history').select('lead_id, to_stage').in('lead_id', ids),
      sb.from('lead_activities').select('lead_id, created_at').in('lead_id', ids),
    ])
    history.value = h.data ?? []
    activities.value = a.data ?? []
  }
  else {
    history.value = []
    activities.value = []
  }
  loading.value = false
}
onMounted(load)
watch(days, load)

const cutoff = computed(() => Date.now() - days.value * 86_400_000)
const current = computed(() => leads.value.filter(x => new Date(x.created_at).getTime() >= cutoff.value))
const previous = computed(() => leads.value.filter(x => new Date(x.created_at).getTime() < cutoff.value))

/** Etapa más avanzada que alcanzó cada lead (perdido no cuenta como avance). */
const reached = computed(() => {
  const best = new Map<string, number>()
  const bump = (id: string, stage: string) => {
    const i = ORDER.indexOf(stage)
    if (i > (best.get(id) ?? -1))
      best.set(id, i)
  }
  for (const h of history.value) bump(h.lead_id, h.to_stage)
  for (const x of leads.value) bump(x.id, x.stage)
  return best
})
const reachedIdx = (id: string) => reached.value.get(id) ?? 0

const won = computed(() => current.value.filter(x => x.stage === 'ganado'))
const demos = computed(() => current.value.filter(x => reachedIdx(x.id) >= ORDER.indexOf('demo_agendada')))
const wonUf = computed(() => won.value.reduce((s, x) => s + (Number(x.deal_value_uf) || 0), 0))

const delta = computed(() => {
  const p = previous.value.length
  if (!p)
    return null
  return Math.round(((current.value.length - p) / p) * 100)
})

const medianHours = computed(() => {
  const hrs = current.value
    .filter(x => x.first_contact_at)
    .map(x => (new Date(x.first_contact_at).getTime() - new Date(x.created_at).getTime()) / 3_600_000)
    .sort((a, b) => a - b)
  if (!hrs.length)
    return null
  const m = Math.floor(hrs.length / 2)
  return hrs.length % 2 ? hrs[m] : (hrs[m - 1] + hrs[m]) / 2
})

const byChannel = computed(() => {
  const rows = new Map<string, { key: string, leads: number, demos: number, won: number, uf: number }>()
  for (const x of current.value) {
    const r = rows.get(x.channel) ?? { key: x.channel, leads: 0, demos: 0, won: 0, uf: 0 }
    r.leads++
    if (reachedIdx(x.id) >= ORDER.indexOf('demo_agendada'))
      r.demos++
    if (x.stage === 'ganado') {
      r.won++
      r.uf += Number(x.deal_value_uf) || 0
    }
    rows.set(x.channel, r)
  }
  const list = [...rows.values()].sort((a, b) => b.leads - a.leads)
  const max = Math.max(1, ...list.map(r => r.leads))
  // El canal con mejor conversión a cliente (si hay ganados) va en verde.
  const best = list.filter(r => r.won).sort((a, b) => b.won / b.leads - a.won / a.leads)[0]?.key
  return list.map(r => ({ ...r, pct: (r.leads / max) * 100, best: r.key === best }))
})

const funnel = computed(() => {
  const n = current.value.length
  const steps = FUNNEL.map((f) => {
    const idx = ORDER.indexOf(f.key)
    return { ...f, count: current.value.filter(x => reachedIdx(x.id) >= idx).length }
  })
  // La caída más grande entre etapas consecutivas se marca en ámbar.
  let worst = -1
  let worstRate = 1
  steps.forEach((s, i) => {
    if (i === 0 || !steps[i - 1].count)
      return
    const rate = s.count / steps[i - 1].count
    if (rate < worstRate) {
      worstRate = rate
      worst = i
    }
  })
  return steps.map((s, i) => ({
    ...s,
    width: n ? Math.max(2, (s.count / n) * 100) : 0,
    rate: i && steps[i - 1].count ? Math.round((s.count / steps[i - 1].count) * 100) : null,
    worst: i === worst,
  }))
})

const lostReasons = computed(() => {
  const c = new Map<string, number>()
  for (const x of current.value.filter(y => y.stage === 'perdido'))
    c.set(x.lost_reason ?? 'otro', (c.get(x.lost_reason ?? 'otro') ?? 0) + 1)
  return [...c.entries()].sort((a, b) => b[1] - a[1]).map(([k, v]) => ({ label: LOST_REASONS[k] ?? k, count: v }))
})

const byOwner = computed(() => {
  const lastTouch = new Map<string, number>()
  for (const a of activities.value) {
    const t = new Date(a.created_at).getTime()
    if (t > (lastTouch.get(a.lead_id) ?? 0))
      lastTouch.set(a.lead_id, t)
  }
  const staleBefore = Date.now() - OPEN_STALE_DAYS * 86_400_000
  return team.value.map((m) => {
    const open = leads.value.filter(x => x.owner_id === m.id && !['ganado', 'perdido'].includes(x.stage))
    const stale = open.filter(x => Math.max(new Date(x.stage_changed_at).getTime(), lastTouch.get(x.id) ?? 0) < staleBefore)
    return { name: m.full_name, open: open.length, stale: stale.length }
  }).filter(r => r.open)
})

const fmt1 = (n: number) => n.toLocaleString('es-CL', { maximumFractionDigits: 1 })
const pctOf = (a: number, b: number) => (b ? `${Math.round((a / b) * 100)}%` : '—')
</script>

<template>
  <div class="dash">
    <div class="dash-head">
      <div>
        <p class="eyebrow">Growth</p>
        <h1>Dashboard de canales</h1>
      </div>
      <select v-model.number="days" aria-label="Período">
        <option v-for="p in PERIODS" :key="p.days" :value="p.days">{{ p.label }}</option>
      </select>
    </div>

    <p v-if="error" class="err">No pudimos cargar los datos: {{ error }}</p>
    <p v-else-if="loading" class="muted">Cargando…</p>
    <p v-else-if="!current.length" class="card muted">Todavía no hay leads en este período. Cuando entren, aquí verás de qué canal vienen y cuántos llegan a cliente.</p>

    <template v-else>
      <div class="kpis">
        <div class="card kpi">
          <span class="muted">Leads</span><strong>{{ current.length }}</strong>
          <small v-if="delta !== null" :class="delta >= 0 ? 'ok' : 'muted'">{{ delta >= 0 ? '+' : '' }}{{ delta }}% vs. período anterior</small>
          <small v-else class="muted">Sin período anterior</small>
        </div>
        <div class="card kpi">
          <span class="muted">Demos</span><strong>{{ demos.length }}</strong>
          <small class="muted">{{ pctOf(demos.length, current.length) }} de los leads</small>
        </div>
        <div class="card kpi">
          <span class="muted">Ganados</span><strong>{{ won.length }}</strong>
          <small class="muted">{{ fmt1(wonUf) }} UF / mes</small>
        </div>
        <div class="card kpi">
          <span class="muted">Primera respuesta</span><strong>{{ medianHours === null ? '—' : `${fmt1(medianHours)} h` }}</strong>
          <small class="muted">mediana</small>
        </div>
      </div>

      <div class="two">
        <section class="card">
          <h2>Por canal: leads y ganados</h2>
          <table class="tbl">
            <thead><tr><th>Canal</th><th /><th>Leads</th><th>Demos</th><th>Ganados</th><th>UF</th></tr></thead>
            <tbody>
              <tr v-for="r in byChannel" :key="r.key">
                <td>{{ CHANNELS[r.key] ?? r.key }}</td>
                <td class="barcell"><div class="bar"><i :class="{ best: r.best }" :style="{ width: `${r.pct}%` }" /></div></td>
                <td>{{ r.leads }}</td>
                <td>{{ r.demos }}</td>
                <td :class="{ ok: r.best }">{{ r.won }}</td>
                <td>{{ r.uf ? fmt1(r.uf) : '—' }}</td>
              </tr>
            </tbody>
          </table>
          <small class="muted">Verde: el canal que más convierte a cliente.</small>
        </section>

        <section class="card">
          <h2>Embudo</h2>
          <div v-for="s in funnel" :key="s.key" class="step">
            <div class="step-row"><span>{{ s.label }}</span><span>{{ s.count }}<template v-if="s.rate !== null"> · {{ s.rate }}%</template></span></div>
            <div class="bar"><i :class="{ warn: s.worst, best: s.key === 'ganado' }" :style="{ width: `${s.width}%` }" /></div>
          </div>
          <small class="muted">El % es la conversión desde la etapa anterior. Ámbar: donde más se pierde.</small>
        </section>
      </div>

      <div class="two">
        <section class="card">
          <h2>Motivos de pérdida</h2>
          <dl v-if="lostReasons.length">
            <template v-for="r in lostReasons" :key="r.label"><dt>{{ r.label }}</dt><dd>{{ r.count }}</dd></template>
          </dl>
          <p v-else class="muted">Ningún lead perdido en este período.</p>
        </section>

        <section class="card">
          <h2>Por responsable</h2>
          <table v-if="byOwner.length" class="tbl">
            <thead><tr><th>Nombre</th><th>Abiertos</th><th>Sin acción</th></tr></thead>
            <tbody>
              <tr v-for="r in byOwner" :key="r.name">
                <td>{{ r.name }}</td><td>{{ r.open }}</td><td :class="{ warn: r.stale }">{{ r.stale }}</td>
              </tr>
            </tbody>
          </table>
          <p v-else class="muted">Nadie tiene leads abiertos.</p>
          <small class="muted">Sin acción: más de {{ OPEN_STALE_DAYS }} días sin cambio de etapa ni actividad.</small>
        </section>
      </div>
    </template>
  </div>
</template>
