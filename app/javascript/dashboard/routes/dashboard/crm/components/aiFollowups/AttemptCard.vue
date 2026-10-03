<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import FlowSelect from 'dashboard/routes/dashboard/settings/operationalFlows/FlowSelect.vue';
import { UNITS, SENDERS, delayToMinutes } from './cadenceForm';

// One follow-up attempt of a behavior: inactivity trigger (delay + who spoke last) and the AI agent
// + prompt that write the message. Edits go up as patches; the parent owns the form.
const props = defineProps({
  attempt: { type: Object, required: true },
  index: { type: Number, required: true },
  agents: { type: Array, default: () => [] },
  errors: { type: Object, default: () => ({}) },
});

const emit = defineEmits(['update', 'duplicate', 'remove']);

const { t } = useI18n();

const update = patch => emit('update', patch);

const totalMinutes = computed(() => delayToMinutes(props.attempt));

const selectedAgent = computed(() =>
  props.agents.find(agent => agent.id === props.attempt.ai_agent_id)
);

const errorSelectClass = 'bg-n-solid-1 !border-n-ruby-8';

// Native select values are strings; agent ids are numbers.
const onAgentChange = value => update({ ai_agent_id: Number(value) || '' });

const unitLabel = unit => t(`CRM_AI_FOLLOWUPS.ATTEMPT.UNITS.${unit}`);
const senderLabel = sender => t(`CRM_AI_FOLLOWUPS.ATTEMPT.SENDERS.${sender}`);
const senderInfo = computed(() =>
  t(`CRM_AI_FOLLOWUPS.ATTEMPT.SENDER_INFO.${props.attempt.inactivity_sender}`)
);
</script>

