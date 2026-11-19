<script setup lang="ts">
interface LeadCard {
  id: string
  first_name: string | null
  company: string | null
  role_title: string | null
  channel: string
  utm_campaign: string | null
  stage: string
  stage_changed_at: string
  owner_id: string | null
  deal_value_uf: number | null
}

const sb = useSupabase()
const team = useTeam()
const leads = ref<LeadCard[]>([])
const loading = ref(true)
const q = ref('')
const fChannel = ref('')
const fOwner = ref('')
const dragging = ref<string | null>(null)
const over = ref<string | null>(null)
const pendingLost = ref<{ id: string } | null>(null)
const error = ref('')

async function load() {
  const { data, error: e } = await sb.from('leads')
    .select('id, first_name, company, role_title, channel, utm_campaign, stage, stage_changed_at, owner_id, deal_value_uf')
    .order('created_at', { ascending: false })
  if (e)
    error.value = e.message
  leads.value = data ?? []
  loading.value = false
}

const filtered = computed(() => {
  const term = q.value.trim().toLowerCase()
  return leads.value.filter(l =>
    (!fChannel.value || l.channel === fChannel.value)
    && (!fOwner.value || l.owner_id === fOwner.value)
    && (!term || `${l.first_name} ${l.company} ${l.role_title}`.toLowerCase().includes(term)))
})

const columns = computed(() => STAGES.map(s => ({
  ...s,
  items: filtered.value.filter(l => l.stage === s.key),
  uf: filtered.value.filter(l => l.stage === s.key).reduce((a, l) => a + (l.deal_value_uf ?? 0), 0),
})))

const ownerName = (id: string | null) => team.value.find(m => m.id === id)?.full_name.split(' ')[0] ?? '—'

async function move(id: string, stage: string, lost?: { reason: string, detail: string }) {
  const lead = leads.value.find(l => l.id === id)
  if (!lead || lead.stage === stage)
    return
  const prev = { stage: lead.stage, at: lead.stage_changed_at }
  lead.stage = stage
  lead.stage_changed_at = new Date().toISOString()
  const patch: Record<string, unknown> = { stage }
  if (lost) {
    patch.lost_reason = lost.reason
    patch.lost_detail = lost.detail || null
  }
  const { error: e } = await sb.from('leads').update(patch).eq('id', id)
  if (e) {
    lead.stage = prev.stage
    lead.stage_changed_at = prev.at
    error.value = `No se pudo mover: ${e.message}`
  }
}

function onDrop(stage: string) {
  const id = dragging.value
  over.value = null
  dragging.value = null
  if (!id)
    return
  if (stage === 'perdido')
    pendingLost.value = { id }
  else
    move(id, stage)
}

function confirmLost(reason: string, detail: string) {
  if (pendingLost.value)
    move(pendingLost.value.id, 'perdido', { reason, detail })
  pendingLost.value = null
}

let channel: ReturnType<typeof sb.channel> | null = null
onMounted(() => {
  load()
  // Tiempo real: un lead nuevo aparece sin recargar.
  channel = sb.channel('leads-board')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'leads' }, () => load())
    .subscribe()
})
onUnmounted(() => { if (channel) sb.removeChannel(channel) })
</script>

<template>
  <div class="board-page">
    <div class="toolbar">
      <input v-model="q" type="search" placeholder="Buscar empresa, contacto o cargo">
      <select v-model="fChannel">
        <option value="">Todos los canales</option>
        <option v-for="(label, key) in CHANNELS" :key="key" :value="key">{{ label }}</option>
      </select>
      <select v-model="fOwner">
        <option value="">Todos los responsables</option>
        <option v-for="m in team" :key="m.id" :value="m.id">{{ m.full_name }}</option>
      </select>
      <span class="muted">{{ filtered.length }} leads</span>
    </div>
    <p v-if="error" class="err">{{ error }}</p>
    <p v-if="loading" class="muted">Cargando…</p>

    <div class="board">
      <section
        v-for="col in columns" :key="col.key"
        class="col" :class="[col.key, { over: over === col.key }]"
        @dragover.prevent="over = col.key"
        @dragleave="over = over === col.key ? null : over"
        @drop.prevent="onDrop(col.key)"
      >
        <header>
          <strong>{{ col.label }}</strong>
          <span class="count">{{ col.items.length }}</span>
          <span v-if="col.uf" class="uf">{{ col.uf.toLocaleString('es-CL') }} UF</span>
        </header>
        <NuxtLink
          v-for="l in col.items" :key="l.id" :to="`/lead/${l.id}`"
          class="lead" draggable="true"
          @dragstart="dragging = l.id" @dragend="dragging = null; over = null"
        >
          <strong>{{ l.company || 'Sin empresa' }}</strong>
          <span>{{ l.first_name || 'Sin nombre' }}<template v-if="l.role_title"> · {{ l.role_title }}</template></span>
          <footer>
            <span class="tag">{{ CHANNELS[l.channel] ?? l.channel }}</span>
            <span class="muted">{{ daysSince(l.stage_changed_at) }} d · {{ ownerName(l.owner_id) }}</span>
          </footer>
        </NuxtLink>
      </section>
    </div>

    <LostDialog v-if="pendingLost" @confirm="confirmLost" @cancel="pendingLost = null" />
  </div>
</template>
