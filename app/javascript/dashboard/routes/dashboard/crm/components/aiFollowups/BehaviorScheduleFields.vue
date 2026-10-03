<script setup>
import { computed } from 'vue';
import { CONTEXTS, activeAttemptsCount } from './cadenceForm';

// "Quando esta cadência vale": one pill per schedule context (the selected one is edited below)
// plus the HH:MM windows of the custom context. Windows are patched through events so the parent
// form stays the single owner of the state.
const props = defineProps({
  behaviors: { type: Array, required: true },
  behavior: { type: Object, required: true },
  error: { type: String, default: '' },
});

const emit = defineEmits(['addWindow', 'removeWindow', 'updateWindow']);

const context = defineModel({ type: String, default: 'inbox_hours' });

const CONTEXT_ICONS = {
  inbox_hours: 'i-lucide-sun',
  outside_hours: 'i-lucide-moon',
  custom: 'i-lucide-clock',
};

const pills = computed(() =>
  CONTEXTS.map(value => ({
    value,
    icon: CONTEXT_ICONS[value],
    count: activeAttemptsCount(
      props.behaviors.filter(behavior => behavior.context === value)
    ),
  }))
);
</script>

<template>
  <section
    class="flex flex-col gap-3 p-4 rounded-xl border border-n-weak bg-n-solid-2"
  >
    <div class="flex flex-col gap-0.5">
      <h3 class="mb-0 text-sm font-semibold text-n-slate-12">
        {{ $t('CRM_AI_FOLLOWUPS.SCHEDULE.TITLE') }}
      </h3>
      <p class="mb-0 text-xs text-n-slate-11">
        {{ $t('CRM_AI_FOLLOWUPS.SCHEDULE.HINT') }}
      </p>
    </div>

    <div class="flex flex-wrap gap-2">
      <button
        v-for="pill in pills"
        :key="pill.value"
        type="button"
        class="flex items-center gap-2 px-3 py-1.5 text-sm rounded-lg border"
        :class="
          context === pill.value
            ? 'border-n-brand bg-n-brand/10 text-n-slate-12'
            : 'border-n-weak bg-n-solid-1 text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12'
        "
        @click="context = pill.value"
      >
        <span :class="pill.icon" class="size-4" />
        {{ $t(`CRM_AI_FOLLOWUPS.SCHEDULE.CONTEXTS.${pill.value}`) }}
        <span
          v-if="pill.count"
          class="px-1.5 py-0.5 text-xs font-medium rounded-full bg-n-violet-9/15 text-n-violet-11"
        >
          {{ pill.count }}
        </span>
      </button>
    </div>

    <div v-if="behavior.context === 'custom'" class="flex flex-col gap-2">
      <span class="text-sm font-medium text-n-slate-12">
        {{ $t('CRM_AI_FOLLOWUPS.SCHEDULE.WINDOWS_TITLE') }}
      </span>
      <p v-if="!behavior.windows.length" class="mb-0 text-xs text-n-slate-11">
        {{ $t('CRM_AI_FOLLOWUPS.SCHEDULE.WINDOWS_EMPTY') }}
      </p>
      <div
        v-for="(window, index) in behavior.windows"
        :key="window.uid"
        class="flex items-center gap-2"
      >
        <input
          :value="window.start"
          type="time"
          class="h-10 px-3 text-sm rounded-lg border border-n-weak bg-n-solid-1 text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
          @input="emit('updateWindow', index, { start: $event.target.value })"
        />
        <span class="text-sm text-n-slate-11">
          {{ $t('CRM_AI_FOLLOWUPS.SCHEDULE.WINDOW_TO') }}
        </span>
        <input
          :value="window.end"
          type="time"
          class="h-10 px-3 text-sm rounded-lg border border-n-weak bg-n-solid-1 text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
          @input="emit('updateWindow', index, { end: $event.target.value })"
        />
        <button
          type="button"
          class="shrink-0 text-n-slate-11 hover:text-n-ruby-11"
          :aria-label="$t('CRM_AI_FOLLOWUPS.SCHEDULE.WINDOW_REMOVE')"
          @click="emit('removeWindow', index)"
        >
          <span class="i-lucide-x size-4 block" />
        </button>
      </div>
      <p v-if="error" class="mb-0 text-xs text-n-ruby-11">{{ error }}</p>
      <button
        type="button"
        class="flex items-center self-start gap-1 text-sm font-medium text-n-blue-11 hover:underline"
        @click="emit('addWindow')"
      >
        <span class="i-lucide-plus size-3.5" />
        {{ $t('CRM_AI_FOLLOWUPS.SCHEDULE.WINDOW_ADD') }}
      </button>
    </div>
  </section>
</template>
