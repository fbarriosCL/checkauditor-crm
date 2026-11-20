<script setup lang="ts">
// Dashboard comercial (Revenue Intelligence). Todo el cálculo vive en funciones SQL (supabase/009 a 013) y cada
// módulo pide solo su resultado ya agregado; aquí solo se ordena la página. Filtros globales en useRevFilters().
useHead({ title: 'Dashboard comercial · CRM Check Auditor' })
// Al volver desde otra pantalla (p. ej. tras editar un lead) las cifras deben reflejarlo: se parte sin caché.
clearRevCache()
</script>

<template>
  <div class="dash">
    <div class="dash-head">
      <div>
        <p class="eyebrow">Revenue Intelligence</p>
        <h1>Dashboard comercial</h1>
      </div>
    </div>

    <!-- Filtros globales: período, responsable y canal -->
    <RevenueFilters />

    <!-- Fila 1 · KPIs ejecutivos -->
    <RevenueKpis />

    <!-- Fila 2 · Evolución de UF en el tiempo -->
    <EvolutionChart />

    <!-- Fila 3 · Performance mensual -->
    <div class="two">
      <MonthlySalesChart />
      <ConversionChart />
    </div>

    <!-- Fila 4 · Forecast y embudo -->
    <div class="two">
      <ForecastPanel />
      <FunnelUf />
    </div>

    <!-- Fila 5 · Rendimiento -->
    <ChannelPerformance />
    <OwnerPerformance />

    <!-- Fila 6 · Salud del pipeline -->
    <PipelineHealth />

    <!-- Fila 7 · Insights -->
    <InsightsPanel />

    <!-- Ingresos recurrentes: preparado, sin datos contractuales -->
    <MrrPlaceholder />

    <DrillDialog />
  </div>
</template>
