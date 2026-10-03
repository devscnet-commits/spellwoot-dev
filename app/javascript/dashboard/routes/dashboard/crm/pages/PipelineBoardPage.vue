<script setup>
import {
  computed,
  onBeforeUnmount,
  onMounted,
  reactive,
  ref,
  watch,
} from 'vue';
import { useRouter } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { debounce } from '@chatwoot/utils';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import PipelinesAPI from 'dashboard/api/pipelines';
import PipelineCardsAPI from 'dashboard/api/pipelineCards';
import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import { usePipelines } from '../usePipelines';
import PipelineSelector from '../components/PipelineSelector.vue';
import PipelineColumn from '../components/PipelineColumn.vue';
import StageRequirementsDialog from '../components/StageRequirementsDialog.vue';
import NewDealDialog from '../components/NewDealDialog.vue';
import {
  TEMPERATURES,
  stageColor,
  isBlank,
  requirementAppliesToStage,
  requirementConditionMet,
} from '../helpers';

// Kanban of a sales pipeline: one column per stage, cards dragged between them (the target stage
// requirements are asked on the way) plus the quick actions of each card.
const router = useRouter();
const store = useStore();
const { t } = useI18n();

const {
  pipelines,
  selected,
  selectedId,
  isLoading: isLoadingPipelines,
  select,
  fetchPipelines,
} = usePipelines();
const attributes = useMapGetter('attributes/getConversationAttributes');

const FILTERS = [
  { value: 'all', icon: '' },
  ...TEMPERATURES.map(({ value, icon, textClass }) => ({
    value,
    icon,
    iconClass: textClass,
  })),
  {
    value: 'sla_breached',
    icon: 'i-lucide-alarm-clock',
    iconClass: 'text-n-ruby-11',
  },
];
const TICK_MS = 30 * 1000;

const isReady = ref(false);
const columns = ref([]);
const isLoadingBoard = ref(false);
const search = ref('');
const appliedSearch = ref('');
const filter = ref('all');
// Last page loaded per stage id (first page comes with the board).
const pages = reactive({});
const loadingMoreStageId = ref(null);
const requirementsDialog = ref(null);
const newDealDialog = ref(null);
// The move waiting for the requirements dialog to be filled.
const pendingMove = ref(null);

// Ticks so SLA countdowns and inactivity alerts stay current without re-fetching.
const now = ref(Date.now());
let ticker = null;

const stages = computed(() => selected.value?.stages || []);
const requirements = computed(() => selected.value?.closing_requirements || []);
const hasPipelines = computed(() => pipelines.value.length > 0);

const boardFilters = computed(() => {
  const params = {};
  if (appliedSearch.value) params.search = appliedSearch.value;
  if (['hot', 'warm', 'cold'].includes(filter.value)) {
    params.temperature = filter.value;
  }
  if (filter.value === 'sla_breached') params.sla = 'breached';
  return params;
});

const emptyColumn = stage => ({
  stage_id: stage.id,
  count: 0,
  total_value: 0,
  automations_count: 0,
  has_ai_followup: false,
  ai_followup_delay: null,
  cards: [],
  has_more: false,
});

const loadBoard = async () => {
  if (!selected.value) return;
  isLoadingBoard.value = true;
  try {
    const { data } = await PipelinesAPI.board(
      selectedId.value,
      boardFilters.value
    );
    // One column per stage, in stage order, so every column has a list to drop into.
    columns.value = stages.value.map(
      stage =>
        data.columns.find(column => column.stage_id === stage.id) ||
        emptyColumn(stage)
    );
    Object.keys(pages).forEach(key => delete pages[key]);
  } catch {
    useAlert(t('CRM_PIPELINE.BOARD.LOAD_ERROR'));
  } finally {
    isLoadingBoard.value = false;
  }
};

const columnFor = stage =>
  columns.value.find(column => column.stage_id === stage.id) ||
  emptyColumn(stage);

const requirementsCountFor = stage =>
  requirements.value.filter(requirement =>
    requirementAppliesToStage(requirement, stage, stages.value)
  ).length;

// A key the backend flagged without a requirement row (e.g. the deal value) is always required.
const requirementFor = key =>
  requirements.value.find(requirement => requirement.attribute_key === key) || {
    attribute_key: key,
    condition: { always: true },
  };

const askRequirements = (card, stage, requirementsList, currentValues) => {
  pendingMove.value = { card, stage };
  requirementsDialog.value.open({
    targetStage: stage,
    requirementsList,
    currentValues,
  });
};

