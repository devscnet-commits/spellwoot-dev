<script setup>
import { computed, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import subDays from 'date-fns/subDays';
import format from 'date-fns/format';
import parseISO from 'date-fns/parseISO';
import { getUnixStartOfDay, getUnixEndOfDay } from 'helpers/DateHelper';
import { useAlert } from 'dashboard/composables';
import PipelinesAPI from 'dashboard/api/pipelines';
import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import { usePipelines } from '../usePipelines';
import PipelineSelector from '../components/PipelineSelector.vue';
import ReportCard from '../components/reports/ReportCard.vue';
import KpiTile from '../components/reports/KpiTile.vue';
import FunnelBars from '../components/reports/FunnelBars.vue';
import StagesTable from '../components/reports/StagesTable.vue';
import LossesList from '../components/reports/LossesList.vue';
import AgentsTable from '../components/reports/AgentsTable.vue';
import DailyChart from '../components/reports/DailyChart.vue';
import { formatMoney, formatDuration } from '../helpers';

// Results of a pipeline over a period: KPIs, the conversion funnel, the stages, where the deals
// were lost, the ranking by owner and the daily evolution.
const { t } = useI18n();

const {
  pipelines,
  selectedId,
  isLoading: isLoadingPipelines,
  select,
  fetchPipelines,
} = usePipelines();

// Computed so the labels follow the account locale, which is applied after the first render.
const PRESETS = computed(() => [
  { value: 7, label: t('CRM_PIPELINE_REPORTS.PERIOD.DAYS_7') },
  { value: 30, label: t('CRM_PIPELINE_REPORTS.PERIOD.DAYS_30') },
  { value: 90, label: t('CRM_PIPELINE_REPORTS.PERIOD.DAYS_90') },
  { value: 'custom', label: t('CRM_PIPELINE_REPORTS.PERIOD.CUSTOM') },
]);
const today = new Date();

const isReady = ref(false);
const report = ref(null);
const isLoadingReport = ref(false);
const hasError = ref(false);
const preset = ref(30);
const since = ref(getUnixStartOfDay(subDays(today, 29)));
const until = ref(getUnixEndOfDay(today));
const customSince = ref(format(subDays(today, 29), 'yyyy-MM-dd'));
const customUntil = ref(format(today, 'yyyy-MM-dd'));

const hasPipelines = computed(() => pipelines.value.length > 0);
const summary = computed(() => report.value?.summary || {});

const kpis = computed(() => {
  const s = summary.value;
  return [
    {
      key: 'new',
      label: t('CRM_PIPELINE_REPORTS.KPI.NEW'),
      value: s.new_cards ?? 0,
      icon: 'i-lucide-user-plus',
      tone: 'blue',
    },
    {
      key: 'won',
      label: t('CRM_PIPELINE_REPORTS.KPI.WON'),
      value: s.won_count ?? 0,
      hint: formatMoney(s.won_value),
      icon: 'i-lucide-circle-check',
      tone: 'teal',
    },
    {
      key: 'lost',
      label: t('CRM_PIPELINE_REPORTS.KPI.LOST'),
      value: s.lost_count ?? 0,
      hint: formatMoney(s.lost_value),
      icon: 'i-lucide-circle-x',
      tone: 'ruby',
    },
    {
      key: 'win_rate',
      label: t('CRM_PIPELINE_REPORTS.KPI.WIN_RATE'),
      value: s.win_rate == null ? '—' : `${s.win_rate}%`,
      hint: t('CRM_PIPELINE_REPORTS.KPI.WIN_RATE_HINT'),
      icon: 'i-lucide-percent',
      tone: 'slate',
    },
    {
      key: 'cycle',
      label: t('CRM_PIPELINE_REPORTS.KPI.AVG_CYCLE'),
      value:
        s.avg_cycle_seconds == null ? '—' : formatDuration(s.avg_cycle_seconds),
      hint: t('CRM_PIPELINE_REPORTS.KPI.AVG_CYCLE_HINT'),
      icon: 'i-lucide-timer',
      tone: 'slate',
    },
    {
      key: 'open',
      label: t('CRM_PIPELINE_REPORTS.KPI.OPEN'),
      value: s.open_count ?? 0,
      hint: formatMoney(s.open_value),
      icon: 'i-lucide-clock',
      tone: 'amber',
    },
  ];
});

const loadReport = async () => {
  if (!selectedId.value) return;
  isLoadingReport.value = true;
  hasError.value = false;
  try {
    const { data } = await PipelinesAPI.report(selectedId.value, {
      since: since.value,
      until: until.value,
    });
    report.value = data;
  } catch {
    report.value = null;
    hasError.value = true;
    useAlert(t('CRM_PIPELINE_REPORTS.ERROR.LOAD'));
  } finally {
    isLoadingReport.value = false;
  }
};

const selectPreset = value => {
  preset.value = value;
  if (value === 'custom') return;
  since.value = getUnixStartOfDay(subDays(new Date(), value - 1));
  until.value = getUnixEndOfDay(new Date());
  loadReport();
};

// parseISO keeps the picked day in the local timezone (new Date('yyyy-MM-dd') would read it as UTC).
const applyCustomRange = () => {
  if (!customSince.value || !customUntil.value) return;
  since.value = getUnixStartOfDay(parseISO(customSince.value));
  until.value = getUnixEndOfDay(parseISO(customUntil.value));
  loadReport();
};

watch(selectedId, loadReport, { immediate: true });

onMounted(async () => {
  await fetchPipelines();
  isReady.value = true;
});
</script>

<template>
  <div class="flex flex-col w-full h-full overflow-auto bg-n-background">
    <div
      v-if="!isReady || (isLoadingPipelines && !hasPipelines)"
      class="flex items-center justify-center flex-1"
    >
      <Spinner class="text-n-slate-11" />
    </div>

    <div
      v-else-if="!hasPipelines"
      class="flex flex-col items-center justify-center flex-1 gap-3 p-8 text-center"
    >
      <span class="i-lucide-chart-column size-10 text-n-slate-10" />
      <h2 class="mb-0 text-base font-semibold text-n-slate-12">
        {{ $t('CRM_PIPELINE_REPORTS.EMPTY.NO_PIPELINE_TITLE') }}
      </h2>
      <p class="max-w-md mb-0 text-sm text-n-slate-11">
        {{ $t('CRM_PIPELINE_REPORTS.EMPTY.NO_PIPELINE_DESCRIPTION') }}
      </p>
      <router-link
        :to="{ name: 'conversation_workflow_index' }"
        class="text-sm font-medium text-n-blue-11 hover:underline"
      >
        {{ $t('CRM_PIPELINE_REPORTS.EMPTY.NO_PIPELINE_ACTION') }}
      </router-link>
    </div>

    <template v-else>
      <div class="flex flex-col gap-4 px-6 py-5 border-b border-n-weak">
        <div class="flex flex-wrap items-start justify-between gap-4">
          <div class="flex flex-col gap-1 min-w-0">
            <h1
              class="flex items-center gap-2 mb-0 text-lg font-semibold text-n-slate-12"
            >
              <span
                class="i-lucide-chart-column size-5 text-n-blue-11 shrink-0"
              />
              {{ $t('CRM_PIPELINE_REPORTS.HEADER.TITLE') }}
            </h1>
            <p class="max-w-3xl mb-0 text-sm text-n-slate-11">
              {{ $t('CRM_PIPELINE_REPORTS.HEADER.DESCRIPTION') }}
            </p>
          </div>
          <div class="flex flex-wrap items-center gap-3">
            <PipelineSelector
              :model-value="selectedId"
              :pipelines="pipelines"
              :label="$t('CRM_PIPELINE_REPORTS.HEADER.PIPELINE_LABEL')"
              @update:model-value="select"
            />
            <div
              class="flex items-center gap-1 p-1 border rounded-lg bg-n-solid-2 border-n-weak"
            >
              <button
                v-for="item in PRESETS"
                :key="item.value"
                type="button"
                class="px-3 py-1.5 text-xs font-medium rounded-md transition-colors"
                :class="
                  preset === item.value
                    ? 'bg-n-brand text-white'
                    : 'text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12'
                "
                @click="selectPreset(item.value)"
              >
                {{ item.label }}
              </button>
            </div>
          </div>
        </div>

        <div
          v-if="preset === 'custom'"
          class="flex flex-wrap items-center gap-2"
        >
          <span class="text-sm text-n-slate-11">
            {{ $t('CRM_PIPELINE_REPORTS.PERIOD.FROM') }}
          </span>
          <input
            v-model="customSince"
            type="date"
            :max="customUntil"
            class="px-3 py-1.5 text-sm border rounded-md border-n-weak bg-n-solid-2 text-n-slate-12 focus:outline-none focus:border-n-brand"
          />
          <span class="text-sm text-n-slate-11">
            {{ $t('CRM_PIPELINE_REPORTS.PERIOD.UNTIL') }}
          </span>
          <input
            v-model="customUntil"
            type="date"
            :min="customSince"
            class="px-3 py-1.5 text-sm border rounded-md border-n-weak bg-n-solid-2 text-n-slate-12 focus:outline-none focus:border-n-brand"
          />
          <Button
            :label="$t('CRM_PIPELINE_REPORTS.PERIOD.APPLY')"
            size="sm"
            @click="applyCustomRange"
          />
        </div>
      </div>

      <div
        v-if="isLoadingReport && !report"
        class="flex items-center justify-center flex-1"
      >
        <Spinner class="text-n-slate-11" />
      </div>

      <div
        v-else-if="hasError"
        class="flex flex-col items-center justify-center flex-1 gap-3 p-8 text-center"
      >
        <span class="i-lucide-triangle-alert size-10 text-n-ruby-11" />
        <p class="mb-0 text-sm text-n-slate-11">
          {{ $t('CRM_PIPELINE_REPORTS.ERROR.LOAD') }}
        </p>
        <Button
          :label="$t('CRM_PIPELINE_REPORTS.ERROR.RETRY')"
          variant="outline"
          color="slate"
          size="sm"
          @click="loadReport"
        />
      </div>

      <!-- On a refetch the previous report stays visible, dimmed, instead of flashing a spinner. -->
      <div
        v-else-if="report"
        class="flex flex-col gap-5 p-6"
        :class="{ 'opacity-60 pointer-events-none': isLoadingReport }"
      >
        <div class="grid grid-cols-2 gap-3 sm:grid-cols-3 xl:grid-cols-6">
          <KpiTile
            v-for="kpi in kpis"
            :key="kpi.key"
            :label="kpi.label"
            :value="kpi.value"
            :hint="kpi.hint"
            :icon="kpi.icon"
            :tone="kpi.tone"
          />
        </div>

        <ReportCard
          :title="$t('CRM_PIPELINE_REPORTS.FUNNEL.TITLE')"
          :description="$t('CRM_PIPELINE_REPORTS.FUNNEL.DESCRIPTION')"
          icon="i-lucide-filter"
        >
          <FunnelBars :rows="report.funnel" />
        </ReportCard>

        <ReportCard
          :title="$t('CRM_PIPELINE_REPORTS.STAGES.TITLE')"
          :description="$t('CRM_PIPELINE_REPORTS.STAGES.DESCRIPTION')"
          icon="i-lucide-layers"
          flush
        >
          <StagesTable :rows="report.stages" />
        </ReportCard>

        <div class="grid grid-cols-1 gap-5 xl:grid-cols-5">
          <ReportCard
            class="xl:col-span-2"
            :title="$t('CRM_PIPELINE_REPORTS.LOSSES.TITLE')"
            :description="$t('CRM_PIPELINE_REPORTS.LOSSES.DESCRIPTION')"
            icon="i-lucide-trending-down"
          >
            <LossesList :rows="report.losses" />
          </ReportCard>
          <ReportCard
            class="xl:col-span-3"
            :title="$t('CRM_PIPELINE_REPORTS.AGENTS.TITLE')"
            :description="$t('CRM_PIPELINE_REPORTS.AGENTS.DESCRIPTION')"
            icon="i-lucide-trophy"
            flush
          >
            <AgentsTable :rows="report.agents" />
          </ReportCard>
        </div>

        <ReportCard
          :title="$t('CRM_PIPELINE_REPORTS.DAILY.TITLE')"
          :description="$t('CRM_PIPELINE_REPORTS.DAILY.DESCRIPTION')"
          icon="i-lucide-chart-line"
        >
          <DailyChart :rows="report.daily" />
        </ReportCard>
      </div>
    </template>
  </div>
</template>
