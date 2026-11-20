// Acceso a las funciones de Revenue Intelligence (supabase/009_rev_kpis.sql).
// Los cálculos viven en Postgres; aquí solo se pide el resultado ya agregado y se cachea unos segundos
// para que cambiar de pestaña o volver a un filtro anterior no repita la consulta.

export interface RevFilters {
  days: number
  owner: string // '' = todos
  channel: string // '' = todos
}

export interface RevKpis {
  desde: string
  hasta: string
  pipeline: { uf: number, n: number, sin_valor: number, uf_inicio: number, n_inicio: number }
  ponderado: { uf: number, uf_inicio: number }
  ganadas: { uf: number, n: number, uf_prev: number, n_prev: number }
  perdidas: {
    uf: number
    n: number
    uf_prev: number
    n_prev: number
    motivos: { motivo: string, n: number, uf: number }[]
  }
  conversion: {
    por_cantidad: number | null
    por_valor: number | null
    prev_por_cantidad: number | null
    prev_por_valor: number | null
    historica: number | null
    cierres: number
  }
  ticket: { uf: number | null, uf_prev: number | null, n_con_valor: number }
  sin_fecha: { n: number, uf: number }
}

/** Filtros globales del dashboard comercial (compartidos por KPIs, gráficos y tablas). days = 0 → histórico completo. */
export const useRevFilters = () => useState<RevFilters>('revFilters', () => ({ days: 90, owner: '', channel: '' }))

export interface RevBucket {
  inicio: string
  fin: string
  desde: string
  hasta: string
  en_curso: boolean
  ing_uf: number
  ing_n: number
  gan_uf: number
  gan_n: number
  gan_vn: number
  per_uf: number
  per_n: number
  pip_uf: number
  pip_n: number
  pond_uf: number
}

export type RevGran = 'day' | 'week' | 'month' | 'quarter'
export type DrillKind = 'ingresadas' | 'ganadas' | 'perdidas' | 'abiertas' | 'estancadas' | 'vencidas' | 'riesgo'

export interface DrillRow {
  id: string
  empresa: string | null
  nombre: string | null
  owner_id: string | null
  canal: string
  etapa: string
  motivo: string | null
  uf: number | null
  fecha: string | null
  /** Solo en los detalles de salud: días sin seguimiento o de atraso, según el tipo. */
  dias?: number
  motivos?: string[]
}

/** Estado del panel de detalle (drill-down). */
export const useDrill = () => useState<{ kind: DrillKind, from: string, to: string, title: string, days?: number } | null>('revDrill', () => null)

/** Intervalo [from, to) del período elegido. La fecha de corte se redondea al minuto para compartir caché. */
export function revRange(days: number) {
  const to = new Date(Math.floor(Date.now() / 60_000) * 60_000)
  const from = days > 0 ? new Date(to.getTime() - days * 86_400_000) : new Date('2015-01-01T00:00:00Z')
  return { from, to }
}

const CACHE_MS = 60_000
const cache = new Map<string, { at: number, data: unknown }>()
// Peticiones en curso: si dos módulos piden lo mismo a la vez (p. ej. dos gráficos con la misma serie), se hace una sola.
const inflight = new Map<string, Promise<unknown>>()

async function cached<T>(key: string, call: () => Promise<{ data: unknown, error: { message: string } | null }>): Promise<T> {
  const hit = cache.get(key)
  if (hit && Date.now() - hit.at < CACHE_MS)
    return hit.data as T
  const pending = inflight.get(key)
  if (pending)
    return pending as Promise<T>
  const p = (async () => {
    const { data, error } = await call()
    if (error)
      throw new Error(error.message)
    cache.set(key, { at: Date.now(), data })
    if (cache.size > 120)
      cache.delete(cache.keys().next().value as string)
    return data as T
  })().finally(() => inflight.delete(key))
  inflight.set(key, p)
  return p
}

/** Vacía la caché: se usa al abrir el dashboard, porque desde otra pantalla pudo cambiar algún lead. */
export function clearRevCache() {
  cache.clear()
}

const who = (f: RevFilters) => ({ p_owner: f.owner || null, p_channel: f.channel || null, p_icp: null })

export function fetchRevKpis(f: RevFilters): Promise<RevKpis> {
  const { from, to } = revRange(f.days)
  return cached<RevKpis>(`k|${from.getTime()}|${to.getTime()}|${f.owner}|${f.channel}`, () =>
    useSupabase().rpc('rev_kpis', { p_from: from.toISOString(), p_to: to.toISOString(), ...who(f) }))
}

