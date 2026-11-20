<script setup lang="ts">
// Ingresos recurrentes: módulo PREPARADO pero sin cálculos. El CRM guarda ventas comerciales (UF/mes ganadas),
// no contratos ni suscripciones: no hay fechas de inicio/término ni cancelaciones, así que no se puede saber qué
// parte de lo vendido sigue activa. Calcular MRR o churn con estos datos sería inventar información.
const INDICATORS = [
  { name: 'Nuevo MRR vendido', needs: 'Fecha de inicio y UF/mes vigente de cada contrato' },
  { name: 'MRR activo', needs: 'Contratos vigentes a una fecha de corte' },
  { name: 'MRR perdido por cancelaciones', needs: 'Fecha de cancelación y su motivo' },
  { name: 'Expansión y contracción de MRR', needs: 'Historial de cambios de UF/mes por cliente' },
  { name: 'Net New MRR', needs: 'Los cuatro anteriores' },
  { name: 'Evolución histórica de MRR', needs: 'Estado de cada contrato mes a mes' },
]
</script>

<template>
  <section class="card chart">
    <div class="chart-head">
      <div>
        <h2>Ingresos recurrentes (MRR)</h2>
        <small class="muted">Pendiente de datos contractuales. Se activará cuando el CRM reciba contratos o suscripciones confiables.</small>
      </div>
      <span class="tag">Preparado, sin datos</span>
    </div>
    <p class="muted" style="margin: 0 0 8px">
      Una oportunidad <strong>ganada</strong> es una venta comercial; el <strong>MRR activo</strong> depende de que el cliente tenga un contrato vigente.
      Por eso «UF ganadas» no se presenta como MRR, y no se calcula churn: ninguna oportunidad ganada se asume activa para siempre.
    </p>
    <table class="tbl left">
      <thead><tr><th>Indicador</th><th>Dato necesario para calcularlo</th></tr></thead>
      <tbody>
        <tr v-for="i in INDICATORS" :key="i.name"><td>{{ i.name }}</td><td class="muted">{{ i.needs }}</td></tr>
      </tbody>
    </table>
  </section>
</template>
