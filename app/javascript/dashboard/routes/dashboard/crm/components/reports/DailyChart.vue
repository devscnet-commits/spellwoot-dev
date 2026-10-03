<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { Line } from 'vue-chartjs';
import {
  Chart as ChartJS,
  LineElement,
  PointElement,
  CategoryScale,
  LinearScale,
  Tooltip,
  Legend,
} from 'chart.js';
import format from 'date-fns/format';
import parseISO from 'date-fns/parseISO';

const props = defineProps({
  rows: { type: Array, default: () => [] },
});

ChartJS.register(
  LineElement,
  PointElement,
  CategoryScale,
  LinearScale,
  Tooltip,
  Legend
);

const { t } = useI18n();

// Same hues as the n-blue/n-teal/n-ruby-9 tokens, as plain rgb: the canvas cannot read CSS
// variables. Each series also gets its own point shape so the legend never relies on color alone.
const SERIES = [
  {
    key: 'new_cards',
    label: t('CRM_PIPELINE_REPORTS.DAILY.NEW'),
    rgb: '0, 144, 255',
    pointStyle: 'circle',
  },
  {
    key: 'won',
    label: t('CRM_PIPELINE_REPORTS.DAILY.WON'),
    rgb: '18, 165, 148',
    pointStyle: 'rect',
  },
  {
    key: 'lost',
    label: t('CRM_PIPELINE_REPORTS.DAILY.LOST'),
    rgb: '229, 70, 102',
    pointStyle: 'triangle',
  },
];
// Neutral gray that reads on both the light and the dark surface.
const INK = 'rgba(148, 163, 184, 0.9)';
const GRID = 'rgba(148, 163, 184, 0.15)';

// Points only when there is room for them; the tooltip covers dense ranges.
const dense = computed(() => props.rows.length > 31);

const data = computed(() => ({
  labels: props.rows.map(row => format(parseISO(row.date), 'dd/MM')),
  datasets: SERIES.map(series => ({
    label: series.label,
    data: props.rows.map(row => row[series.key]),
    borderColor: `rgb(${series.rgb})`,
    backgroundColor: `rgb(${series.rgb})`,
    pointStyle: series.pointStyle,
    pointRadius: dense.value ? 0 : 3,
    pointHoverRadius: 5,
    borderWidth: 2,
    tension: 0.3,
  })),
}));

const options = {
  responsive: true,
  maintainAspectRatio: false,
  animation: { duration: 0 },
  interaction: { mode: 'index', intersect: false },
  plugins: {
    legend: {
      position: 'top',
      align: 'end',
      labels: {
        color: INK,
        usePointStyle: true,
        boxWidth: 8,
        boxHeight: 8,
        padding: 16,
      },
    },
    tooltip: { usePointStyle: true },
  },
  scales: {
    x: {
      ticks: { color: INK, maxRotation: 0, autoSkip: true, maxTicksLimit: 12 },
      grid: { display: false },
      border: { color: GRID },
    },
    y: {
      beginAtZero: true,
      ticks: { color: INK, precision: 0 },
      grid: { color: GRID },
      border: { display: false },
    },
  },
};
</script>

<template>
  <div class="relative h-72">
    <Line :data="data" :options="options" />
  </div>
</template>