export function fetchRevSeries(from: Date, to: Date, gran: RevGran, f: RevFilters, align = false): Promise<RevBucket[]> {
  return cached<RevBucket[]>(`s|${from.getTime()}|${to.getTime()}|${gran}|${align}|${f.owner}|${f.channel}`, () =>
    useSupabase().rpc('rev_series', { p_from: from.toISOString(), p_to: to.toISOString(), p_gran: gran, p_align: align, ...who(f) }))
}

export function fetchRevDrill(kind: DrillKind, from: string, to: string, f: RevFilters): Promise<DrillRow[]> {
  return cached<DrillRow[]>(`d|${kind}|${from}|${to}|${f.owner}|${f.channel}`, () =>
    useSupabase().rpc('rev_drill', { p_kind: kind, p_from: from, p_to: to, ...who(f) }))
}

// ---- Conversión por cohorte, embudo, distribución y forecast (supabase/011_rev_conversion_forecast.sql) ----

export interface RevCohort {
  inicio: string
  n: number
  ganados: number
  perdidos: number
  abiertos: number
  uf_ganadas: number
  conv_ingresados: number
  conv_resueltos: number | null
}

export interface RevFunnel {
  total: number
  incompletos: number
  etapas: { etapa: string, alcanzaron: number, uf: number, dias_prom: number | null }[]
}

export interface RevDistribution {
  total_n: number
  total_uf: number
  etapas: { etapa: string, n: number, uf: number, sin_valor: number }[]
}

export interface ForecastBlock { n: number, uf: number, pond: number, sin_valor: number }
export interface RevForecast {
  al: string
  total: { n: number, uf: number, pond: number }
  comprometido: { n: number, uf: number, pond: number }
  bloques: Record<'mes0' | 'mes1' | 'mes2' | 'despues' | 'vencida' | 'sin_fecha', ForecastBlock>
  ganado_mes: { uf: number, n: number }
  proximas: { id: string, empresa: string | null, nombre: string | null, etapa: string, uf: number | null, prob: number, fecha: string }[]
  calibracion: { cierres_completos: number, disponible: boolean, usando_observado: boolean }
}

const ALL_TIME = new Date('2015-01-01T00:00:00Z')

export function fetchRevCohorts(from: Date, to: Date, f: RevFilters): Promise<RevCohort[]> {
  return cached<RevCohort[]>(`c|${from.getTime()}|${to.getTime()}|${f.owner}|${f.channel}`, () =>
    useSupabase().rpc('rev_cohorts', { p_from: from.toISOString(), p_to: to.toISOString(), ...who(f) }))
}

/** Embudo de cohorte de los leads creados en [from, to). Con `allTime` se usa todo el historial. */
export function fetchRevFunnel(days: number, f: RevFilters, allTime = false): Promise<RevFunnel> {
  const { from, to } = revRange(allTime ? 0 : days)
  return cached<RevFunnel>(`f|${from.getTime()}|${to.getTime()}|${f.owner}|${f.channel}`, () =>
    useSupabase().rpc('rev_funnel_cohort', { p_from: (allTime ? ALL_TIME : from).toISOString(), p_to: to.toISOString(), ...who(f) }))
}

export function fetchRevDistribution(f: RevFilters): Promise<RevDistribution> {
  const t = new Date(Math.floor(Date.now() / 60_000) * 60_000)
  return cached<RevDistribution>(`dist|${t.getTime()}|${f.owner}|${f.channel}`, () =>
    useSupabase().rpc('rev_stage_distribution', { p_t: t.toISOString(), ...who(f) }))
}

export function fetchRevForecast(f: RevFilters, observed: boolean): Promise<RevForecast> {
  const t = new Date(Math.floor(Date.now() / 60_000) * 60_000)
  return cached<RevForecast>(`fc|${t.getTime()}|${observed}|${f.owner}|${f.channel}`, () =>
    useSupabase().rpc('rev_forecast', { p_observed: observed, p_at: t.toISOString(), ...who(f) }))
}

/** Rango de los gráficos mensuales: al menos 6 meses; days = 0 → todo el historial. */
export function revMonthlyRange(days: number) {
  const { to } = revRange(days)
  const back = days > 0 ? Math.max(6, Math.round(days / 30.44)) : 0
  return { from: back ? new Date(to.getTime() - back * 30.44 * 86_400_000) : ALL_TIME, to }
}

// ---- Rendimiento por canal y responsable (supabase/012_rev_performance.sql) ----

