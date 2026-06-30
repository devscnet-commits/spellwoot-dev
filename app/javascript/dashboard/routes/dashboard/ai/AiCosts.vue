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
  total_cost_in: 0,
  total_cost_out: 0,
  total_tokens_in: 0,
  total_tokens_out: 0,
  total_runs: 0,
  total_errors: 0,
  by_model: [],
  by_agent: [],
  by_error: [],
});

const numberFormat = new Intl.NumberFormat('pt-BR');
const formatTokens = value => numberFormat.format(value || 0);
const data = ref(blank());
const isLoading = ref(false);
const period = ref('0');
const fromDate = ref('');
const toDate = ref('');
const agentId = ref('');
const agents = ref([]);

const periodOptions = computed(() => [
  { value: '0', label: t('AI_COSTS.PERIOD_ALL') },
  { value: '7', label: t('AI_COSTS.PERIOD_7') },
  { value: '30', label: t('AI_COSTS.PERIOD_30') },
  { value: 'custom', label: t('AI_COSTS.PERIOD_CUSTOM') },
]);
const agentOptions = computed(() => [
  { value: '', label: t('AI_COSTS.AGENT_ALL') },
  ...agents.value.map(a => ({
    value: String(a.id),
    label: a.assistant_name || a.name,
  })),
]);

const errorTypeLabel = type =>
  type ? t(`AI_COSTS.ERROR_TYPES.${type}`) : type;

const hasData = computed(() => data.value.total_runs > 0);

const fetchAgents = async () => {
  try {
    const { data: payload } = await axios.get(
      `/api/v1/accounts/${route.params.accountId}/ai_agents`
    );
    agents.value = Array.isArray(payload) ? payload : [];
  } catch (error) {
    agents.value = [];
  }
};

const fetchCosts = async () => {
  isLoading.value = true;
  try {
    const params = {};
    if (period.value === 'custom') {
      if (fromDate.value) params.from = fromDate.value;
      if (toDate.value) params.to = toDate.value;
    } else {
      const days = Number(period.value) || 0;
      if (days > 0) params.days = days;
    }
    if (agentId.value) params.agent_id = agentId.value;
    const { data: payload } = await axios.get(
      `/api/v1/accounts/${route.params.accountId}/ai_costs`,
      { params }
    );
    data.value = { ...blank(), ...(payload || {}) };
  } finally {
    isLoading.value = false;
  }
};

watch([period, agentId, fromDate, toDate], fetchCosts);
onMounted(() => {
  fetchAgents();
  fetchCosts();
});
</script>

