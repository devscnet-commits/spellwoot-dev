<script setup>
/* global axios */
import { computed, onMounted, ref, watch } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import PipelineAiFollowupsAPI from 'dashboard/api/pipelineAiFollowups';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import { usePipelines } from '../usePipelines';
import PipelineSelector from '../components/PipelineSelector.vue';
import CadenceEditor from '../components/aiFollowups/CadenceEditor.vue';
import { activeAttemptsCount } from '../components/aiFollowups/cadenceForm';
import { STAGE_DOT_CLASS, isOpenStage, stageColor } from '../helpers';

// AI follow-up cadences of a pipeline: one tab per open stage (the cadence only makes sense while
// the deal is still open), each with its own editor.
const route = useRoute();
const { t } = useI18n();

const {
  pipelines,
  selected,
  selectedId,
  isLoading: isLoadingPipelines,
  select,
  fetchPipelines,
} = usePipelines();

const isReady = ref(false);
const cadences = ref([]);
const isLoadingCadences = ref(false);
const agents = ref([]);
const selectedStageId = ref(null);

const stages = computed(() => selected.value?.stages || []);
const openStages = computed(() => stages.value.filter(isOpenStage));
const hasPipelines = computed(() => pipelines.value.length > 0);
const selectedStage = computed(() =>
  openStages.value.find(stage => stage.id === selectedStageId.value)
);

const cadenceFor = stage =>
  cadences.value.find(cadence => cadence.resolution_state_id === stage.id) ||
  null;
const followupsCount = stage =>
  activeAttemptsCount(cadenceFor(stage)?.behaviors);

const loadCadences = async () => {
  if (!selectedId.value) return;
  isLoadingCadences.value = true;
  try {
    const { data } = await PipelineAiFollowupsAPI.list(selectedId.value);
    cadences.value = data.payload || [];
  } catch {
    useAlert(t('CRM_AI_FOLLOWUPS.EDITOR.LOAD_ERROR'));
  } finally {
    isLoadingCadences.value = false;
  }
};

// Same call as the AI agents page; only active agents can write follow-ups.
const loadAgents = async () => {
  try {
    const { data } = await axios.get(
      `/api/v1/accounts/${route.params.accountId}/ai_agents`
    );
    agents.value = (Array.isArray(data) ? data : []).filter(
      agent => agent.status === 'active'
    );
  } catch {
    useAlert(t('CRM_AI_FOLLOWUPS.EDITOR.AGENTS_LOAD_ERROR'));
  }
};

const onSaved = cadence => {
  const index = cadences.value.findIndex(c => c.id === cadence.id);
  if (index === -1) cadences.value.push(cadence);
  else cadences.value.splice(index, 1, cadence);
};
const onDeleted = id => {
  cadences.value = cadences.value.filter(cadence => cadence.id !== id);
};

watch(
  selectedId,
  () => {
    selectedStageId.value = openStages.value[0]?.id || null;
    loadCadences();
  },
  { immediate: true }
);

onMounted(async () => {
  await Promise.all([fetchPipelines(), loadAgents()]);
  // Pipelines arrive after the watch ran with the id from the URL: pick its first stage now.
  if (!selectedStageId.value) {
    selectedStageId.value = openStages.value[0]?.id || null;
  }
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
      <span class="i-lucide-sparkles size-10 text-n-slate-10" />
      <h2 class="mb-0 text-base font-semibold text-n-slate-12">
        {{ $t('CRM_AI_FOLLOWUPS.EMPTY.NO_PIPELINE_TITLE') }}
      </h2>
      <p class="max-w-md mb-0 text-sm text-n-slate-11">
        {{ $t('CRM_AI_FOLLOWUPS.EMPTY.NO_PIPELINE_DESCRIPTION') }}
      </p>
      <router-link
        :to="{ name: 'conversation_workflow_index' }"
        class="text-sm font-medium text-n-blue-11 hover:underline"
      >
        {{ $t('CRM_AI_FOLLOWUPS.EMPTY.NO_PIPELINE_ACTION') }}
      </router-link>
    </div>

    <template v-else>
      <div
        class="flex flex-wrap items-start justify-between gap-4 px-6 py-5 border-b border-n-weak"
      >
        <div class="flex flex-col gap-1 min-w-0">
          <h1
            class="flex items-center gap-2 mb-0 text-lg font-semibold text-n-slate-12"
          >
            <span class="i-lucide-sparkles size-5 text-n-violet-11 shrink-0" />
            {{ $t('CRM_AI_FOLLOWUPS.HEADER.TITLE') }}
          </h1>
          <p class="max-w-3xl mb-0 text-sm text-n-slate-11">
            {{ $t('CRM_AI_FOLLOWUPS.HEADER.DESCRIPTION') }}
          </p>
        </div>
        <PipelineSelector
          :model-value="selectedId"
          :pipelines="pipelines"
          :label="$t('CRM_AI_FOLLOWUPS.HEADER.PIPELINE_LABEL')"
          @update:model-value="select"
        />
      </div>

      <div
        v-if="!openStages.length"
        class="flex flex-col items-center justify-center flex-1 gap-3 p-8 text-center"
      >
        <span class="i-lucide-layers size-10 text-n-slate-10" />
        <h2 class="mb-0 text-base font-semibold text-n-slate-12">
          {{ $t('CRM_AI_FOLLOWUPS.EMPTY.NO_OPEN_STAGE_TITLE') }}
        </h2>
        <p class="max-w-md mb-0 text-sm text-n-slate-11">
          {{ $t('CRM_AI_FOLLOWUPS.EMPTY.NO_OPEN_STAGE_DESCRIPTION') }}
        </p>
      </div>

      <template v-else>
        <div
          class="flex items-center gap-2 px-6 py-3 overflow-x-auto border-b border-n-weak"
        >
          <button
            v-for="(stage, index) in openStages"
            :key="stage.id"
            type="button"
            class="flex items-center gap-2 px-3 py-1.5 text-sm rounded-lg border shrink-0"
            :class="
              stage.id === selectedStageId
                ? 'border-n-brand bg-n-brand/10 text-n-slate-12'
                : 'border-n-weak bg-n-solid-2 text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12'
            "
            @click="selectedStageId = stage.id"
          >
            <span
              class="size-2 rounded-full shrink-0"
              :class="STAGE_DOT_CLASS[stageColor(stage, index)]"
            />
            {{ stage.display_label }}
            <span
              class="px-1.5 py-0.5 text-xs font-medium rounded-full"
              :class="
                followupsCount(stage)
                  ? 'bg-n-violet-9/15 text-n-violet-11'
                  : 'bg-n-alpha-2 text-n-slate-10'
              "
            >
              {{
                $t('CRM_AI_FOLLOWUPS.STAGES.COUNT', {
                  count: followupsCount(stage),
                })
              }}
            </span>
          </button>
        </div>

        <div
          v-if="isLoadingCadences"
          class="flex items-center justify-center flex-1"
        >
          <Spinner class="text-n-slate-11" />
        </div>
        <div v-else-if="selectedStage" class="p-6">
          <CadenceEditor
            :key="`${selected.id}-${selectedStage.id}`"
            :pipeline="selected"
            :stage="selectedStage"
            :stages="stages"
            :cadence="cadenceFor(selectedStage)"
            :agents="agents"
            @saved="onSaved"
            @deleted="onDeleted"
          />
        </div>
      </template>
    </template>
  </div>
</template>