export interface RevPerfRow {
  clave: string | null
  creados: number
  abiertas: number
  uf_abiertas: number
  pond: number
  gan_n: number
  gan_uf: number
  per_n: number
  per_uf: number
  conv_cantidad: number | null
  conv_valor: number | null
  ticket: number | null
  dias_cierre: number | null
  sin_seguimiento: number
  uf_sin_seguimiento: number
  vencidas: number
}

export interface RevChannelMonth { inicio: string, canal: string, gan_uf: number, gan_n: number, ing_n: number }

/** Días sin actividad ni cambio de etapa para considerar una oportunidad "sin seguimiento". */
export const STALE_DAYS = 7

/** Cada tabla compara TODAS sus filas: ignora el filtro de su propia dimensión (se resalta la fila elegida). */
export function fetchRevPerformance(dim: 'channel' | 'owner', f: RevFilters): Promise<RevPerfRow[]> {
  const { from, to } = revRange(f.days)
  const own = dim === 'owner' ? '' : f.owner
  const chan = dim === 'channel' ? '' : f.channel
  return cached<RevPerfRow[]>(`perf|${dim}|${from.getTime()}|${to.getTime()}|${own}|${chan}`, () =>
    useSupabase().rpc('rev_performance', {
      p_dim: dim, p_from: from.toISOString(), p_to: to.toISOString(),
      p_owner: own || null, p_channel: chan || null, p_icp: null, p_stale_days: STALE_DAYS,
    }))
}

export function fetchRevChannelMonthly(f: RevFilters): Promise<RevChannelMonth[]> {
  const { from, to } = revMonthlyRange(f.days)
  return cached<RevChannelMonth[]>(`chm|${from.getTime()}|${to.getTime()}|${f.owner}`, () =>
    useSupabase().rpc('rev_channel_monthly', {
      p_from: from.toISOString(), p_to: to.toISOString(), p_owner: f.owner || null, p_channel: null, p_icp: null,
    }))
}

// ---- Salud del pipeline e insights (supabase/013_rev_health_insights.sql) ----

export type RiskRule = 'inactividad' | 'fecha_vencida' | 'postergaciones' | 'exceso_etapa'

export interface RevHealth {
  al: string
  abiertas: { n: number, uf: number }
  estancadas: { dias: number, n: number, uf: number }[]
  vencidas: {
    n: number
    uf: number
    por_responsable: { owner_id: string | null, n: number, uf: number, dias_max: number }[]
    top: { id: string, empresa: string | null, nombre: string | null, owner_id: string | null, etapa: string, uf: number | null, dias: number }[]
  }
  antiguedad: { rango: string, n: number, uf: number }[]
  riesgo: {
    n: number
    uf: number
    reglas: Record<RiskRule, { n: number, uf: number }>
    top: { id: string, empresa: string | null, nombre: string | null, owner_id: string | null, etapa: string, uf: number | null, senales: number, motivos: RiskRule[] }[]
  }
  config: Record<string, number>
}

export interface RevInsight {
  codigo: string
  tipo: 'alerta' | 'positivo' | 'info'
  datos: Record<string, number | string>
}

/** La salud es una foto de hoy (stock): no depende del período, sí del responsable y el canal. */
export function fetchRevHealth(f: RevFilters): Promise<RevHealth> {
  const t = new Date(Math.floor(Date.now() / 60_000) * 60_000)
  return cached<RevHealth>(`h|${t.getTime()}|${f.owner}|${f.channel}`, () =>
    useSupabase().rpc('rev_health', { p_at: t.toISOString(), ...who(f) }))
}

export function fetchRevHealthDrill(kind: DrillKind, days: number, f: RevFilters): Promise<DrillRow[]> {
  const t = new Date(Math.floor(Date.now() / 60_000) * 60_000)
  return cached<DrillRow[]>(`hd|${kind}|${days}|${t.getTime()}|${f.owner}|${f.channel}`, () =>
    useSupabase().rpc('rev_health_drill', { p_kind: kind, p_days: days, p_at: t.toISOString(), ...who(f) }))
}

export function fetchRevInsights(f: RevFilters): Promise<RevInsight[]> {
  const { from, to } = revRange(f.days)
  return cached<RevInsight[]>(`i|${from.getTime()}|${to.getTime()}|${f.owner}|${f.channel}`, () =>
    useSupabase().rpc('rev_insights', { p_from: from.toISOString(), p_to: to.toISOString(), ...who(f) }))
}