<template>
  <div class="w-full h-full overflow-auto bg-n-background p-4 sm:p-6">
    <div class="max-w-5xl mx-auto flex flex-col gap-3">
      <div
        class="rounded-2xl border border-n-weak bg-n-solid-1 px-4 sm:px-8 py-6 flex flex-col gap-4"
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
          <div class="flex items-end gap-3">
            <div class="flex flex-col gap-1.5">
              <span class="text-xs text-n-slate-11">{{
                $t('AI_COSTS.AGENT')
              }}</span>
              <Select v-model="agentId" :options="agentOptions" />
            </div>
            <div class="flex flex-col gap-1.5">
              <span class="text-xs text-n-slate-11">{{
                $t('AI_COSTS.PERIOD')
              }}</span>
              <Select v-model="period" :options="periodOptions" />
            </div>
            <div v-if="period === 'custom'" class="flex flex-col gap-1.5">
              <span class="text-xs text-n-slate-11">{{
                $t('AI_COSTS.FROM')
              }}</span>
              <input
                v-model="fromDate"
                type="date"
                :max="toDate || undefined"
                class="rounded-lg border-0 outline-1 outline -outline-offset-1 outline-n-weak hover:outline-n-slate-6 focus:outline-n-blue-9 bg-n-surface-1 py-2 px-3 text-sm text-n-slate-12"
              />
            </div>
            <div v-if="period === 'custom'" class="flex flex-col gap-1.5">
              <span class="text-xs text-n-slate-11">{{
                $t('AI_COSTS.TO')
              }}</span>
              <input
                v-model="toDate"
                type="date"
                :min="fromDate || undefined"
                class="rounded-lg border-0 outline-1 outline -outline-offset-1 outline-n-weak hover:outline-n-slate-6 focus:outline-n-blue-9 bg-n-surface-1 py-2 px-3 text-sm text-n-slate-12"
              />
            </div>
          </div>
        </div>

        <!-- Aviso: custos são estimativas, não a fatura final -->
        <p
          class="flex items-start gap-2 text-xs text-n-slate-11 rounded-xl border border-n-weak bg-n-alpha-1 px-3 py-2 mb-0"
        >
          <span class="i-lucide-info size-3.5 shrink-0 mt-0.5" />
          <span>{{ $t('AI_COSTS.DISCLAIMER') }}</span>
        </p>

        <!-- Headline numbers -->
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-3">
          <div class="border border-n-weak rounded-xl p-4">
            <p class="text-xs text-n-slate-11 mb-1">
              {{ $t('AI_COSTS.TOTAL_COST') }}
            </p>
            <p class="text-lg font-semibold text-n-slate-12 mb-1">
              {{ 'US$ ' + data.total_cost }}
            </p>
            <p class="text-xs text-n-slate-11 mb-0">
              {{
                $t('AI_COSTS.COST_SPLIT', {
                  input: data.total_cost_in,
                  output: data.total_cost_out,
                })
              }}
            </p>
          </div>
          <div class="border border-n-weak rounded-xl p-4">
            <p class="text-xs text-n-slate-11 mb-1">
              {{ $t('AI_COSTS.TOTAL_TOKENS') }}
            </p>
            <p class="text-lg font-semibold text-n-slate-12 mb-1">
              {{ formatTokens(data.total_tokens_in + data.total_tokens_out) }}
            </p>
            <p class="text-xs text-n-slate-11 mb-0">
              {{
                $t('AI_COSTS.TOKENS_SPLIT', {
                  input: formatTokens(data.total_tokens_in),
                  output: formatTokens(data.total_tokens_out),
                })
              }}
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
              :class="
                data.total_errors > 0 ? 'text-n-ruby-11' : 'text-n-slate-12'
              "
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
                  <span>{{
                    $t('AI_COSTS.COLUMNS.RUNS') + ': ' + row.runs
                  }}</span>
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
              <table class="w-full text-sm min-w-[44rem]">
                <thead class="bg-n-alpha-2 text-n-slate-11">
                  <tr>
                    <th class="text-left font-medium px-3 py-2">
                      {{ $t('AI_COSTS.COLUMNS.MODEL') }}
                    </th>
                    <th class="text-left font-medium px-3 py-2">
                      {{ $t('AI_COSTS.COLUMNS.RUNS') }}
                    </th>
                    <th class="text-left font-medium px-3 py-2">
                      {{ $t('AI_COSTS.COLUMNS.TOKENS_IN') }}
                    </th>
                    <th class="text-left font-medium px-3 py-2">
                      {{ $t('AI_COSTS.COLUMNS.TOKENS_OUT') }}
                    </th>
                    <th class="text-left font-medium px-3 py-2">
                      {{ $t('AI_COSTS.COLUMNS.COST_IN') }}
                    </th>
                    <th class="text-left font-medium px-3 py-2">
                      {{ $t('AI_COSTS.COLUMNS.COST_OUT') }}
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
                      {{
                        [row.provider, row.model].filter(Boolean).join(' / ')
                      }}
                    </td>
                    <td class="px-3 py-2">{{ row.runs }}</td>
                    <td class="px-3 py-2">{{ formatTokens(row.tokens_in) }}</td>
                    <td class="px-3 py-2">
                      {{ formatTokens(row.tokens_out) }}
                    </td>
                    <td class="px-3 py-2">{{ 'US$ ' + row.cost_in }}</td>
                    <td class="px-3 py-2">{{ 'US$ ' + row.cost_out }}</td>
                    <td class="px-3 py-2 font-medium">
                      {{ 'US$ ' + row.cost }}
                    </td>
                    <td class="px-3 py-2">{{ row.avg_latency }}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </template>
      </div>
    </div>
  </div>
</template>