const moveCard = async (card, stage, customAttributes = {}) => {
  try {
    await PipelinesAPI.move(selectedId.value, {
      conversationId: card.id,
      stageId: stage.id,
      customAttributes,
    });
    requirementsDialog.value.close();
    pendingMove.value = null;
    useAlert(
      t('CRM_PIPELINE.BOARD.MOVE_SUCCESS', { stage: stage.display_label })
    );
  } catch (error) {
    const missing = error.response?.data?.missing_attributes;
    if (missing?.length) {
      // The backend still wants more fields: keep the dialog up with those rows.
      askRequirements(card, stage, missing.map(requirementFor), {
        ...card.custom_attributes,
        ...customAttributes,
      });
      return;
    }
    requirementsDialog.value.close();
    pendingMove.value = null;
    useAlert(error.response?.data?.error || t('CRM_PIPELINE.BOARD.MOVE_ERROR'));
  }
  await loadBoard();
};

// Dropped into another column: the card is already in the target list, so first ask the target
// stage requirements still blank on the card. Rows with an "if" clause ride along because the
// dialog re-evaluates them live as the trigger attribute is typed.
const onDropped = (stage, card) => {
  const values = card.custom_attributes || {};
  const pending = requirements.value.filter(
    requirement =>
      requirementAppliesToStage(requirement, stage, stages.value) &&
      (requirement.condition?.if || isBlank(values[requirement.attribute_key]))
  );
  const needsInput = pending.some(
    requirement =>
      requirementConditionMet(requirement, values) &&
      isBlank(values[requirement.attribute_key])
  );
  if (needsInput) {
    askRequirements(card, stage, pending, values);
    return;
  }
  moveCard(card, stage);
};

const onRequirementsSubmit = values =>
  moveCard(pendingMove.value.card, pendingMove.value.stage, values);

// Cancelled: reloading puts the card back in its real column.
const onRequirementsCancel = () => {
  pendingMove.value = null;
  loadBoard();
};

const openCard = card =>
  router.push({
    name: 'inbox_conversation',
    params: { conversation_id: card.id },
  });

const setTemperature = async (card, value) => {
  try {
    await PipelineCardsAPI.setTemperature(card.id, value);
    card.temperature = value;
  } catch {
    useAlert(t('CRM_PIPELINE.BOARD.TEMPERATURE_ERROR'));
  }
};

const aiFollowup = async card => {
  try {
    await PipelineCardsAPI.aiFollowup(card.id);
    useAlert(t('CRM_PIPELINE.BOARD.AI_FOLLOWUP_QUEUED'));
  } catch (error) {
    useAlert(
      error.response?.data?.error || t('CRM_PIPELINE.BOARD.AI_FOLLOWUP_ERROR')
    );
  }
};

const loadMore = async stage => {
  const column = columnFor(stage);
  const page = (pages[stage.id] || 1) + 1;
  loadingMoreStageId.value = stage.id;
  try {
    const { data } = await PipelinesAPI.stageCards(selectedId.value, stage.id, {
      page,
      ...boardFilters.value,
    });
    column.cards.push(...data.cards);
    column.has_more = data.has_more;
    pages[stage.id] = page;
  } catch {
    useAlert(t('CRM_PIPELINE.BOARD.LOAD_ERROR'));
  } finally {
    loadingMoreStageId.value = null;
  }
};

const newDeal = stage => newDealDialog.value.open({ stageId: stage?.id });

const onDealCreated = () => {
  useAlert(t('CRM_PIPELINE.NEW_DEAL.CREATE_SUCCESS'));
  loadBoard();
};

const applySearch = debounce(
  () => {
    appliedSearch.value = search.value.trim();
  },
  300,
  false
);

watch(search, applySearch);
watch([appliedSearch, filter], () => loadBoard());
// Covers both the first load (selection resolved) and switching pipelines.
watch(selected, pipeline => {
  columns.value = [];
  if (pipeline) loadBoard();
});

onMounted(async () => {
  store.dispatch('attributes/get');
  ticker = setInterval(() => {
    now.value = Date.now();
  }, TICK_MS);
  try {
    await fetchPipelines();
  } catch {
    useAlert(t('CRM_PIPELINE.BOARD.LOAD_ERROR'));
  } finally {
    isReady.value = true;
  }
});

onBeforeUnmount(() => clearInterval(ticker));
</script>

