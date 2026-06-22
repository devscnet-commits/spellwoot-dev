<script setup>
/* global axios */
import { ref, computed, watch, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import Select from 'dashboard/components-next/select/Select.vue';

const route = useRoute();
const { t } = useI18n();

const blank = () => ({
  facets: { departments: [], error_types: [], statuses: [] },
  summary: {
    evaluated: 0,
    unanswered: 0,
    errors: 0,
    low_confidence: 0,
    tools_suggested: 0,
    tools_missing: 0,
    knowledge_gaps: 0,
    by_resolution: {},
    by_department: [],
    by_error: [],
  },
  insights: [],
  runs: [],
});
const data = ref(blank());
const isLoading = ref(false);

const filters = ref({
  period: '0',
  department_id: '',
  error_type: '',
  status: '',
  has_reply: '',
  has_tool: '',
  conversation_id: '',
});

// Visual identity per resolution outcome.
const RESOLUTION_META = {
  knowledge: { cls: 'bg-n-teal-3 text-n-teal-11', icon: 'i-lucide-book-open' },
  instruction: {
    cls: 'bg-n-blue-3 text-n-blue-11',
    icon: 'i-lucide-file-text',
  },
  tool: { cls: 'bg-n-brand/15 text-n-brand', icon: 'i-lucide-wrench' },
  transfer: {
    cls: 'bg-n-amber-3 text-n-amber-11',
    icon: 'i-lucide-user-round',
  },
  closed: { cls: 'bg-n-alpha-2 text-n-slate-11', icon: 'i-lucide-check' },
  unanswered: {
    cls: 'bg-n-ruby-3 text-n-ruby-11',
    icon: 'i-lucide-help-circle',
  },
  error: { cls: 'bg-n-ruby-3 text-n-ruby-11', icon: 'i-lucide-alert-triangle' },
};
const resolutionMeta = r => RESOLUTION_META[r] || RESOLUTION_META.closed;
const resolutionLabel = r => t(`AI_SHADOW_RUNS.RESOLUTION.${r}`);

const errorTypeLabel = type =>
  type ? t(`AI_SHADOW_RUNS.ERROR_TYPES.${type}`) : type;
const statusLabel = s => t(`AI_SHADOW_RUNS.STATUS.${s}`, s);
const methodLabel = m => (m ? t(`AI_SHADOW_RUNS.METHODS.${m}`, m) : '');

const isErrorRow = run => run.status === 'error' || !!run.error_type;

// Filter options
const periodOptions = computed(() => [
  { value: '0', label: t('AI_SHADOW_RUNS.FILTERS.PERIOD_ALL') },
  { value: '7', label: t('AI_SHADOW_RUNS.FILTERS.PERIOD_7') },
  { value: '30', label: t('AI_SHADOW_RUNS.FILTERS.PERIOD_30') },
]);
const departmentOptions = computed(() => [
  { value: '', label: t('AI_SHADOW_RUNS.FILTERS.DEPARTMENT_ALL') },
  ...data.value.facets.departments.map(d => ({
    value: String(d.id),
    label: d.name,
  })),
]);
const errorOptions = computed(() => [
  { value: '', label: t('AI_SHADOW_RUNS.FILTERS.ERROR_ALL') },
  ...data.value.facets.error_types.map(e => ({
    value: e,
    label: errorTypeLabel(e),
  })),
]);
const statusOptions = computed(() => [
  { value: '', label: t('AI_SHADOW_RUNS.FILTERS.STATUS_ALL') },
  ...data.value.facets.statuses.map(s => ({ value: s, label: statusLabel(s) })),
]);
const replyOptions = computed(() => [
  { value: '', label: t('AI_SHADOW_RUNS.FILTERS.ANY') },
  { value: 'true', label: t('AI_SHADOW_RUNS.FILTERS.HAS_REPLY') },
  { value: 'false', label: t('AI_SHADOW_RUNS.FILTERS.NO_REPLY') },
]);
const toolOptions = computed(() => [
  { value: '', label: t('AI_SHADOW_RUNS.FILTERS.ANY') },
  { value: 'true', label: t('AI_SHADOW_RUNS.FILTERS.HAS_TOOL') },
  { value: 'false', label: t('AI_SHADOW_RUNS.FILTERS.NO_TOOL') },
]);

// KPI cards (value + whether a positive number is a problem).
const kpis = computed(() => {
  const s = data.value.summary;
  return [
    { key: 'EVALUATED', value: s.evaluated, warn: false },
    { key: 'UNANSWERED', value: s.unanswered, warn: true },
    { key: 'ERRORS', value: s.errors, warn: true },
    { key: 'LOW_CONFIDENCE', value: s.low_confidence, warn: true },
    { key: 'TOOLS_MISSING', value: s.tools_missing, warn: true },
    { key: 'KNOWLEDGE_GAPS', value: s.knowledge_gaps, warn: true },
  ];
});

const resolutionChips = computed(() =>
  Object.entries(data.value.summary.by_resolution || {})
    .map(([resolution, count]) => ({ resolution, count }))
    .sort((a, b) => b.count - a.count)
);

const insightsByType = type =>
  computed(() => data.value.insights.filter(i => i.type === type));
const faqInsights = insightsByType('faq');
const instructionInsights = insightsByType('instruction');
const toolInsights = insightsByType('tool');
const errorInsights = insightsByType('error');

const INSIGHT_META = {
  faq: { icon: 'i-lucide-book-open', cls: 'text-n-amber-11 bg-n-amber-3' },
  instruction: {
    icon: 'i-lucide-file-text',
    cls: 'text-n-blue-11 bg-n-blue-3',
  },
  tool: { icon: 'i-lucide-wrench', cls: 'text-n-brand bg-n-brand/15' },
  error: { icon: 'i-lucide-alert-triangle', cls: 'text-n-ruby-11 bg-n-ruby-3' },
};
const insightBody = i => {
  if (i.type === 'faq') {
    return t('AI_SHADOW_RUNS.INSIGHT.FAQ_BODY', {
      count: i.count,
      department: i.department,
    });
  }
  if (i.type === 'instruction') {
    return t('AI_SHADOW_RUNS.INSIGHT.INSTRUCTION_BODY', {
      count: i.count,
      department: i.department,
    });
  }
  if (i.type === 'tool') {
    return t('AI_SHADOW_RUNS.INSIGHT.TOOL_BODY', {
      count: i.count,
      department: i.department,
      tool: i.tool,
    });
  }
  return t('AI_SHADOW_RUNS.INSIGHT.ERROR_BODY', {
    count: i.count,
    error: errorTypeLabel(i.error_type),
  });
};

// Diagnostic blocks driven by config to avoid repetitive markup.
const diagnosticBlocks = computed(() => [
  { key: 'faq', title: 'KNOWLEDGE_GAPS', items: faqInsights.value },
  {
    key: 'instruction',
    title: 'INSTRUCTION_FAILS',
    items: instructionInsights.value,
  },
  { key: 'tool', title: 'TOOLS_MISSING', items: toolInsights.value },
  { key: 'error', title: 'RECURRING_ERRORS', items: errorInsights.value },
]);

const hasData = computed(() => data.value.summary.evaluated > 0);

const fetchRuns = async () => {
  isLoading.value = true;
  try {
    const params = {};
    Object.entries(filters.value).forEach(([key, value]) => {
      if (key === 'period') return;
      if (value !== '' && value != null) params[key] = value;
    });
    const days = Number(filters.value.period) || 0;
    if (days > 0) params.days = days;
    const { data: payload } = await axios.get(
      `/api/v1/accounts/${route.params.accountId}/ai_shadow_runs`,
      { params }
    );
    data.value = { ...blank(), ...(payload || {}) };
  } catch (error) {
    data.value = blank();
  } finally {
    isLoading.value = false;
  }
};

const clearFilters = () => {
  filters.value = {
    period: '0',
    department_id: '',
    error_type: '',
    status: '',
    has_reply: '',
    has_tool: '',
    conversation_id: '',
  };
};

watch(filters, fetchRuns, { deep: true });
onMounted(fetchRuns);
</script>

<template>
  <div
    class="flex flex-col w-full h-full overflow-auto p-4 sm:p-6 gap-5 max-w-5xl mx-auto"
  >
    <div class="flex items-start justify-between gap-4">
      <div class="flex flex-col gap-1">
        <h1 class="text-xl font-semibold text-n-slate-12">
          {{ $t('AI_SHADOW_RUNS.TITLE') }}
        </h1>
        <p class="text-sm text-n-slate-11 mb-0 max-w-2xl">
          {{ $t('AI_SHADOW_RUNS.DESCRIPTION') }}
        </p>
      </div>
      <button
        type="button"
        class="shrink-0 text-sm font-medium px-3 py-2 rounded-lg bg-n-alpha-2 text-n-slate-12 disabled:opacity-50"
        :disabled="isLoading"
        @click="fetchRuns"
      >
        {{
          isLoading
            ? $t('AI_SHADOW_RUNS.LOADING')
            : $t('AI_SHADOW_RUNS.REFRESH')
        }}
      </button>
    </div>

    <!-- Filters -->
    <div class="flex flex-wrap items-end gap-2">
      <Select v-model="filters.period" :options="periodOptions" />
      <Select v-model="filters.department_id" :options="departmentOptions" />
      <Select v-model="filters.error_type" :options="errorOptions" />
      <Select v-model="filters.status" :options="statusOptions" />
      <Select v-model="filters.has_reply" :options="replyOptions" />
      <Select v-model="filters.has_tool" :options="toolOptions" />
      <input
        v-model="filters.conversation_id"
        type="search"
        inputmode="numeric"
        :placeholder="$t('AI_SHADOW_RUNS.FILTERS.CONVERSATION')"
        class="w-28 px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12"
      />
      <button
        type="button"
        class="text-sm text-n-slate-11 hover:text-n-slate-12 px-2 py-2"
        @click="clearFilters"
      >
        {{ $t('AI_SHADOW_RUNS.FILTERS.CLEAR') }}
      </button>
    </div>

    <p
      v-if="!isLoading && !hasData"
      class="text-sm text-n-slate-11 py-8 text-center"
    >
      {{ $t('AI_SHADOW_RUNS.EMPTY') }}
    </p>

    <template v-else>
      <!-- Resumo executivo -->
      <section class="flex flex-col gap-3">
        <h2 class="text-sm font-semibold text-n-slate-12">
          {{ $t('AI_SHADOW_RUNS.BLOCKS.SUMMARY') }}
        </h2>
        <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3">
          <div
            v-for="kpi in kpis"
            :key="kpi.key"
            class="border border-n-weak rounded-xl p-3"
          >
            <p class="text-xs text-n-slate-11 mb-1">
              {{ $t(`AI_SHADOW_RUNS.KPI.${kpi.key}`) }}
            </p>
            <p
              class="text-xl font-semibold mb-0"
              :class="
                kpi.warn && kpi.value > 0 ? 'text-n-ruby-11' : 'text-n-slate-12'
              "
            >
              {{ kpi.value }}
            </p>
          </div>
        </div>
        <!-- Resolution distribution -->
        <div class="flex flex-wrap gap-2">
          <span
            v-for="chip in resolutionChips"
            :key="chip.resolution"
            class="inline-flex items-center gap-1.5 rounded-full px-3 py-1 text-xs font-medium"
            :class="resolutionMeta(chip.resolution).cls"
          >
            <span
              :class="resolutionMeta(chip.resolution).icon"
              class="size-3"
            />
            {{ resolutionLabel(chip.resolution) }}
            <span class="opacity-70">{{ chip.count }}</span>
          </span>
        </div>
      </section>

      <!-- Diagnostic blocks: knowledge gaps / instruction / tools / recurring errors -->
      <section
        v-for="block in diagnosticBlocks"
        :key="block.key"
        class="flex flex-col gap-2"
      >
        <h2 class="text-sm font-semibold text-n-slate-12">
          {{ $t(`AI_SHADOW_RUNS.BLOCKS.${block.title}`) }}
        </h2>
        <p v-if="!block.items.length" class="text-sm text-n-slate-11 mb-0 px-1">
          {{ $t('AI_SHADOW_RUNS.INSIGHT.EMPTY') }}
        </p>
        <div
          v-for="(insight, index) in block.items"
          :key="index"
          class="flex items-start gap-3 rounded-xl border border-n-weak bg-n-solid-1 p-3"
        >
          <span
            class="shrink-0 size-8 rounded-lg flex items-center justify-center"
            :class="INSIGHT_META[block.key].cls"
          >
            <span :class="INSIGHT_META[block.key].icon" class="size-4" />
          </span>
          <div class="min-w-0 flex-1">
            <p class="text-sm font-medium text-n-slate-12 mb-0">
              {{
                $t(`AI_SHADOW_RUNS.INSIGHT.${block.key.toUpperCase()}_TITLE`)
              }}
            </p>
            <p class="text-xs text-n-slate-11 mb-0">
              {{ insightBody(insight) }}
            </p>
          </div>
          <span
            class="shrink-0 inline-flex items-center justify-center min-w-6 px-1.5 h-6 rounded-full bg-n-alpha-2 text-xs font-medium text-n-slate-12"
          >
            {{ insight.count }}
          </span>
        </div>
      </section>

      <!-- Oportunidades por departamento -->
      <section
        v-if="data.summary.by_department.length"
        class="flex flex-col gap-2"
      >
        <h2 class="text-sm font-semibold text-n-slate-12">
          {{ $t('AI_SHADOW_RUNS.BLOCKS.BY_DEPARTMENT') }}
        </h2>
        <div class="border border-n-weak rounded-xl divide-y divide-n-weak">
          <div
            v-for="(dept, index) in data.summary.by_department"
            :key="index"
            class="flex items-center justify-between gap-3 px-4 py-2.5 text-sm"
          >
            <span class="text-n-slate-12 truncate">{{ dept.name }}</span>
            <span
              class="shrink-0 flex items-center gap-4 text-xs text-n-slate-11"
            >
              <span>{{
                dept.total + ' ' + $t('AI_SHADOW_RUNS.DEPT.TOTAL')
              }}</span>
              <span :class="{ 'text-n-ruby-11 font-medium': dept.errors > 0 }">
                {{ dept.errors + ' ' + $t('AI_SHADOW_RUNS.DEPT.ERRORS') }}
              </span>
              <span
                :class="{ 'text-n-amber-11 font-medium': dept.unanswered > 0 }"
              >
                {{
                  dept.unanswered + ' ' + $t('AI_SHADOW_RUNS.DEPT.UNANSWERED')
                }}
              </span>
            </span>
          </div>
        </div>
      </section>

      <!-- Execuções detalhadas -->
      <section class="flex flex-col gap-3">
        <h2 class="text-sm font-semibold text-n-slate-12">
          {{ $t('AI_SHADOW_RUNS.BLOCKS.RUNS') }}
        </h2>
        <p
          v-if="!data.runs.length"
          class="text-sm text-n-slate-11 py-4 text-center mb-0"
        >
          {{ $t('AI_SHADOW_RUNS.RUN.EMPTY') }}
        </p>
        <div
          v-for="run in data.runs"
          :key="run.id"
          class="rounded-xl border border-n-weak bg-n-solid-1 p-4 flex flex-col gap-3"
        >
          <div class="flex items-start justify-between gap-3">
            <div class="flex items-center gap-2 min-w-0 text-sm">
              <span class="font-medium text-n-slate-12">
                {{
                  `${$t('AI_SHADOW_RUNS.RUN.CONVERSATION')} #${run.conversation_id}`
                }}
              </span>
              <span
                v-if="run.department"
                class="inline-flex items-center gap-1 text-n-slate-11 truncate"
              >
                <span class="i-lucide-layers size-3.5 shrink-0" />
                {{ run.department }}
                <span v-if="run.routing_method" class="text-n-slate-10">
                  {{
                    `· ${$t('AI_SHADOW_RUNS.RUN.VIA')} ${methodLabel(run.routing_method)}`
                  }}
                </span>
              </span>
            </div>
            <div class="shrink-0 flex items-center gap-1.5">
              <span
                class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium"
                :class="resolutionMeta(run.resolution).cls"
              >
                <span
                  :class="resolutionMeta(run.resolution).icon"
                  class="size-3"
                />
                {{ resolutionLabel(run.resolution) }}
              </span>
              <span
                v-if="isErrorRow(run)"
                class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-n-ruby-3 text-n-ruby-11"
              >
                {{ errorTypeLabel(run.error_type || 'unknown') }}
              </span>
            </div>
          </div>

          <p
            class="text-sm text-n-slate-12 mb-0 whitespace-pre-wrap line-clamp-3 rounded-lg bg-n-alpha-1 px-3 py-2"
            :class="{ 'italic text-n-slate-11': !run.reply_text }"
          >
            {{ run.reply_text || $t('AI_SHADOW_RUNS.RUN.NO_REPLY') }}
          </p>

          <div
            class="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-n-slate-11"
          >
            <span v-if="run.tool" class="inline-flex items-center gap-1">
              <span class="i-lucide-wrench size-3.5" />
              {{ run.tool }}
              <span v-if="run.tool_missing" class="text-n-ruby-11">{{
                `(${$t('AI_SHADOW_RUNS.RUN.TOOL_MISSING')})`
              }}</span>
            </span>
            <span class="inline-flex items-center gap-1">
              <span class="i-lucide-book-open size-3.5" />
              {{
                $t('AI_SHADOW_RUNS.RUN.KNOWLEDGE_COUNT', {
                  count: run.knowledge_count ?? 0,
                })
              }}
            </span>
            <span
              v-if="run.confidence != null"
              class="inline-flex items-center gap-1"
            >
              <span class="i-lucide-gauge size-3.5" />
              {{ `${$t('AI_SHADOW_RUNS.RUN.CONFIDENCE')}: ${run.confidence}` }}
            </span>
            <span class="inline-flex items-center gap-1">
              <span class="i-lucide-timer size-3.5" />
              {{ `${run.latency_ms ?? 0} ms` }}
            </span>
            <span class="inline-flex items-center gap-1">
              <span class="i-lucide-banknote size-3.5" />
              {{ `US$ ${run.cost ?? 0}` }}
            </span>
          </div>
        </div>
      </section>
    </template>
  </div>
</template>
