<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import PipelineAutomationsAPI from 'dashboard/api/pipelineAutomations';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TriggerPicker from './TriggerPicker.vue';
import ConditionRow from './ConditionRow.vue';
import ActionCard from './ActionCard.vue';
import AddActionMenu from './AddActionMenu.vue';
import {
  newCondition,
  newAction,
  validateAutomation,
  validateConditions,
  toPayload,
} from './automationForm';

// Right column of the page: edits a copy of the selected (or new) rule, simulates it against the
// cards now in the stage and saves it; the page reloads the list on `saved`.
const props = defineProps({
  automation: { type: Object, required: true },
  stage: { type: Object, required: true },
  pipelineId: { type: Number, required: true },
  pipelines: { type: Array, default: () => [] },
  inboxes: { type: Array, default: () => [] },
  teams: { type: Array, default: () => [] },
  agents: { type: Array, default: () => [] },
  labels: { type: Array, default: () => [] },
  attributes: { type: Array, default: () => [] },
});

const emit = defineEmits(['saved']);

const { t } = useI18n();

const MATCH_TYPES = ['all', 'any'];
const NO_ERRORS = () => ({ conditions: {}, actions: {} });

// Stable keys for the condition/action rows (index keys would mix up rows on removal).
let uid = 0;
const nextKey = () => {
  uid += 1;
  return uid;
};
const withKeys = list =>
  (list || []).map(item => ({ ...item, _key: nextKey() }));

// Deep copy: nested action_params (and label arrays) must not stay shared with the list item.
const clone = automation => {
  const copy = JSON.parse(JSON.stringify(automation));
  return {
    ...copy,
    conditions: withKeys(copy.conditions),
    actions: withKeys(copy.actions),
  };
};

const draft = ref(clone(props.automation));
const errors = ref(NO_ERRORS());
const simulation = ref(null);
const isSaving = ref(false);
const isSimulating = ref(false);

const isNew = computed(() => !draft.value.id);

const reset = () => {
  draft.value = clone(props.automation);
  errors.value = NO_ERRORS();
  simulation.value = null;
};

watch(() => props.automation, reset);

// Once a save attempt flagged fields, keep the messages current while the user fixes them.
watch(
  draft,
  () => {
    if (errors.value.any) {
      errors.value = validateAutomation(draft.value, props.inboxes);
    } else if (Object.keys(errors.value.conditions).length) {
      errors.value = {
        ...errors.value,
        conditions: validateConditions(draft.value.conditions),
      };
    }
  },
  { deep: true }
);

// The simulation describes the conditions it ran with: drop it when they really change (the trigger
// picker replaces the whole draft object, which must not count).
watch(
  () => JSON.stringify([draft.value.conditions, draft.value.match_type]),
  () => {
    simulation.value = null;
  }
);

const addCondition = () =>
  draft.value.conditions.push({ ...newCondition(), _key: nextKey() });

const removeCondition = index => draft.value.conditions.splice(index, 1);

const addAction = name =>
  draft.value.actions.push({
    ...newAction(name, { pipelineId: props.pipelineId }),
    _key: nextKey(),
  });

const removeAction = index => draft.value.actions.splice(index, 1);

const moveAction = (index, offset) => {
  const [action] = draft.value.actions.splice(index, 1);
  draft.value.actions.splice(index + offset, 0, action);
};

// Only the conditions matter to a simulation; the name and actions may still be unfinished.
const simulate = async () => {
  const conditionErrors = validateConditions(draft.value.conditions);
  if (Object.keys(conditionErrors).length) {
    errors.value = { ...errors.value, conditions: conditionErrors };
    return;
  }
  isSimulating.value = true;
  try {
    const { data } = await PipelineAutomationsAPI.simulate(
      props.pipelineId,
      toPayload(draft.value)
    );
    simulation.value = data;
  } catch {
    useAlert(t('CRM_AUTOMATIONS.EDITOR.SIMULATION_ERROR'));
  } finally {
    isSimulating.value = false;
  }
};

const save = async () => {
  errors.value = validateAutomation(draft.value, props.inboxes);
  if (errors.value.any) {
    useAlert(t('CRM_AUTOMATIONS.EDITOR.FIX_ERRORS'));
    return;
  }
  isSaving.value = true;
  try {
    const payload = toPayload(draft.value);
    const { data } = draft.value.id
      ? await PipelineAutomationsAPI.updateAutomation(
          props.pipelineId,
          draft.value.id,
          payload
        )
      : await PipelineAutomationsAPI.createAutomation(
          props.pipelineId,
          payload
        );
    emit('saved', data);
  } catch (error) {
    useAlert(
      error.response?.data?.error || t('CRM_AUTOMATIONS.EDITOR.SAVE_ERROR')
    );
  } finally {
    isSaving.value = false;
  }
};
</script>

