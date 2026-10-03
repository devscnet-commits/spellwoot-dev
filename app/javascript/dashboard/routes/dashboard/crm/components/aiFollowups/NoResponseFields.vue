<script setup>
import { useI18n } from 'vue-i18n';
import FlowSelect from 'dashboard/routes/dashboard/settings/operationalFlows/FlowSelect.vue';
import { NO_RESPONSE_ACTIONS } from './cadenceForm';

// "Se o cliente não responder após a última tentativa": the no-response action of the behavior
// plus the cadence-level inactivity time and closing message (shared by every context).
defineProps({
  behavior: { type: Object, required: true },
  stages: { type: Array, default: () => [] },
  errors: { type: Object, default: () => ({}) },
});

const emit = defineEmits(['update']);

const inactivityMinutes = defineModel('inactivityMinutes', {
  type: [Number, String],
  default: 30,
});
const closeMessage = defineModel('closeMessage', { type: String, default: '' });

const { t } = useI18n();

const actionLabel = action =>
  t(`CRM_AI_FOLLOWUPS.NO_RESPONSE.ACTIONS.${action}`);

// Native select values are strings; stage ids are numbers.
const onStageChange = value =>
  emit('update', { no_response_stage_id: Number(value) || '' });
</script>

<template>
  <section
    class="flex flex-col gap-3 p-4 rounded-xl border border-n-weak bg-n-solid-2"
  >
    <h3
      class="flex items-center gap-2 mb-0 text-sm font-semibold text-n-slate-12"
    >
      <span class="i-lucide-flag size-4 text-n-ruby-11" />
      {{ $t('CRM_AI_FOLLOWUPS.NO_RESPONSE.TITLE') }}
    </h3>

    <div class="grid gap-4 lg:grid-cols-2">
      <div class="flex flex-col gap-1">
        <span class="text-sm text-n-slate-12">
          {{ $t('CRM_AI_FOLLOWUPS.NO_RESPONSE.INACTIVITY_LABEL') }}
        </span>
        <input
          v-model="inactivityMinutes"
          type="number"
          min="0"
          class="w-32 h-10 px-3 text-sm rounded-lg border border-n-weak bg-n-solid-1 text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
        />
        <p class="mb-0 text-xs text-n-slate-11">
          {{ $t('CRM_AI_FOLLOWUPS.NO_RESPONSE.INACTIVITY_HINT') }}
        </p>
      </div>

      <div class="flex flex-col gap-1">
        <span class="text-sm text-n-slate-12">
          {{ $t('CRM_AI_FOLLOWUPS.NO_RESPONSE.ACTION_LABEL') }}
        </span>
        <FlowSelect
          :model-value="behavior.no_response_action"
          select-class="bg-n-solid-1"
          @update:model-value="emit('update', { no_response_action: $event })"
        >
          <option
            v-for="action in NO_RESPONSE_ACTIONS"
            :key="action"
            :value="action"
          >
            {{ actionLabel(action) }}
          </option>
        </FlowSelect>
        <p class="mb-0 text-xs text-n-slate-11">
          {{ $t('CRM_AI_FOLLOWUPS.NO_RESPONSE.ACTION_HINT') }}
        </p>
      </div>

      <div
        v-if="behavior.no_response_action === 'move_stage'"
        class="flex flex-col gap-1"
      >
        <span class="text-sm text-n-slate-12">
          {{ $t('CRM_AI_FOLLOWUPS.NO_RESPONSE.STAGE_LABEL') }}
        </span>
        <FlowSelect
          :model-value="behavior.no_response_stage_id"
          :select-class="
            errors.stage ? 'bg-n-solid-1 !border-n-ruby-8' : 'bg-n-solid-1'
          "
          @update:model-value="onStageChange"
        >
          <option value="" disabled>
            {{ $t('CRM_AI_FOLLOWUPS.NO_RESPONSE.STAGE_PLACEHOLDER') }}
          </option>
          <option v-for="stage in stages" :key="stage.id" :value="stage.id">
            {{ stage.display_label }}
          </option>
        </FlowSelect>
        <p v-if="errors.stage" class="mb-0 text-xs text-n-ruby-11">
          {{ errors.stage }}
        </p>
      </div>

      <label
        v-if="behavior.no_response_action === 'finalize'"
        class="flex flex-col gap-1 text-sm text-n-slate-12 lg:col-span-2"
      >
        {{ $t('CRM_AI_FOLLOWUPS.NO_RESPONSE.CLOSE_MESSAGE_LABEL') }}
        <textarea
          v-model="closeMessage"
          rows="3"
          class="px-3 py-2 text-sm rounded-lg border border-n-weak bg-n-solid-1 text-n-slate-12 resize-y focus:outline-none focus:ring-2 focus:ring-n-brand placeholder:text-n-slate-10"
          :placeholder="
            $t('CRM_AI_FOLLOWUPS.NO_RESPONSE.CLOSE_MESSAGE_PLACEHOLDER')
          "
        />
        <span class="text-xs text-n-slate-11">
          {{ $t('CRM_AI_FOLLOWUPS.NO_RESPONSE.CLOSE_MESSAGE_HINT') }}
        </span>
      </label>
    </div>
  </section>
</template>
