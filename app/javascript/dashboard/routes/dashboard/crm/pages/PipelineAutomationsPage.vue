<script setup>
import { computed, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import PipelineAutomationsAPI from 'dashboard/api/pipelineAutomations';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import { usePipelines } from '../usePipelines';
import PipelineSelector from '../components/PipelineSelector.vue';
import AutomationList from '../components/automations/AutomationList.vue';
import AutomationEditor from '../components/automations/AutomationEditor.vue';
import { newAutomation } from '../components/automations/automationForm';
import { STAGE_DOT_CLASS, stageColor } from '../helpers';

// Stage automations of a pipeline: one tab per stage, the rules of the selected stage on the left
// and the editor of the selected (or new) rule on the right.
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

const inboxes = useMapGetter('inboxes/getInboxes');
const teams = useMapGetter('teams/getTeams');
const agents = useMapGetter('agents/getAgents');
const labels = useMapGetter('labels/getLabels');
const attributes = useMapGetter('attributes/getConversationAttributes');

const isReady = ref(false);
const automations = ref([]);
const isLoadingList = ref(false);
const selectedStageId = ref(null);
const selectedAutomationId = ref(null);
// The unsaved rule being created ("+ Nova Automação"); null while editing an existing one.
const newDraft = ref(null);
const deleteDialog = ref(null);
const pendingDelete = ref(null);

const stages = computed(() => selected.value?.stages || []);
const hasPipelines = computed(() => pipelines.value.length > 0);

const selectedStage = computed(
  () => stages.value.find(stage => stage.id === selectedStageId.value) || null
);

const stageAutomations = computed(() =>
  automations.value.filter(
    automation => automation.resolution_state_id === selectedStageId.value
  )
);

const countFor = stage =>
  automations.value.filter(
    automation => automation.resolution_state_id === stage.id
  ).length;

const editing = computed(
  () =>
    newDraft.value ||
    automations.value.find(
      automation => automation.id === selectedAutomationId.value
    ) ||
    null
);

const loadAutomations = async () => {
  if (!selectedId.value) return;
  isLoadingList.value = true;
  try {
    const { data } = await PipelineAutomationsAPI.list(selectedId.value);
    automations.value = data.payload || [];
  } catch {
    useAlert(t('CRM_AUTOMATIONS.ALERTS.LOAD_ERROR'));
  } finally {
    isLoadingList.value = false;
  }
};

const selectStage = stageId => {
  selectedStageId.value = stageId;
  selectedAutomationId.value = null;
  newDraft.value = null;
};

const selectAutomation = automation => {
  newDraft.value = null;
  selectedAutomationId.value = automation.id;
};

const startNew = () => {
  selectedAutomationId.value = null;
  newDraft.value = newAutomation(selectedStageId.value);
};

const onSaved = async saved => {
  useAlert(t('CRM_AUTOMATIONS.ALERTS.SAVE_SUCCESS'));
  await loadAutomations();
  newDraft.value = null;
  selectedAutomationId.value = saved.id;
};

// Updated in place so the editor keeps whatever is being typed in the other rules.
const toggleActive = async (automation, active) => {
  try {
    await PipelineAutomationsAPI.updateAutomation(
      selectedId.value,
      automation.id,
      { active }
    );
    automation.active = active;
  } catch {
    useAlert(t('CRM_AUTOMATIONS.ALERTS.ACTIVE_ERROR'));
    await loadAutomations();
  }
};

const askDelete = automation => {
  pendingDelete.value = automation;
  deleteDialog.value.open();
};

const confirmDelete = async () => {
  const automation = pendingDelete.value;
  try {
    await PipelineAutomationsAPI.deleteAutomation(
      selectedId.value,
      automation.id
    );
    if (selectedAutomationId.value === automation.id) {
      selectedAutomationId.value = null;
    }
    useAlert(t('CRM_AUTOMATIONS.ALERTS.DELETE_SUCCESS'));
    await loadAutomations();
  } catch {
    useAlert(t('CRM_AUTOMATIONS.ALERTS.DELETE_ERROR'));
  } finally {
    deleteDialog.value.close();
    pendingDelete.value = null;
  }
};

// Covers both the first load (selection resolved) and switching pipelines.
watch(selected, pipeline => {
  automations.value = [];
  selectStage(pipeline?.stages?.[0]?.id || null);
  if (pipeline) loadAutomations();
});

onMounted(async () => {
  store.dispatch('inboxes/get');
  store.dispatch('teams/get');
  store.dispatch('agents/get');
  store.dispatch('labels/get');
  store.dispatch('attributes/get');
  try {
    await fetchPipelines();
  } catch {
    useAlert(t('CRM_AUTOMATIONS.ALERTS.LOAD_ERROR'));
  } finally {
    isReady.value = true;
  }
});
</script>

<template>
  <div class="flex flex-col w-full h-full overflow-y-auto bg-n-background">
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
      <span class="i-lucide-zap size-10 text-n-slate-10" />
      <h2 class="mb-0 text-base font-semibold text-n-slate-12">
        {{ $t('CRM_AUTOMATIONS.EMPTY.NO_PIPELINES_TITLE') }}
      </h2>
      <p class="max-w-md mb-0 text-sm text-n-slate-11">
        {{ $t('CRM_AUTOMATIONS.EMPTY.NO_PIPELINES_DESCRIPTION') }}
      </p>
      <router-link
        :to="{ name: 'conversation_workflow_index' }"
        class="text-sm font-medium text-n-blue-11 hover:underline"
      >
        {{ $t('CRM_AUTOMATIONS.EMPTY.NO_PIPELINES_ACTION') }}
      </router-link>
    </div>

    <template v-else>
      <div
        class="flex flex-wrap items-start justify-between gap-4 px-6 pt-6 pb-4"
      >
        <div class="flex flex-col gap-1 max-w-3xl">
          <h1 class="mb-0 text-xl font-semibold text-n-slate-12">
            {{ $t('CRM_AUTOMATIONS.HEADER.TITLE') }}
          </h1>
          <p class="mb-0 text-sm text-n-slate-11">
            {{ $t('CRM_AUTOMATIONS.HEADER.DESCRIPTION') }}
          </p>
        </div>
        <PipelineSelector
          :model-value="selectedId"
          :pipelines="pipelines"
          :label="$t('CRM_AUTOMATIONS.HEADER.PIPELINE_LABEL')"
          @update:model-value="select"
        />
      </div>

      <div class="flex gap-1 px-6 overflow-x-auto border-b border-n-weak">
        <button
          v-for="(stage, index) in stages"
          :key="stage.id"
          type="button"
          class="flex items-center gap-2 px-3 py-2.5 -mb-px text-sm border-b-2 whitespace-nowrap"
          :class="
            selectedStageId === stage.id
              ? 'border-n-brand text-n-slate-12 font-medium'
              : 'border-transparent text-n-slate-11 hover:text-n-slate-12'
          "
          @click="selectStage(stage.id)"
        >
          <span
            class="size-2.5 rounded-full shrink-0"
            :class="STAGE_DOT_CLASS[stageColor(stage, index)]"
          />
          {{ stage.display_label }}
          <span
            class="min-w-5 px-1.5 py-0.5 text-xs font-medium text-center rounded-full"
            :class="
              countFor(stage)
                ? 'bg-n-amber-3 text-n-amber-11'
                : 'bg-n-alpha-2 text-n-slate-11'
            "
          >
            {{ countFor(stage) }}
          </span>
        </button>
      </div>

      <div
        v-if="!selectedStage"
        class="flex items-center justify-center flex-1 p-8 text-sm text-n-slate-11"
      >
        {{ $t('CRM_AUTOMATIONS.EMPTY.NO_STAGE') }}
      </div>

      <div
        v-else
        class="grid items-start grid-cols-1 gap-4 p-6 lg:grid-cols-[340px_minmax(0,1fr)]"
      >
        <AutomationList
          :automations="stageAutomations"
          :selected-id="selectedAutomationId"
          :is-loading="isLoadingList"
          @select="selectAutomation"
          @create="startNew"
          @toggle-active="toggleActive"
          @remove="askDelete"
        />

        <AutomationEditor
          v-if="editing"
          :automation="editing"
          :stage="selectedStage"
          :pipeline-id="selectedId"
          :pipelines="pipelines"
          :inboxes="inboxes"
          :teams="teams"
          :agents="agents"
          :labels="labels"
          :attributes="attributes"
          @saved="onSaved"
        />
        <div
          v-else
          class="flex flex-col items-center justify-center gap-2 p-10 text-center border border-dashed rounded-xl border-n-weak"
        >
          <span class="i-lucide-mouse-pointer-click size-8 text-n-slate-10" />
          <p class="mb-0 text-sm font-medium text-n-slate-12">
            {{ $t('CRM_AUTOMATIONS.EMPTY.NO_SELECTION_TITLE') }}
          </p>
          <p class="max-w-sm mb-0 text-xs text-n-slate-11">
            {{ $t('CRM_AUTOMATIONS.EMPTY.NO_SELECTION_DESCRIPTION') }}
          </p>
        </div>
      </div>
    </template>

    <Dialog
      ref="deleteDialog"
      type="alert"
      :title="$t('CRM_AUTOMATIONS.DELETE.TITLE')"
      :description="
        $t('CRM_AUTOMATIONS.DELETE.DESCRIPTION', {
          name: pendingDelete?.name || '',
        })
      "
      :confirm-button-label="$t('CRM_AUTOMATIONS.DELETE.CONFIRM')"
      :cancel-button-label="$t('CRM_AUTOMATIONS.DELETE.CANCEL')"
      @confirm="confirmDelete"
    />
  </div>
</template>
