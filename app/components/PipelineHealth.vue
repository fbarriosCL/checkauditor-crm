<script setup lang="ts">
// Salud del pipeline: foto de HOY de las oportunidades abiertas (stock). Respeta responsable y canal, no el período.
// El riesgo de pérdida son reglas transparentes y configurables (tabla health_config), sin IA.
const filters = useRevFilters()
const drill = useDrill()
const team = useTeam()

const h = ref<RevHealth | null>(null)
const loading = ref(true)
const error = ref('')
let seq = 0

async function load() {
  const mine = ++seq
  loading.value = true
  error.value = ''
  try {
    const r = await fetchRevHealth(filters.value)
    if (mine === seq)
      h.value = r
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

const uf = (n: number | null | undefined) => fmtUf(n, 1)
const owner = (id: string | null) => (id ? (team.value.find(m => m.id === id)?.full_name ?? 'Responsable inactivo') : 'Sin responsable')
const stageLabel = (k: string) => STAGES.find(s => s.key === k)?.label ?? k

const RULES: { key: RiskRule, label: string }[] = [
  { key: 'inactividad', label: 'Sin actividad ni cambio de etapa' },
  { key: 'fecha_vencida', label: 'Fecha estimada de cierre vencida' },
  { key: 'postergaciones', label: 'Fecha de cierre pospuesta varias veces' },
  { key: 'exceso_etapa', label: 'Demasiado tiempo en la etapa' },
]
const RULE_TAG: Record<string, string> = { inactividad: 'Sin actividad', fecha_vencida: 'Fecha vencida', postergaciones: 'Pospuesta', exceso_etapa: 'Mucho en la etapa' }

const cfg = computed(() => h.value?.config ?? {})
const ruleHint = (k: RiskRule) => {
  const c = cfg.value
  if (k === 'inactividad')
    return `> ${c.riesgo_dias_sin_actividad ?? 14} días`
  if (k === 'postergaciones')
    return `≥ ${c.riesgo_postergaciones ?? 2} veces`
  if (k === 'exceso_etapa')
    return `> ${c.riesgo_factor_etapa ?? 2}× el promedio histórico`
  return ''
}

const maxEst = computed(() => Math.max(1, ...(h.value?.estancadas.map(e => e.uf) ?? [])))
const maxAge = computed(() => Math.max(1, ...(h.value?.antiguedad.map(e => e.uf) ?? [])))
const est7 = computed(() => h.value?.estancadas.find(e => e.dias === 7))
const AGE_LABEL: Record<string, string> = { '0-7': '0–7 días', '8-15': '8–15 días', '16-30': '16–30 días', '31-60': '31–60 días', '60+': 'Más de 60 días' }

function open(kind: DrillKind, title: string, days?: number) {
  const now = new Date().toISOString()
  drill.value = { kind, from: now, to: now, title, days }
}
</script>

<template>
  <section class="health">
    <p v-if="error" class="err">No pudimos calcular la salud del pipeline: {{ error }}. ¿Ya ejecutaste la migración 013?</p>
    <template v-if="h">
      <div class="kpis three">
        <button class="card kpi click" type="button" @click="open('estancadas', 'Oportunidades sin seguimiento (más de 7 días)', 7)">
          <span class="muted">UF sin seguimiento (&gt; 7 días)</span>
          <strong :class="{ amber: est7?.n }">{{ uf(est7?.uf) }} UF</strong>
          <small class="muted">{{ est7?.n ?? 0 }} de {{ h.abiertas.n }} oportunidades abiertas</small>
        </button>
        <button class="card kpi click" type="button" @click="open('vencidas', 'Oportunidades con la próxima acción vencida')">
          <span class="muted">Acciones vencidas</span>
          <strong :class="{ amber: h.vencidas.n }">{{ h.vencidas.n }}</strong>
          <small class="muted">{{ uf(h.vencidas.uf) }} UF en riesgo</small>
        </button>
        <button class="card kpi click" type="button" @click="open('riesgo', 'Oportunidades con riesgo de pérdida')">
          <span class="muted">Con riesgo de pérdida</span>
          <strong :class="{ amber: h.riesgo.n }">{{ h.riesgo.n }}</strong>
          <small class="muted">{{ uf(h.riesgo.uf) }} UF · al menos una señal</small>
        </button>
      </div>

      <div class="two">
        <section class="card chart">
          <h2>Oportunidades estancadas</h2>
          <small class="muted">Sin actividad ni cambio de etapa. Es acumulado: una oportunidad de 20 días sin movimiento cuenta en &gt;3, &gt;7 y &gt;14.</small>
          <table class="tbl num">
            <thead><tr><th>Sin movimiento</th><th>Oportunidades</th><th>UF/mes</th></tr></thead>
            <tbody>
              <template v-for="e in h.estancadas" :key="e.dias">
                <tr class="click" tabindex="0" @click="e.n && open('estancadas', `Oportunidades sin seguimiento (más de ${e.dias} días)`, e.dias)" @keydown.enter="e.n && open('estancadas', `Oportunidades sin seguimiento (más de ${e.dias} días)`, e.dias)">
                  <td>Más de {{ e.dias }} días</td><td>{{ e.n }}</td><td>{{ uf(e.uf) }}</td>
                </tr>
                <tr class="barrow"><td colspan="3"><div class="bar"><i class="warn" :style="{ width: `${(e.uf / maxEst) * 100}%` }" /></div></td></tr>
              </template>
            </tbody>
          </table>
        </section>

        <section class="card chart">
          <h2>Acciones vencidas</h2>
          <small class="muted">Oportunidades abiertas cuya próxima acción ya pasó.</small>
          <p v-if="!h.vencidas.n" class="muted" style="margin-top: 10px">Ninguna acción vencida. Buen trabajo de seguimiento.</p>
          <template v-else>
            <table class="tbl num l1">
              <thead><tr><th>Responsable</th><th>Oportunidades</th><th>UF en riesgo</th><th>Máx. atraso</th></tr></thead>
              <tbody>
                <tr v-for="r in h.vencidas.por_responsable" :key="r.owner_id ?? 'none'">
                  <td>{{ owner(r.owner_id) }}</td><td>{{ r.n }}</td><td>{{ uf(r.uf) }}</td><td class="warn-text">{{ r.dias_max }} d</td>
                </tr>
              </tbody>
            </table>
            <h2 style="margin-top: 12px; font-size: 14px">Más atrasadas</h2>
            <table class="tbl left">
              <tbody>
                <tr v-for="t in h.vencidas.top" :key="t.id">
                  <td><NuxtLink :to="`/lead/${t.id}`">{{ t.empresa || t.nombre || 'Sin nombre' }}</NuxtLink></td>
                  <td>{{ stageLabel(t.etapa) }}</td><td>{{ owner(t.owner_id) }}</td>
                  <td class="r">{{ t.uf ? `${uf(t.uf)} UF` : 'sin valor' }}</td><td class="r warn-text">{{ t.dias }} d</td>
                </tr>
              </tbody>
            </table>
          </template>
        </section>
      </div>

      <div class="two">
        <section class="card chart">
          <h2>Antigüedad del pipeline</h2>
          <small class="muted">Oportunidades abiertas según el tiempo desde su creación.</small>
          <table class="tbl num">
            <thead><tr><th>Antigüedad</th><th>Oportunidades</th><th>UF/mes</th></tr></thead>
            <tbody>
              <template v-for="a in h.antiguedad" :key="a.rango">
                <tr><td>{{ AGE_LABEL[a.rango] ?? a.rango }}</td><td>{{ a.n }}</td><td>{{ uf(a.uf) }}</td></tr>
                <tr class="barrow"><td colspan="3"><div class="bar"><i :class="{ warn: a.rango === '60+' }" :style="{ width: `${(a.uf / maxAge) * 100}%` }" /></div></td></tr>
              </template>
            </tbody>
          </table>
        </section>

        <section class="card chart">
          <h2>Riesgo de pérdida</h2>
          <small class="muted">Reglas simples y visibles (sin IA). Una oportunidad suma una señal por cada regla que cumple.</small>
          <table class="tbl num l1">
            <thead><tr><th>Señal</th><th>Umbral</th><th>Oportunidades</th><th>UF/mes</th></tr></thead>
            <tbody>
              <tr v-for="r in RULES" :key="r.key">
                <td>{{ r.label }}</td><td class="muted">{{ ruleHint(r.key) }}</td><td>{{ h.riesgo.reglas[r.key].n }}</td><td>{{ uf(h.riesgo.reglas[r.key].uf) }}</td>
              </tr>
            </tbody>
          </table>
          <p v-if="!h.riesgo.top.length" class="muted">Ninguna oportunidad abierta cumple alguna señal de riesgo.</p>
          <table v-else class="tbl left">
            <tbody>
              <tr v-for="t in h.riesgo.top" :key="t.id">
                <td><NuxtLink :to="`/lead/${t.id}`">{{ t.empresa || t.nombre || 'Sin nombre' }}</NuxtLink><br><small class="muted">{{ owner(t.owner_id) }} · {{ stageLabel(t.etapa) }}</small></td>
                <td class="r">{{ t.uf ? `${uf(t.uf)} UF` : 'sin valor' }}</td>
                <td><span v-for="m in t.motivos" :key="m" class="tag" style="margin: 0 4px 4px 0; display: inline-block">{{ RULE_TAG[m] ?? m }}</span></td>
              </tr>
            </tbody>
          </table>
          <small class="muted">Los umbrales se editan en la tabla <code>health_config</code>. «Demasiado tiempo en la etapa» solo se aplica si hay al menos {{ cfg.riesgo_min_muestras_etapa ?? 5 }} estadías terminadas de esa etapa.</small>
        </section>
      </div>
    </template>
    <p v-else-if="loading" class="muted">Calculando…</p>
  </section>
</template>

<style scoped>
.health { display: grid; gap: 16px; min-width: 0; }
.kpis.three { grid-template-columns: repeat(3, minmax(0, 1fr)); }
.amber { color: var(--amber); }
.warn-text { color: var(--amber); }
tr.barrow td { border-top: 0; padding-top: 0; padding-bottom: 8px; text-align: left !important; }
td.r { text-align: right !important; }
.tbl.l1 th:nth-child(1), .tbl.l1 td:nth-child(1) { text-align: left; }
.tbl.l1.num th:nth-child(2), .tbl.l1.num td:nth-child(2) { text-align: right; }
@media (max-width: 900px) { .kpis.three { grid-template-columns: 1fr; } }
</style>
