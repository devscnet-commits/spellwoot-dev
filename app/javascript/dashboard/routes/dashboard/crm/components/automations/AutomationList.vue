<script setup>
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import { triggerSummary } from './automationForm';

// Left column of the page: the rules of the selected stage, with the active checkbox and delete.
defineProps({
  automations: { type: Array, default: () => [] },
  selectedId: { type: Number, default: null },
  isLoading: { type: Boolean, default: false },
});

const emit = defineEmits(['select', 'create', 'toggleActive', 'remove']);

const { t } = useI18n();
</script>

<template>
  <div class="flex flex-col border rounded-xl border-n-weak bg-n-solid-1">
    <div
      class="flex items-center justify-between gap-2 px-4 py-3 border-b border-n-weak"
    >
      <h3 class="mb-0 text-sm font-semibold text-n-slate-12">
        {{ $t('CRM_AUTOMATIONS.LIST.TITLE', { count: automations.length }) }}
      </h3>
      <Button
        type="button"
        size="sm"
        icon="i-lucide-plus"
        :label="$t('CRM_AUTOMATIONS.LIST.NEW')"
        @click="emit('create')"
      />
    </div>

    <div v-if="isLoading" class="flex items-center justify-center p-8">
      <Spinner class="text-n-slate-11" />
    </div>

    <div
      v-else-if="!automations.length"
      class="flex flex-col items-center gap-2 p-8 text-center"
    >
      <span class="i-lucide-zap size-8 text-n-slate-10" />
      <p class="mb-0 text-sm font-medium text-n-slate-12">
        {{ $t('CRM_AUTOMATIONS.EMPTY.NO_RULES') }}
      </p>
      <p class="mb-0 text-xs text-n-slate-11">
        {{ $t('CRM_AUTOMATIONS.EMPTY.NO_RULES_HINT') }}
      </p>
    </div>

    <ul v-else class="flex flex-col mb-0 divide-y divide-n-weak">
      <li
        v-for="automation in automations"
        :key="automation.id"
        class="flex items-start gap-3 px-4 py-3 cursor-pointer"
        :class="
          selectedId === automation.id ? 'bg-n-brand/10' : 'hover:bg-n-alpha-1'
        "
        @click="emit('select', automation)"
      >
        <input
          v-tooltip.top="$t('CRM_AUTOMATIONS.LIST.ACTIVE_TOGGLE')"
          type="checkbox"
          :checked="automation.active"
          class="mt-1 rounded cursor-pointer size-4 border-n-strong accent-n-brand shrink-0"
          @click.stop
          @change="emit('toggleActive', automation, $event.target.checked)"
        />
        <div class="flex flex-col flex-1 min-w-0 gap-0.5">
          <p
            class="mb-0 text-sm font-medium truncate"
            :class="automation.active ? 'text-n-slate-12' : 'text-n-slate-11'"
          >
            {{ automation.name }}
            <span
              v-if="!automation.active"
              class="text-xs font-normal text-n-slate-10"
            >
              {{ $t('CRM_AUTOMATIONS.LIST.INACTIVE') }}
            </span>
          </p>
          <p class="mb-0 text-xs truncate text-n-slate-11">
            {{ triggerSummary(automation, t) }}
          </p>
          <p class="mb-0 text-xs text-n-slate-10">
            {{
              $t(
                'CRM_AUTOMATIONS.LIST.ACTIONS_COUNT',
                { count: automation.actions.length },
                automation.actions.length
              )
            }}
          </p>
        </div>
        <Button
          v-tooltip.top="$t('CRM_AUTOMATIONS.LIST.DELETE')"
          type="button"
          variant="ghost"
          color="ruby"
          size="sm"
          icon="i-lucide-trash-2"
          @click.stop="emit('remove', automation)"
        />
      </li>
    </ul>
  </div>
</template>
