<script setup lang="ts">
const sb = useSupabase()
const team = useTeam()
const me = useMe()
const id = String(useRoute().params.id)

const lead = ref<Record<string, any> | null>(null)
const history = ref<any[]>([])
const activities = ref<any[]>([])
const saving = ref(false)
const msg = ref('')
const askLost = ref(false)
const act = reactive({ type: 'llamada', body: '' })

async function load() {
  const [l, h, a] = await Promise.all([
    sb.from('leads').select('*').eq('id', id).single(),
    sb.from('lead_stage_history').select('*').eq('lead_id', id).order('changed_at', { ascending: false }),
    sb.from('lead_activities').select('*').eq('lead_id', id).order('created_at', { ascending: false }),
  ])
  lead.value = l.data
  history.value = h.data ?? []
  activities.value = a.data ?? []
}
onMounted(load)

const digits = computed(() => phoneDigits(lead.value?.phone))
const userName = (uid: string | null) => team.value.find(m => m.user_id === uid)?.full_name ?? 'Sistema'

async function save(extra: Record<string, unknown> = {}) {
  if (!lead.value)
    return
  if (lead.value.stage === 'perdido' && !lead.value.lost_reason && !extra.lost_reason) {
    askLost.value = true
    return
  }
  saving.value = true
  const l = lead.value
  const { error } = await sb.from('leads').update({
    first_name: l.first_name, company: l.company, role_title: l.role_title,
    email: l.email, phone: l.phone, stage: l.stage, owner_id: l.owner_id,
    icp: l.icp || null, deal_value_uf: l.deal_value_uf || null,
    next_action_at: l.next_action_at || null, notes: l.notes,
    // Solo si la migración 007 ya agregó la columna (así el guardado no falla antes de aplicarla).
    ...('expected_close_at' in l ? { expected_close_at: l.expected_close_at || null } : {}),
    ...extra,
  }).eq('id', id)
  saving.value = false
  msg.value = error ? `Error: ${error.message}` : 'Guardado'
  setTimeout(() => (msg.value = ''), 2500)
  if (!error)
    load()
}

function confirmLost(reason: string, detail: string) {
  askLost.value = false
  save({ lost_reason: reason, lost_detail: detail || null })
}

async function addActivity() {
  if (!act.body.trim())
    return
  const { data: { user } } = await sb.auth.getUser()
  const { error } = await sb.from('lead_activities').insert({ lead_id: id, type: act.type, body: act.body.trim(), created_by: user?.id })
  if (!error) {
    act.body = ''
    load()
  }
}

const nextLocal = computed({
  get: () => lead.value?.next_action_at ? new Date(lead.value.next_action_at).toISOString().slice(0, 16) : '',
  set: (v: string) => { if (lead.value) lead.value.next_action_at = v ? new Date(v).toISOString() : null },
})
</script>

