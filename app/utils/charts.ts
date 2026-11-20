// Utilidades de gráficos y exportación del dashboard comercial (SVG propio, sin librerías).

const TZ = 'America/Santiago'

export const fmtUf = (n: number | null | undefined, digits = 1) =>
  n == null ? '—' : n.toLocaleString('es-CL', { maximumFractionDigits: digits })

/** Máximo "redondo" y marcas del eje Y para un valor máximo dado. */
export function niceScale(max: number, ticks = 4) {
  if (!(max > 0))
    return { max: 1, ticks: [0, 1] }
  const raw = max / ticks
  const pow = 10 ** Math.floor(Math.log10(raw))
  const step = [1, 2, 2.5, 5, 10].map(m => m * pow).find(s => s >= raw) ?? raw
  const top = step * Math.ceil(max / step)
  const out: number[] = []
  for (let v = 0; v <= top + step / 2; v += step) out.push(Math.round(v * 1e6) / 1e6)
  return { max: top, ticks: out }
}

export function bucketLabel(iso: string, gran: 'day' | 'week' | 'month' | 'quarter') {
  const d = new Date(iso)
  if (gran === 'quarter') {
    const m = Number(new Intl.DateTimeFormat('en-US', { month: 'numeric', timeZone: TZ }).format(d))
    const y = new Intl.DateTimeFormat('es-CL', { year: '2-digit', timeZone: TZ }).format(d)
    return `T${Math.ceil(m / 3)} ${y}`
  }
  if (gran === 'month')
    return new Intl.DateTimeFormat('es-CL', { month: 'short', year: '2-digit', timeZone: TZ }).format(d).replace('.', '')
  return new Intl.DateTimeFormat('es-CL', { day: 'numeric', month: 'short', timeZone: TZ }).format(d).replace('.', '')
}

export function monthName(iso: string) {
  const s = new Intl.DateTimeFormat('es-CL', { month: 'long', year: 'numeric', timeZone: TZ }).format(new Date(iso))
  return s.charAt(0).toUpperCase() + s.slice(1)
}

/** Descarga un CSV compatible con Excel en español (separador ;, coma decimal, BOM UTF-8). */
export function downloadCsv(filename: string, rows: (string | number | null | undefined)[][]) {
  const cell = (v: string | number | null | undefined) => {
    if (v == null)
      return ''
    if (typeof v === 'number')
      return String(v).replace('.', ',')
    return /[";\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v
  }
  const blob = new Blob([`﻿${rows.map(r => r.map(cell).join(';')).join('\r\n')}`], { type: 'text/csv;charset=utf-8' })
  const a = document.createElement('a')
  a.href = URL.createObjectURL(blob)
  a.download = filename
  a.click()
  setTimeout(() => URL.revokeObjectURL(a.href), 1000)
}

/** Clave 'YYYY-MM' de un instante, en hora de Santiago. */
export function monthKey(iso: string) {
  const p = new Intl.DateTimeFormat('en-CA', { year: 'numeric', month: '2-digit', timeZone: TZ }).formatToParts(new Date(iso))
  return `${p.find(x => x.type === 'year')!.value}-${p.find(x => x.type === 'month')!.value}`
}
export function nextMonthKey(key: string) {
  const [y, m] = key.split('-').map(Number)
  return m === 12 ? `${y + 1}-01` : `${y}-${String(m + 1).padStart(2, '0')}`
}
export function monthKeyLabel(key: string, long = false) {
  const [y, m] = key.split('-').map(Number)
  const s = new Intl.DateTimeFormat('es-CL', { month: long ? 'long' : 'short', year: long ? 'numeric' : '2-digit', timeZone: 'UTC' }).format(new Date(Date.UTC(y, m - 1, 15)))
  return long ? s.charAt(0).toUpperCase() + s.slice(1) : s.replace('.', '')
}
