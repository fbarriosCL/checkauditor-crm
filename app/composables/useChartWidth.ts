/** Ancho en píxeles del contenedor de un gráfico (se actualiza al redimensionar, aunque el elemento aparezca después). */
export function useChartWidth(min = 280) {
  const wrap = ref<HTMLElement | null>(null)
  const width = ref(800)
  let ro: ResizeObserver | null = null
  watch(wrap, (el) => {
    ro?.disconnect()
    ro = null
    if (!el)
      return
    width.value = Math.max(min, el.clientWidth)
    ro = new ResizeObserver(e => (width.value = Math.max(min, e[0].contentRect.width)))
    ro.observe(el)
  }, { flush: 'post' })
  onBeforeUnmount(() => ro?.disconnect())
  return { wrap, width }
}