<template>
  <div class="flex flex-col w-full h-full bg-n-background">
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
      <span class="i-lucide-kanban size-10 text-n-slate-10" />
      <h2 class="mb-0 text-base font-semibold text-n-slate-12">
        {{ $t('CRM_PIPELINE.BOARD.EMPTY_TITLE') }}
      </h2>
      <p class="max-w-md mb-0 text-sm text-n-slate-11">
        {{ $t('CRM_PIPELINE.BOARD.EMPTY_DESCRIPTION') }}
      </p>
      <router-link
        :to="{ name: 'conversation_workflow_index' }"
        class="text-sm font-medium text-n-blue-11 hover:underline"
      >
        {{ $t('CRM_PIPELINE.BOARD.EMPTY_ACTION') }}
      </router-link>
    </div>

    <template v-else>
      <div
        class="flex flex-wrap items-center gap-3 px-4 py-3 border-b border-n-weak"
      >
        <div class="flex items-center gap-2">
          <PipelineSelector
            :model-value="selectedId"
            :pipelines="pipelines"
            :label="$t('CRM_PIPELINE.BOARD.PIPELINE_LABEL')"
            @update:model-value="select"
          />
          <span v-if="selected" class="text-xs text-n-slate-11 shrink-0">
            {{ $t('CRM_PIPELINE.BOARD.STAGE_COUNT', { count: stages.length }) }}
          </span>
        </div>

        <label
          class="flex items-center h-10 gap-2 px-3 rounded-lg border border-n-weak bg-n-solid-2 min-w-64 focus-within:ring-2 focus-within:ring-n-brand"
        >
          <span class="i-lucide-search size-4 text-n-slate-10 shrink-0" />
          <input
            v-model="search"
            type="search"
            class="flex-1 min-w-0 text-sm bg-transparent border-0 text-n-slate-12 focus:outline-none placeholder:text-n-slate-10"
            :placeholder="$t('CRM_PIPELINE.BOARD.SEARCH_PLACEHOLDER')"
          />
        </label>

        <div
          class="flex items-center gap-1 p-1 rounded-lg border border-n-weak bg-n-solid-2"
        >
          <button
            v-for="option in FILTERS"
            :key="option.value"
            type="button"
            class="flex items-center gap-1 px-2.5 py-1 text-xs font-medium rounded-md"
            :class="
              filter === option.value
                ? 'bg-n-brand/10 text-n-blue-11'
                : 'text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12'
            "
            @click="filter = option.value"
          >
            <span
              v-if="option.icon"
              :class="[option.icon, option.iconClass]"
              class="size-3.5"
            />
            {{ $t(`CRM_PIPELINE.BOARD.FILTERS.${option.value}`) }}
          </button>
        </div>

        <div class="flex items-center gap-2 ltr:ml-auto rtl:mr-auto">
          <Button
            v-tooltip.bottom="$t('CRM_PIPELINE.BOARD.REFRESH')"
            type="button"
            variant="ghost"
            color="slate"
            icon="i-lucide-refresh-cw"
            :is-loading="isLoadingBoard"
            @click="loadBoard"
          />
          <Button
            type="button"
            icon="i-lucide-plus"
            :label="$t('CRM_PIPELINE.BOARD.NEW_DEAL')"
            @click="newDeal()"
          />
        </div>
      </div>

      <div
        v-if="isLoadingBoard && !columns.length"
        class="flex items-center justify-center flex-1"
      >
        <Spinner class="text-n-slate-11" />
      </div>
      <div v-else class="flex flex-1 min-h-0 gap-3 p-4 overflow-x-auto">
        <PipelineColumn
          v-for="(stage, index) in stages"
          :key="stage.id"
          :stage="stage"
          :column="columnFor(stage)"
          :color="stageColor(stage, index)"
          :requirements-count="requirementsCountFor(stage)"
          :is-loading-more="loadingMoreStageId === stage.id"
          :now="now"
          @dropped="card => onDropped(stage, card)"
          @load-more="loadMore(stage)"
          @new-card="newDeal(stage)"
          @open="openCard"
          @set-temperature="setTemperature"
          @ai-followup="aiFollowup"
        />
      </div>
    </template>

    <StageRequirementsDialog
      ref="requirementsDialog"
      :attributes="attributes"
      @submit="onRequirementsSubmit"
      @cancel="onRequirementsCancel"
    />
    <NewDealDialog
      ref="newDealDialog"
      :pipeline="selected"
      :attributes="attributes"
      @created="onDealCreated"
    />
  </div>
</template>
