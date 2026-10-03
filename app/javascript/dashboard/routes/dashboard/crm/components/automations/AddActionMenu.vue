<script setup>
import { ref } from 'vue';
import { OnClickOutside } from '@vueuse/components';
import Button from 'dashboard/components-next/button/Button.vue';
import { ACTIONS } from './automationForm';

// "+ Adicionar Ação ▾": dropdown with the actions a rule can run.
const emit = defineEmits(['select']);

const isOpen = ref(false);

const pick = name => {
  isOpen.value = false;
  emit('select', name);
};
</script>

<template>
  <OnClickOutside class="relative" @trigger="isOpen = false">
    <Button
      type="button"
      variant="faded"
      color="blue"
      size="sm"
      icon="i-lucide-plus"
      @click="isOpen = !isOpen"
    >
      <span class="min-w-0 truncate">{{
        $t('CRM_AUTOMATIONS.ACTIONS.ADD')
      }}</span>
      <span class="i-lucide-chevron-down size-3.5" />
    </Button>
    <div
      v-if="isOpen"
      class="absolute z-20 flex flex-col w-72 p-1 mt-1 overflow-y-auto border shadow-lg ltr:right-0 rtl:left-0 max-h-80 rounded-xl border-n-weak bg-n-solid-2"
    >
      <button
        v-for="action in ACTIONS"
        :key="action.name"
        type="button"
        class="flex items-center gap-2 px-2.5 py-2 text-sm text-left rounded-lg text-n-slate-12 hover:bg-n-alpha-2"
        @click="pick(action.name)"
      >
        <span :class="action.icon" class="size-4 text-n-slate-11 shrink-0" />
        {{ $t(`CRM_AUTOMATIONS.ACTIONS.NAMES.${action.name}`) }}
      </button>
    </div>
  </OnClickOutside>
</template>
