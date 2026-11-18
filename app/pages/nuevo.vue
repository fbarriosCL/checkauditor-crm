<script setup lang="ts">
// Lead manual: referidos, correos entrantes, eventos. Queda a nombre de Tomas salvo que elijas otro.
const sb = useSupabase()
const team = useTeam()
const f = reactive({
  first_name: '', company: '', role_title: '', email: '', phone: '',
  channel: 'referido', icp: '', owner_id: '', notes: '',
})
const error = ref('')

async function create() {
  const { data, error: e } = await sb.from('leads').insert({
    ...f,
    email: f.email.trim().toLowerCase() || null,
    icp: f.icp || null,
    owner_id: f.owner_id || null,
    source_form: 'manual',
  }).select('id').single()
  if (e) {
    error.value = e.message
    return
  }
  navigateTo(`/lead/${data.id}`)
}
</script>

<template>
  <form class="card narrow" @submit.prevent="create">
    <h1>Nuevo lead</h1>
    <label>Empresa<input v-model="f.company" required></label>
    <label>Nombre<input v-model="f.first_name" required></label>
    <label>Cargo<input v-model="f.role_title"></label>
    <label>Correo<input v-model="f.email" type="email"></label>
    <label>Teléfono<input v-model="f.phone" placeholder="+56 9 1234 5678"></label>
    <label>Canal
      <select v-model="f.channel">
        <option v-for="(label, key) in CHANNELS" :key="key" :value="key">{{ label }}</option>
      </select>
    </label>
    <label>ICP
      <select v-model="f.icp">
        <option value="">Sin definir</option>
        <option v-for="(label, key) in ICPS" :key="key" :value="key">{{ label }}</option>
      </select>
    </label>
    <label>Responsable
      <select v-model="f.owner_id">
        <option value="">Por defecto (Tomas)</option>
        <option v-for="m in team" :key="m.id" :value="m.id">{{ m.full_name }}</option>
      </select>
    </label>
    <label>Notas<textarea v-model="f.notes" rows="3" placeholder="¿Quién lo refirió? ¿Qué necesita?" /></label>
    <p v-if="error" class="err">{{ error }}</p>
    <button class="btn">Crear lead</button>
  </form>
</template>