<template>
  <div
    class="flex flex-col gap-6 p-5 border rounded-xl border-n-weak bg-n-solid-1"
  >
    <div class="flex flex-col gap-3">
      <span class="text-xs font-medium uppercase text-n-slate-10">
        {{
          isNew
            ? $t('CRM_AUTOMATIONS.EDITOR.NEW_TITLE')
            : $t('CRM_AUTOMATIONS.EDITOR.EDIT_TITLE')
        }}
      </span>
      <div class="flex flex-wrap items-start gap-3">
        <Input
          v-model="draft.name"
          class="flex-1 min-w-64"
          :label="$t('CRM_AUTOMATIONS.EDITOR.NAME_LABEL')"
          :placeholder="$t('CRM_AUTOMATIONS.EDITOR.NAME_PLACEHOLDER')"
          :message="
            errors.name
              ? $t(`CRM_AUTOMATIONS.EDITOR.ERRORS.${errors.name}`)
              : ''
          "
          :message-type="errors.name ? 'error' : 'info'"
        />
        <div class="flex items-center gap-2 pt-7">
          <Button
            type="button"
            variant="outline"
            color="slate"
            icon="i-lucide-play"
            :label="$t('CRM_AUTOMATIONS.EDITOR.SIMULATE')"
            :is-loading="isSimulating"
            @click="simulate"
          />
          <Button
            type="button"
            icon="i-lucide-save"
            :label="$t('CRM_AUTOMATIONS.EDITOR.SAVE')"
            :is-loading="isSaving"
            @click="save"
          />
        </div>
      </div>

      <div
        v-if="simulation"
        class="flex flex-col gap-1 p-3 text-sm border rounded-lg"
        :class="
          simulation.matched
            ? 'border-n-teal-6 bg-n-teal-3/40 text-n-slate-12'
            : 'border-n-amber-6 bg-n-amber-3/40 text-n-slate-12'
        "
      >
        <p class="mb-0 font-medium">
          {{
            $t('CRM_AUTOMATIONS.EDITOR.SIMULATION_RESULT', {
              matched: simulation.matched,
              total: simulation.total,
            })
          }}
        </p>
        <p v-if="!simulation.total" class="mb-0 text-xs text-n-slate-11">
          {{ $t('CRM_AUTOMATIONS.EDITOR.SIMULATION_EMPTY_STAGE') }}
        </p>
        <p v-else-if="!simulation.matched" class="mb-0 text-xs text-n-slate-11">
          {{ $t('CRM_AUTOMATIONS.EDITOR.SIMULATION_NONE') }}
        </p>
        <div
          v-else
          class="flex flex-wrap items-center gap-1.5 text-xs text-n-slate-11"
        >
          <span>{{ $t('CRM_AUTOMATIONS.EDITOR.SIMULATION_SAMPLES') }}</span>
          <span
            v-for="sample in simulation.samples"
            :key="sample.id"
            class="px-1.5 py-0.5 rounded-md bg-n-alpha-2 text-n-slate-12"
          >
            {{ sample.name }}
          </span>
        </div>
      </div>
    </div>

    <TriggerPicker v-model="draft" :error="errors.trigger" />

    <section class="flex flex-col gap-3">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <h3 class="mb-0 text-sm font-semibold text-n-slate-12">
          {{ $t('CRM_AUTOMATIONS.CONDITIONS.TITLE') }}
        </h3>
        <Button
          type="button"
          variant="faded"
          color="blue"
          size="sm"
          icon="i-lucide-plus"
          :label="$t('CRM_AUTOMATIONS.CONDITIONS.ADD')"
          @click="addCondition"
        />
      </div>

      <div class="flex flex-wrap items-center gap-2 text-sm text-n-slate-11">
        <span>{{ $t('CRM_AUTOMATIONS.CONDITIONS.LOGIC_LABEL') }}</span>
        <div
          class="flex items-center gap-1 p-1 border rounded-lg border-n-weak bg-n-solid-2"
        >
          <button
            v-for="matchType in MATCH_TYPES"
            :key="matchType"
            type="button"
            class="px-2.5 py-1 text-xs font-medium rounded-md"
            :class="
              draft.match_type === matchType
                ? 'bg-n-brand/10 text-n-blue-11'
                : 'text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12'
            "
            @click="draft.match_type = matchType"
          >
            {{
              matchType === 'all'
                ? $t('CRM_AUTOMATIONS.CONDITIONS.MATCH_ALL')
                : $t('CRM_AUTOMATIONS.CONDITIONS.MATCH_ANY')
            }}
          </button>
        </div>
      </div>

      <p v-if="!draft.conditions.length" class="mb-0 text-xs text-n-slate-11">
        {{ $t('CRM_AUTOMATIONS.CONDITIONS.EMPTY') }}
      </p>
      <ConditionRow
        v-for="(condition, index) in draft.conditions"
        :key="condition._key"
        v-model="draft.conditions[index]"
        :labels="labels"
        :teams="teams"
        :agents="agents"
        :attributes="attributes"
        :error="errors.conditions[index] || ''"
        @remove="removeCondition(index)"
      />
    </section>

    <section class="flex flex-col gap-3">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <h3 class="mb-0 text-sm font-semibold text-n-slate-12">
          {{
            $t('CRM_AUTOMATIONS.ACTIONS.TITLE', { stage: stage.display_label })
          }}
        </h3>
        <AddActionMenu @select="addAction" />
      </div>
      <p class="mb-0 text-xs text-n-slate-11">
        {{ $t('CRM_AUTOMATIONS.ACTIONS.ORDER_HINT') }}
      </p>
      <p v-if="errors.actionsList" class="mb-0 text-xs text-n-ruby-9">
        {{ $t(`CRM_AUTOMATIONS.ACTIONS.ERRORS.${errors.actionsList}`) }}
      </p>
      <p
        v-if="!draft.actions.length"
        class="p-4 mb-0 text-sm text-center border border-dashed rounded-xl border-n-weak text-n-slate-11"
      >
        {{ $t('CRM_AUTOMATIONS.ACTIONS.EMPTY') }}
      </p>
      <ActionCard
        v-for="(action, index) in draft.actions"
        :key="action._key"
        v-model="draft.actions[index]"
        :index="index"
        :total="draft.actions.length"
        :error="errors.actions[index] || ''"
        :pipelines="pipelines"
        :current-pipeline-id="pipelineId"
        :inboxes="inboxes"
        :teams="teams"
        :agents="agents"
        :labels="labels"
        @remove="removeAction(index)"
        @move-up="moveAction(index, -1)"
        @move-down="moveAction(index, 1)"
      />
    </section>
  </div>
</template>