<template>
  <div v-if="lead" class="detail">
    <NuxtLink to="/" class="muted">← Pipeline</NuxtLink>
    <div class="head">
      <div>
        <p class="eyebrow">{{ CHANNELS[lead.channel] ?? lead.channel }}<template v-if="lead.utm_campaign"> · {{ lead.utm_campaign }}</template></p>
        <h1>{{ lead.company || 'Sin empresa' }}</h1>
        <p class="muted">{{ lead.first_name }} · {{ lead.role_title }} · entró el {{ fmtDate(lead.created_at) }}</p>
      </div>
      <div class="actions">
        <a v-if="digits" class="btn" :href="`tel:+${digits}`">Llamar</a>
        <a v-if="digits" class="btn ghost" :href="`https://wa.me/${digits}`" target="_blank">WhatsApp</a>
        <a v-if="lead.email" class="btn ghost" :href="`mailto:${lead.email}`">Correo</a>
      </div>
    </div>

    <div class="grid">
      <section class="card">
        <h2>Pipeline</h2>
        <label>Etapa
          <select v-model="lead.stage">
            <option v-for="s in STAGES" :key="s.key" :value="s.key">{{ s.label }}</option>
          </select>
        </label>
        <p v-if="lead.stage === 'perdido' && lead.lost_reason" class="muted">Motivo: {{ LOST_REASONS[lead.lost_reason] }}<template v-if="lead.lost_detail"> · {{ lead.lost_detail }}</template></p>
        <label>Responsable
          <select v-model="lead.owner_id">
            <option v-for="m in team" :key="m.id" :value="m.id">{{ m.full_name }}</option>
          </select>
        </label>
        <label>ICP
          <select v-model="lead.icp">
            <option :value="null">Sin definir</option>
            <option v-for="(label, key) in ICPS" :key="key" :value="key">{{ label }}</option>
          </select>
        </label>
        <label>Valor (UF / mes)<input v-model.number="lead.deal_value_uf" type="number" min="0" step="0.5"></label>
        <label>Próxima acción<input v-model="nextLocal" type="datetime-local"></label>
        <label v-if="'expected_close_at' in lead">Cierre estimado<input v-model="lead.expected_close_at" type="date"></label>
        <label>Notas<textarea v-model="lead.notes" rows="4" /></label>
        <div class="row">
          <span class="muted">{{ msg }}</span>
          <button class="btn" :disabled="saving" @click="save()">{{ saving ? 'Guardando…' : 'Guardar' }}</button>
        </div>
      </section>

      <section class="card">
        <h2>Contacto</h2>
        <label>Nombre<input v-model="lead.first_name"></label>
        <label>Empresa<input v-model="lead.company"></label>
        <label>Cargo<input v-model="lead.role_title"></label>
        <label>Correo<input v-model="lead.email" type="email"></label>
        <label>Teléfono<input v-model="lead.phone"></label>
        <p class="muted">Evalúa {{ lead.monthly_evaluations ?? '—' }} empresas al mes</p>
        <blockquote v-if="lead.message">{{ lead.message }}</blockquote>

        <h2>Origen</h2>
        <dl>
          <dt>Canal</dt><dd>{{ CHANNELS[lead.channel] ?? lead.channel }}</dd>
          <dt>Fuente / medio</dt><dd>{{ lead.utm_source || '—' }} / {{ lead.utm_medium || '—' }}</dd>
          <dt>Campaña</dt><dd>{{ lead.utm_campaign || '—' }}</dd>
          <dt>Formulario</dt><dd>{{ lead.source_form || '—' }}</dd>
          <dt>Landing</dt><dd>{{ lead.landing_page || '—' }}</dd>
          <dt>IDs de clic</dt><dd>{{ [lead.gclid && 'gclid', lead.fbclid && 'fbclid', lead.li_fat_id && 'li_fat_id'].filter(Boolean).join(' · ') || '—' }}</dd>
        </dl>
      </section>

      <section class="card">
        <h2>Actividad</h2>
        <form class="act" @submit.prevent="addActivity">
          <select v-model="act.type">
            <option v-for="(label, key) in ACTIVITY_TYPES" :key="key" :value="key">{{ label }}</option>
          </select>
          <textarea v-model="act.body" rows="2" placeholder="¿Qué pasó? Objeciones, acuerdos, próximos pasos…" />
          <button class="btn sm">Registrar</button>
        </form>
        <ul class="timeline">
          <li v-for="a in activities" :key="`a${a.id}`">
            <span class="tag">{{ ACTIVITY_TYPES[a.type] ?? a.type }}</span> {{ a.body }}
            <small class="muted">{{ userName(a.created_by) }} · {{ fmtDate(a.created_at) }}</small>
          </li>
        </ul>
        <h2>Historial de etapas</h2>
        <ul class="timeline">
          <li v-for="h in history" :key="`h${h.id}`">
            {{ STAGES.find(s => s.key === h.from_stage)?.label ?? 'Ingreso' }} → <strong>{{ STAGES.find(s => s.key === h.to_stage)?.label }}</strong>
            <small class="muted">{{ userName(h.changed_by) }} · {{ fmtDate(h.changed_at) }}</small>
          </li>
        </ul>
      </section>
    </div>
    <LostDialog v-if="askLost" @confirm="confirmLost" @cancel="askLost = false" />
    <p v-if="!me" class="err">Tu usuario no está en el equipo: no podrás guardar cambios.</p>
  </div>
  <p v-else class="muted pad">Cargando…</p>
</template>
