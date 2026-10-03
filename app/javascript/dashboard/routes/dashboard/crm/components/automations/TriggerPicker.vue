<script setup>
import { ref, watch } from 'vue';
import FlowSelect from 'dashboard/routes/dashboard/settings/operationalFlows/FlowSelect.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import {
  TRIGGER_TYPES,
  INACTIVITY_SENDERS,
  DELAY_UNITS,
  splitMinutes,
  toMinutes,
} from './automationForm';

// Section 1 of the editor: the trigger card (stage entered / time in stage / inactivity) and the
// inputs each one needs. Edits are emitted as a patched copy of the automation.
defineProps({
  error: { type: String, default: '' },
});

const model = defineModel({ type: Object, required: true });

// Sensible starting delays when a timed trigger is picked with no time yet.
const DEFAULT_DELAY = { time_in_stage: 5, inactivity: 60 };

const set = patch => {
  model.value = { ...model.value, ...patch };
};

// The delay is edited as value + unit but stored in minutes.
const delay = ref(splitMinutes(model.value.delay_minutes));

watch(
  () => model.value.delay_minutes,
  minutes => {
    if (toMinutes(delay.value.value, delay.value.unit) !== minutes) {
      delay.value = splitMinutes(minutes);
    }
  }
);

const updateDelay = patch => {
  delay.value = { ...delay.value, ...patch };
  set({ delay_minutes: toMinutes(delay.value.value, delay.value.unit) });
};

const selectTrigger = type => {
  const patch = { trigger_type: type };
  if (type !== 'stage_entered' && !model.value.delay_minutes) {
    patch.delay_minutes = DEFAULT_DELAY[type];
  }
  set(patch);
};
</script>

<template>
  <section class="flex flex-col gap-3">
    <h3 class="mb-0 text-sm font-semibold text-n-slate-12">
      {{ $t('CRM_AUTOMATIONS.TRIGGER.TITLE') }}
    </h3>

    <div class="grid grid-cols-1 gap-3 md:grid-cols-3">
      <button
        v-for="trigger in TRIGGER_TYPES"
        :key="trigger.value"
        type="button"
        class="flex flex-col items-start gap-2 p-3 text-left rounded-xl border transition-colors"
        :class="
          model.trigger_type === trigger.value
            ? 'border-n-blue-8 bg-n-brand/10'
            : 'border-n-weak bg-n-solid-1 hover:bg-n-alpha-2'
        "
        @click="selectTrigger(trigger.value)"
      >
        <span
          :class="[
            trigger.icon,
            model.trigger_type === trigger.value
              ? 'text-n-blue-11'
              : 'text-n-slate-11',
          ]"
          class="size-5"
        />
        <span class="text-sm font-medium text-n-slate-12">
          {{ $t(`CRM_AUTOMATIONS.TRIGGER.TYPES.${trigger.value}.TITLE`) }}
        </span>
        <span class="text-xs text-n-slate-11">
          {{ $t(`CRM_AUTOMATIONS.TRIGGER.TYPES.${trigger.value}.DESCRIPTION`) }}
        </span>
      </button>
    </div>

    <div
      v-if="model.trigger_type !== 'stage_entered'"
      class="flex flex-col gap-3 p-3 rounded-lg bg-n-alpha-1"
    >
      <div class="flex flex-wrap items-center gap-2 text-sm text-n-slate-11">
        <span class="shrink-0">
          {{
            model.trigger_type === 'inactivity'
              ? $t('CRM_AUTOMATIONS.TRIGGER.INACTIVITY_LABEL')
              : $t('CRM_AUTOMATIONS.TRIGGER.DELAY_LABEL')
          }}
        </span>
        <Input
          :model-value="delay.value"
          type="number"
          min="1"
          class="w-24"
          @update:model-value="updateDelay({ value: $event })"
        />
        <FlowSelect
          :model-value="delay.unit"
          class="w-36"
          select-class="bg-n-solid-2"
          @update:model-value="updateDelay({ unit: $event })"
        >
          <option
            v-for="unit in DELAY_UNITS"
            :key="unit.value"
            :value="unit.value"
          >
            {{ $t(`CRM_AUTOMATIONS.TRIGGER.UNITS.${unit.value}`) }}
          </option>
        </FlowSelect>
      </div>

      <label
        v-if="model.trigger_type === 'inactivity'"
        class="flex flex-col gap-1 text-sm text-n-slate-11"
      >
        <span>{{ $t('CRM_AUTOMATIONS.TRIGGER.SENDER_LABEL') }}</span>
        <FlowSelect
          :model-value="model.inactivity_sender"
          class="max-w-md"
          select-class="bg-n-solid-2"
          @update:model-value="set({ inactivity_sender: $event })"
        >
          <option
            v-for="sender in INACTIVITY_SENDERS"
            :key="sender"
            :value="sender"
          >
            {{ $t(`CRM_AUTOMATIONS.TRIGGER.SENDERS.${sender}`) }}
          </option>
        </FlowSelect>
      </label>

      <p v-if="error" class="mb-0 text-xs text-n-ruby-9">
        {{ $t(`CRM_AUTOMATIONS.TRIGGER.ERRORS.${error}`) }}
      </p>
    </div>
  </section>
</template>
