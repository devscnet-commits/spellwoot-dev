<script setup>
import { computed, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import PipelineAiFollowupsAPI from 'dashboard/api/pipelineAiFollowups';
import Button from 'dashboard/components-next/button/Button.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import BehaviorScheduleFields from './BehaviorScheduleFields.vue';
import AttemptCard from './AttemptCard.vue';
import NoResponseFields from './NoResponseFields.vue';
import {
  blankAttempt,
  blankWindow,
  cadencePayload,
  delayToMinutes,
  hydrateCadence,
  nextUid,
} from './cadenceForm';

// Editor of the AI follow-up cadence of one stage: created on the first save, updated after. The
// parent re-mounts it per stage (key), so the form is hydrated once from the saved cadence.
const props = defineProps({
  pipeline: { type: Object, required: true },
  stage: { type: Object, required: true },
  stages: { type: Array, default: () => [] },
  cadence: { type: Object, default: null },
  agents: { type: Array, default: () => [] },
});

const emit = defineEmits(['saved', 'deleted']);

const { t } = useI18n();

const HINTS = ['REPLACES', 'FUTURE_SILENCE', 'RESTART', 'TAKES_BACK'];

const form = reactive(hydrateCadence(props.cadence));
const firstConfigured = form.behaviors.find(b => b.attempts.length);
const selectedContext = ref(firstConfigured?.context || 'inbox_hours');
const isSaving = ref(false);
const isDeleting = ref(false);
// Inline errors only after the first save attempt, so a fresh attempt is not red on arrival.
const showErrors = ref(false);
const deleteDialog = ref(null);

const behavior = computed(() =>
  form.behaviors.find(b => b.context === selectedContext.value)
);
const attempts = computed(() => behavior.value.attempts);

// Errors keyed by attempt/behavior uid; computed so they clear as the user fixes the fields.
const errors = computed(() => {
  const result = {};
  form.behaviors.forEach(b => {
    if (!b.attempts.length) return;
    b.attempts.forEach(attempt => {
      const attemptErrors = {};
      // An agent deactivated since the last save is no longer offered: it has to be re-chosen.
      const agentKnown = props.agents.some(a => a.id === attempt.ai_agent_id);
      if (!attempt.ai_agent_id || (props.agents.length && !agentKnown)) {
        attemptErrors.ai_agent_id = t('CRM_AI_FOLLOWUPS.ERRORS.AGENT_REQUIRED');
      }
      if (delayToMinutes(attempt) < 1) {
        attemptErrors.delay = t('CRM_AI_FOLLOWUPS.ERRORS.DELAY_REQUIRED');
      }
      if (Object.keys(attemptErrors).length)
        result[attempt.uid] = attemptErrors;
    });
    const behaviorErrors = {};
    if (b.context === 'custom' && b.windows.some(w => !w.start || !w.end)) {
      behaviorErrors.windows = t('CRM_AI_FOLLOWUPS.ERRORS.WINDOW_REQUIRED');
    }
    if (b.no_response_action === 'move_stage' && !b.no_response_stage_id) {
      behaviorErrors.stage = t('CRM_AI_FOLLOWUPS.ERRORS.STAGE_REQUIRED');
    }
    if (Object.keys(behaviorErrors).length) result[b.uid] = behaviorErrors;
  });
  return result;
});
const errorsFor = uid => (showErrors.value && errors.value[uid]) || {};
const hasAttempts = computed(() => form.behaviors.some(b => b.attempts.length));

const addAttempt = () => {
  const n = attempts.value.length + 1;
  attempts.value.push(
    blankAttempt({ name: t('CRM_AI_FOLLOWUPS.ATTEMPT.DEFAULT_NAME', { n }) })
  );
};
const patchAttempt = (attempt, patch) => Object.assign(attempt, patch);
const duplicateAttempt = index => {
  const source = attempts.value[index];
  attempts.value.splice(index + 1, 0, {
    ...source,
    uid: nextUid(),
    name: `${source.name} ${t('CRM_AI_FOLLOWUPS.ATTEMPT.COPY_SUFFIX')}`.trim(),
  });
};
const removeAttempt = index => attempts.value.splice(index, 1);

const patchBehavior = patch => Object.assign(behavior.value, patch);
const addWindow = () => behavior.value.windows.push(blankWindow());
const removeWindow = index => behavior.value.windows.splice(index, 1);
const updateWindow = (index, patch) =>
  Object.assign(behavior.value.windows[index], patch);

const applySaved = cadence => {
  Object.assign(form, hydrateCadence(cadence));
  showErrors.value = false;
};

const save = async () => {
  if (!hasAttempts.value) {
    useAlert(t('CRM_AI_FOLLOWUPS.ERRORS.NO_ATTEMPTS'));
    return;
  }
  showErrors.value = true;
  if (Object.keys(errors.value).length) {
    // Jump to the first context with a problem so the inline errors are visible.
    const broken = form.behaviors.find(
      b => errors.value[b.uid] || b.attempts.some(a => errors.value[a.uid])
    );
    if (broken) selectedContext.value = broken.context;
    useAlert(t('CRM_AI_FOLLOWUPS.ERRORS.VALIDATION'));
    return;
  }

  isSaving.value = true;
  try {
    const payload = cadencePayload(form, props.stage.id);
    const { data } = form.id
      ? await PipelineAiFollowupsAPI.updateCadence(
          props.pipeline.id,
          form.id,
          payload
        )
      : await PipelineAiFollowupsAPI.createCadence(props.pipeline.id, payload);
    applySaved(data);
    emit('saved', data);
    useAlert(t('CRM_AI_FOLLOWUPS.EDITOR.SAVE_SUCCESS'));
  } catch (error) {
    useAlert(
      error?.response?.data?.message || t('CRM_AI_FOLLOWUPS.EDITOR.SAVE_ERROR')
    );
  } finally {
    isSaving.value = false;
  }
};

const remove = async () => {
  isDeleting.value = true;
  try {
    await PipelineAiFollowupsAPI.deleteCadence(props.pipeline.id, form.id);
    const removedId = form.id;
    applySaved(null);
    deleteDialog.value?.close();
    emit('deleted', removedId);
    useAlert(t('CRM_AI_FOLLOWUPS.EDITOR.DELETE_SUCCESS'));
  } catch {
    useAlert(t('CRM_AI_FOLLOWUPS.EDITOR.DELETE_ERROR'));
  } finally {
    isDeleting.value = false;
  }
};
</script>

<template>
  <section
    class="flex flex-col gap-5 p-5 rounded-xl border border-n-weak bg-n-solid-1"
  >
    <div class="flex flex-wrap items-center gap-3">
      <div class="flex flex-col flex-1 min-w-0 gap-2">
        <h2
          class="flex items-center gap-2 mb-0 text-base font-semibold text-n-slate-12"
        >
          <span class="i-lucide-sparkles size-4 text-n-violet-11 shrink-0" />
          {{
            $t('CRM_AI_FOLLOWUPS.EDITOR.TITLE', { stage: stage.display_label })
          }}
        </h2>
        <div class="flex flex-wrap items-center gap-4 text-sm">
          <label class="flex items-center gap-2 text-n-slate-11 cursor-pointer">
            <Switch v-model="form.active" />
            <span :class="form.active ? 'text-n-slate-12' : ''">
              {{ $t('CRM_AI_FOLLOWUPS.EDITOR.ACTIVE') }}
            </span>
          </label>
          <button
            v-if="form.id"
            type="button"
            class="text-n-ruby-11 hover:underline"
            @click="deleteDialog.open()"
          >
            {{ $t('CRM_AI_FOLLOWUPS.EDITOR.REMOVE') }}
          </button>
        </div>
      </div>
      <Button
        type="button"
        variant="outline"
        color="slate"
        icon="i-lucide-plus"
        :label="$t('CRM_AI_FOLLOWUPS.EDITOR.ADD_ATTEMPT')"
        @click="addAttempt"
      />
      <Button
        type="button"
        icon="i-lucide-save"
        :label="$t('CRM_AI_FOLLOWUPS.EDITOR.SAVE')"
        :is-loading="isSaving"
        :disabled="isSaving"
        @click="save"
      />
    </div>

    <ul class="flex flex-col gap-1 pl-0 mb-0 list-none">
      <li
        v-for="hint in HINTS"
        :key="hint"
        class="flex items-start gap-2 text-xs text-n-slate-11"
      >
        <span class="i-lucide-info size-3.5 mt-0.5 shrink-0 text-n-slate-10" />
        {{ $t(`CRM_AI_FOLLOWUPS.EDITOR.HINTS.${hint}`) }}
      </li>
    </ul>

    <BehaviorScheduleFields
      v-model="selectedContext"
      :behaviors="form.behaviors"
      :behavior="behavior"
      :error="errorsFor(behavior.uid).windows || ''"
      @add-window="addWindow"
      @remove-window="removeWindow"
      @update-window="updateWindow"
    />

    <div
      v-if="!attempts.length"
      class="flex flex-col items-center gap-3 px-6 py-10 text-center rounded-xl border border-dashed border-n-strong"
    >
      <span class="i-lucide-message-square-dashed size-8 text-n-slate-10" />
      <div class="flex flex-col gap-1">
        <span class="text-sm font-medium text-n-slate-12">
          {{ $t('CRM_AI_FOLLOWUPS.EMPTY.NO_ATTEMPTS_TITLE') }}
        </span>
        <span class="text-xs text-n-slate-11">
          {{ $t('CRM_AI_FOLLOWUPS.EMPTY.NO_ATTEMPTS_DESCRIPTION') }}
        </span>
      </div>
      <Button
        type="button"
        variant="faded"
        size="sm"
        icon="i-lucide-plus"
        :label="$t('CRM_AI_FOLLOWUPS.EMPTY.NO_ATTEMPTS_ACTION')"
        @click="addAttempt"
      />
    </div>

    <template v-else>
      <template v-for="(attempt, index) in attempts" :key="attempt.uid">
        <AttemptCard
          :attempt="attempt"
          :index="index"
          :agents="agents"
          :errors="errorsFor(attempt.uid)"
          @update="patch => patchAttempt(attempt, patch)"
          @duplicate="duplicateAttempt(index)"
          @remove="removeAttempt(index)"
        />
        <div
          v-if="index < attempts.length - 1"
          class="flex justify-center -my-2"
        >
          <span
            class="flex items-center gap-2 px-3 py-1 text-xs font-medium rounded-full bg-n-amber-9/10 text-n-amber-11"
          >
            {{ $t('CRM_AI_FOLLOWUPS.ATTEMPT.NEXT_PILL') }}
            <span class="i-lucide-arrow-down size-3.5" />
          </span>
        </div>
      </template>

      <NoResponseFields
        v-model:inactivity-minutes="form.inactivity_minutes"
        v-model:close-message="form.close_message"
        :behavior="behavior"
        :stages="stages"
        :errors="errorsFor(behavior.uid)"
        @update="patchBehavior"
      />
    </template>

    <Dialog
      ref="deleteDialog"
      type="alert"
      :title="$t('CRM_AI_FOLLOWUPS.EDITOR.DELETE_DIALOG.TITLE')"
      :description="
        $t('CRM_AI_FOLLOWUPS.EDITOR.DELETE_DIALOG.DESCRIPTION', {
          stage: stage.display_label,
        })
      "
      :confirm-button-label="
        $t('CRM_AI_FOLLOWUPS.EDITOR.DELETE_DIALOG.CONFIRM')
      "
      :is-loading="isDeleting"
      @confirm="remove"
    />
  </section>
</template>
