export const STAGES = [
  { key: 'nuevo', label: 'Nuevo' },
  { key: 'contactado', label: 'Contactado' },
  { key: 'calificado', label: 'Calificado' },
  { key: 'demo_agendada', label: 'Demo agendada' },
  { key: 'demo_hecha', label: 'Demo hecha' },
  { key: 'propuesta', label: 'Propuesta' },
  { key: 'negociacion', label: 'Negociación' },
  { key: 'ganado', label: 'Ganado' },
  { key: 'perdido', label: 'Perdido' },
] as const

export const CHANNELS: Record<string, string> = {
  google_ads: 'Google Ads',
  meta_ads: 'Meta Ads',
  linkedin_ads: 'LinkedIn Ads',
  pago_otro: 'Pago (otro)',
  email: 'Email',
  rrss: 'Redes sociales',
  organico: 'Orgánico',
  ia: 'IA (ChatGPT, etc.)',
  referido: 'Referido',
  directo: 'Directo',
  otro: 'Otro',
  desconocido: 'Desconocido',
}

export const LOST_REASONS: Record<string, string> = {
  precio: 'Precio',
  timing: 'No es el momento',
  competencia: 'Eligió a la competencia',
  sin_respuesta: 'Sin respuesta',
  sin_necesidad: 'Sin necesidad',
  sin_presupuesto: 'Sin presupuesto',
  no_califica: 'No califica',
  otro: 'Otro',
}

export const ICPS: Record<string, string> = {
  fin_credito: 'Finanzas · crédito',
  fin_continuidad: 'Finanzas · continuidad',
  compras: 'Compras / proveedores',
  compl_21595: 'Compliance · Ley 21.595',
  compl_monitoreo: 'Compliance · monitoreo',
  uaf: 'Sujeto obligado UAF',
  pyme: 'Dueño de empresa / pyme',
}

export const ACTIVITY_TYPES: Record<string, string> = {
  llamada: 'Llamada',
  whatsapp: 'WhatsApp',
  email: 'Correo',
  reunion: 'Reunión',
  nota: 'Nota',
}

/** Teléfono chileno a dígitos internacionales (56XXXXXXXXX) o null. */
export function phoneDigits(phone?: string | null): string | null {
  let d = (phone ?? '').replace(/\D/g, '')
  if (d.length === 9)
    d = `56${d}`
  return d.length >= 11 ? d : null
}

export function daysSince(iso: string): number {
  return Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 86_400_000))
}

export function fmtDate(iso?: string | null): string {
  if (!iso)
    return '—'
  return new Date(iso).toLocaleString('es-CL', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' })
}