<template>
  <article
    class="flex flex-col gap-4 p-4 rounded-xl border bg-n-solid-2"
    :class="attempt.active ? 'border-n-weak' : 'border-n-weak opacity-70'"
  >
    <div class="flex flex-wrap items-center gap-3">
      <span
        class="px-2 py-0.5 text-xs font-semibold rounded-md bg-n-violet-9/15 text-n-violet-11 shrink-0"
      >
        {{ $t('CRM_AI_FOLLOWUPS.ATTEMPT.NUMBER', { n: index + 1 }) }}
      </span>
      <input
        :value="attempt.name"
        type="text"
        class="flex-1 min-w-48 h-9 px-3 text-sm font-medium rounded-lg border border-n-weak bg-n-solid-1 text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand placeholder:text-n-slate-10"
        :placeholder="
          $t('CRM_AI_FOLLOWUPS.ATTEMPT.NAME_PLACEHOLDER', { n: index + 1 })
        "
        @input="update({ name: $event.target.value })"
      />
      <label
        class="flex items-center gap-2 text-sm text-n-slate-11 cursor-pointer select-none"
      >
        <input
          :checked="attempt.active"
          type="checkbox"
          class="size-4 rounded border-n-strong accent-n-brand"
          @change="update({ active: $event.target.checked })"
        />
        {{ $t('CRM_AI_FOLLOWUPS.ATTEMPT.ACTIVE') }}
      </label>
      <div class="flex items-center gap-1">
        <button
          v-tooltip.bottom="$t('CRM_AI_FOLLOWUPS.ATTEMPT.DUPLICATE')"
          type="button"
          class="p-1.5 rounded-md text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12"
          :aria-label="$t('CRM_AI_FOLLOWUPS.ATTEMPT.DUPLICATE')"
          @click="emit('duplicate')"
        >
          <span class="i-lucide-copy size-4 block" />
        </button>
        <button
          v-tooltip.bottom="$t('CRM_AI_FOLLOWUPS.ATTEMPT.REMOVE')"
          type="button"
          class="p-1.5 rounded-md text-n-slate-11 hover:bg-n-ruby-9/10 hover:text-n-ruby-11"
          :aria-label="$t('CRM_AI_FOLLOWUPS.ATTEMPT.REMOVE')"
          @click="emit('remove')"
        >
          <span class="i-lucide-trash-2 size-4 block" />
        </button>
      </div>
    </div>

    <div class="grid gap-4 lg:grid-cols-2">
      <!-- Trigger: silence since the last message, counted from the previous attempt after #1 -->
      <section
        class="flex flex-col gap-3 p-3 rounded-lg border border-n-weak bg-n-solid-1"
      >
        <h4
          class="flex items-center gap-2 mb-0 text-sm font-semibold text-n-slate-12"
        >
          <span class="i-lucide-timer size-4 text-n-amber-11" />
          {{ $t('CRM_AI_FOLLOWUPS.ATTEMPT.TRIGGER_TITLE') }}
        </h4>

        <div class="flex flex-col gap-1">
          <span class="text-sm text-n-slate-12">
            {{ $t('CRM_AI_FOLLOWUPS.ATTEMPT.DELAY_LABEL') }}
          </span>
          <div class="flex items-center gap-2">
            <input
              :value="attempt.delay_value"
              type="number"
              min="1"
              class="w-24 h-10 px-3 text-sm rounded-lg border bg-n-solid-2 text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
              :class="errors.delay ? 'border-n-ruby-8' : 'border-n-weak'"
              @input="update({ delay_value: $event.target.value })"
            />
            <FlowSelect
              :model-value="attempt.delay_unit"
              class="w-32"
              select-class="bg-n-solid-2"
              @update:model-value="update({ delay_unit: $event })"
            >
              <option
                v-for="unit in UNITS"
                :key="unit.value"
                :value="unit.value"
              >
                {{ unitLabel(unit.value) }}
              </option>
            </FlowSelect>
          </div>
          <p v-if="errors.delay" class="mb-0 text-xs text-n-ruby-11">
            {{ errors.delay }}
          </p>
          <p v-else class="mb-0 text-xs text-n-slate-11">
            {{
              index === 0
                ? $t('CRM_AI_FOLLOWUPS.ATTEMPT.EQUIVALENT', {
                    minutes: totalMinutes,
                  })
                : $t('CRM_AI_FOLLOWUPS.ATTEMPT.EQUIVALENT_NEXT', {
                    minutes: totalMinutes,
                  })
            }}
          </p>
        </div>

        <div class="flex flex-col gap-1">
          <span class="text-sm text-n-slate-12">
            {{ $t('CRM_AI_FOLLOWUPS.ATTEMPT.SENDER_LABEL') }}
          </span>
          <FlowSelect
            :model-value="attempt.inactivity_sender"
            select-class="bg-n-solid-2"
            @update:model-value="update({ inactivity_sender: $event })"
          >
            <option v-for="sender in SENDERS" :key="sender" :value="sender">
              {{ senderLabel(sender) }}
            </option>
          </FlowSelect>
          <p class="flex items-start gap-1.5 mb-0 text-xs text-n-slate-11">
            <span class="i-lucide-info size-3.5 mt-0.5 shrink-0" />
            {{ senderInfo }}
          </p>
        </div>
      </section>

      <!-- Who writes the message and how -->
      <section
        class="flex flex-col gap-3 p-3 rounded-lg border border-n-weak bg-n-solid-1"
      >
        <h4
          class="flex items-center gap-2 mb-0 text-sm font-semibold text-n-slate-12"
        >
          <span class="i-lucide-bot size-4 text-n-violet-11" />
          {{ $t('CRM_AI_FOLLOWUPS.ATTEMPT.AGENT_TITLE') }}
        </h4>

        <div class="flex flex-col gap-1">
          <span class="text-sm text-n-slate-12">
            {{ $t('CRM_AI_FOLLOWUPS.ATTEMPT.AGENT_LABEL') }}
          </span>
          <FlowSelect
            :model-value="attempt.ai_agent_id"
            :select-class="
              errors.ai_agent_id ? errorSelectClass : 'bg-n-solid-2'
            "
            @update:model-value="onAgentChange"
          >
            <option value="" disabled>
              {{ $t('CRM_AI_FOLLOWUPS.ATTEMPT.AGENT_PLACEHOLDER') }}
            </option>
            <option v-for="agent in agents" :key="agent.id" :value="agent.id">
              {{ agent.name }}
            </option>
          </FlowSelect>
          <p v-if="errors.ai_agent_id" class="mb-0 text-xs text-n-ruby-11">
            {{ errors.ai_agent_id }}
          </p>
          <p v-else-if="!agents.length" class="mb-0 text-xs text-n-amber-11">
            {{ $t('CRM_AI_FOLLOWUPS.ATTEMPT.AGENTS_EMPTY') }}
          </p>
          <p
            v-else-if="selectedAgent?.assistant_description"
            class="mb-0 text-xs text-n-slate-11"
          >
            <span class="font-medium text-n-slate-12">
              {{ $t('CRM_AI_FOLLOWUPS.ATTEMPT.AGENT_SPECIALTY') }}
            </span>
            {{ selectedAgent.assistant_description }}
          </p>
        </div>

        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('CRM_AI_FOLLOWUPS.ATTEMPT.PROMPT_LABEL') }}
          <textarea
            :value="attempt.prompt"
            rows="4"
            class="px-3 py-2 text-sm rounded-lg border border-n-weak bg-n-solid-2 text-n-slate-12 resize-y focus:outline-none focus:ring-2 focus:ring-n-brand placeholder:text-n-slate-10"
            :placeholder="$t('CRM_AI_FOLLOWUPS.ATTEMPT.PROMPT_PLACEHOLDER')"
            @input="update({ prompt: $event.target.value })"
          />
        </label>
        <p class="mb-0 text-xs text-n-slate-11">
          {{ $t('CRM_AI_FOLLOWUPS.ATTEMPT.PROMPT_HINT') }}
        </p>
      </section>
    </div>
  </article>
</template>
