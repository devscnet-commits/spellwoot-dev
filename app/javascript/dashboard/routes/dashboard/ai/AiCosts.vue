<script setup>
/* global axios */
import { ref, computed, watch, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import Select from 'dashboard/components-next/select/Select.vue';

const route = useRoute();
const { t } = useI18n();

const blank = () => ({
  total_cost: 0,
  total_runs: 0,
  total_errors: 0,
  by_model: [],
  by_agent: [],
  by_department: [],
  by_error: [],
});
const data = ref(blank());
const isLoading = ref(false);
const period = ref('0');

const periodOptions = computed(() => [
  { value: '0', label: t('AI_COSTS.PERIOD_ALL') },
  { value: '7', label: t('AI_COSTS.PERIOD_7') },
  { value: '30', label: t('AI_COSTS.PERIOD_30') },
]);

const errorTypeLabel = type =>
  type ? t(`AI_COSTS.ERROR_TYPES.${type}`) : type;

const hasData = computed(() => data.value.total_runs > 0);

const fetchCosts = async () => {
  isLoading.value = true;
  try {
    const days = Number(period.value) || 0;
    const { data: payload } = await axios.get(
      `/api/v1/accounts/${route.params.accountId}/ai_costs`,
      { params: days > 0 ? { days } : {} }
    );
    data.value = { ...blank(), ...(payload || {}) };
  } finally {
    isLoading.value = false;
  }
};

watch(period, fetchCosts);
onMounted(fetchCosts);
</script>

<template>
  <div
    class="flex flex-col w-full h-full overflow-auto p-4 sm:p-6 gap-4 max-w-5xl mx-auto"
  >
    <div class="flex items-start justify-between gap-4">
      <div class="flex flex-col gap-1">
        <h1 class="text-xl font-semibold text-n-slate-12">
          {{ $t('AI_COSTS.TITLE') }}
        </h1>
        <p class="text-sm text-n-slate-11 mb-0">
          {{ $t('AI_COSTS.DESCRIPTION') }}
        </p>
      </div>
      <div class="flex flex-col gap-1.5">
        <span class="text-xs text-n-slate-11">{{ $t('AI_COSTS.PERIOD') }}</span>
        <Select v-model="period" :options="periodOptions" />
      </div>
    </div>

    <!-- Headline numbers -->
    <div class="grid grid-cols-3 gap-3 sm:max-w-xl">
      <div class="border border-n-weak rounded-xl p-4">
        <p class="text-xs text-n-slate-11 mb-1">
          {{ $t('AI_COSTS.TOTAL_COST') }}
        </p>
        <p class="text-lg font-semibold text-n-slate-12 mb-0">
          {{ data.total_cost }}
        </p>
      </div>
      <div class="border border-n-weak rounded-xl p-4">
        <p class="text-xs text-n-slate-11 mb-1">
          {{ $t('AI_COSTS.TOTAL_RUNS') }}
        </p>
        <p class="text-lg font-semibold text-n-slate-12 mb-0">
          {{ data.total_runs }}
        </p>
      </div>
      <div class="border border-n-weak rounded-xl p-4">
        <p class="text-xs text-n-slate-11 mb-1">
          {{ $t('AI_COSTS.TOTAL_ERRORS') }}
        </p>
        <p
          class="text-lg font-semibold mb-0"
          :class="data.total_errors > 0 ? 'text-n-ruby-11' : 'text-n-slate-12'"
        >
          {{ data.total_errors }}
        </p>
      </div>
    </div>

    <p
      v-if="!isLoading && !hasData"
      class="text-sm text-n-slate-11 py-8 text-center"
    >
      {{ $t('AI_COSTS.EMPTY') }}
    </p>

    <template v-else>
      <!-- By agent -->
      <div class="flex flex-col gap-2">
        <h2 class="text-sm font-semibold text-n-slate-12">
          {{ $t('AI_COSTS.BY_AGENT') }}
        </h2>
        <div class="border border-n-weak rounded-xl divide-y divide-n-weak">
          <p
            v-if="!data.by_agent.length"
            class="text-sm text-n-slate-11 px-4 py-3 mb-0"
          >
            {{ $t('AI_COSTS.EMPTY_SECTION') }}
          </p>
          <div
            v-for="(row, index) in data.by_agent"
            :key="index"
            class="flex items-center justify-between gap-3 px-4 py-2.5 text-sm"
          >
            <span class="text-n-slate-12 truncate">{{ row.name }}</span>
            <span class="shrink-0 flex items-center gap-4 text-n-slate-11">
              <span>{{ $t('AI_COSTS.COLUMNS.RUNS') + ': ' + row.runs }}</span>
              <span class="text-n-slate-12 font-medium">{{
                'US$ ' + row.cost
              }}</span>
            </span>
          </div>
        </div>
      </div>

      <!-- By department -->
      <div class="flex flex-col gap-2">
        <h2 class="text-sm font-semibold text-n-slate-12">
          {{ $t('AI_COSTS.BY_DEPARTMENT') }}
        </h2>
        <div class="border border-n-weak rounded-xl divide-y divide-n-weak">
          <p
            v-if="!data.by_department.length"
            class="text-sm text-n-slate-11 px-4 py-3 mb-0"
          >
            {{ $t('AI_COSTS.EMPTY_SECTION') }}
          </p>
          <div
            v-for="(row, index) in data.by_department"
            :key="index"
            class="flex items-center justify-between gap-3 px-4 py-2.5 text-sm"
          >
            <span class="text-n-slate-12 truncate">{{ row.name }}</span>
            <span class="shrink-0 flex items-center gap-4 text-n-slate-11">
              <span>{{ $t('AI_COSTS.COLUMNS.RUNS') + ': ' + row.runs }}</span>
              <span class="text-n-slate-12 font-medium">{{
                'US$ ' + row.cost
              }}</span>
            </span>
          </div>
        </div>
      </div>

      <!-- Errors by type -->
      <div v-if="data.by_error.length" class="flex flex-col gap-2">
        <h2 class="text-sm font-semibold text-n-slate-12">
          {{ $t('AI_COSTS.BY_ERROR') }}
        </h2>
        <div class="flex flex-wrap gap-2">
          <span
            v-for="(row, index) in data.by_error"
            :key="index"
            class="inline-flex items-center gap-2 rounded-full bg-n-ruby-3 text-n-ruby-11 px-3 py-1 text-xs font-medium"
          >
            {{ errorTypeLabel(row.error_type) }}
            <span class="rounded-full bg-n-ruby-9/20 px-1.5">{{
              row.count
            }}</span>
          </span>
        </div>
      </div>

      <!-- By model -->
      <div class="flex flex-col gap-2">
        <h2 class="text-sm font-semibold text-n-slate-12">
          {{ $t('AI_COSTS.BY_MODEL') }}
        </h2>
        <div class="border border-n-weak rounded-xl overflow-x-auto">
          <table class="w-full text-sm min-w-[32rem]">
            <thead class="bg-n-alpha-2 text-n-slate-11">
              <tr>
                <th class="text-left font-medium px-3 py-2">
                  {{ $t('AI_COSTS.COLUMNS.MODEL') }}
                </th>
                <th class="text-left font-medium px-3 py-2">
                  {{ $t('AI_COSTS.COLUMNS.RUNS') }}
                </th>
                <th class="text-left font-medium px-3 py-2">
                  {{ $t('AI_COSTS.COLUMNS.COST') }}
                </th>
                <th class="text-left font-medium px-3 py-2">
                  {{ $t('AI_COSTS.COLUMNS.AVG_LATENCY') }}
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-n-weak text-n-slate-12">
              <tr v-for="(row, index) in data.by_model" :key="index">
                <td class="px-3 py-2 whitespace-nowrap">
                  {{ [row.provider, row.model].filter(Boolean).join(' / ') }}
                </td>
                <td class="px-3 py-2">{{ row.runs }}</td>
                <td class="px-3 py-2">{{ row.cost }}</td>
                <td class="px-3 py-2">{{ row.avg_latency }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </template>
  </div>
</template>
