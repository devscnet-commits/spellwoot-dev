<script setup>
import { ref, computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore, useStoreGetters } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { vOnClickOutside } from '@vueuse/components';

const store = useStore();
const getters = useStoreGetters();
const { t } = useI18n();

const currentChat = computed(() => getters.getSelectedChat.value);
const isDropdownOpen = ref(false);
const isLoading = ref(false);

// Read the first-class result column; only won/lost are selectable values here.
const outcome = computed(() => {
  const result = currentChat.value?.result;
  return result === 'won' || result === 'lost' ? result : null;
});

const RESULT_OPTIONS = [
  {
    key: 'won',
    icon: 'i-lucide-circle-check',
    colorClass: 'text-n-teal-11',
    bgClass: 'bg-n-teal-3',
    hoverClass: 'hover:bg-n-teal-3',
  },
  {
    key: 'lost',
    icon: 'i-lucide-circle-x',
    colorClass: 'text-n-ruby-11',
    bgClass: 'bg-n-ruby-3',
    hoverClass: 'hover:bg-n-ruby-3',
  },
  {
    key: null,
    icon: 'i-lucide-minus-circle',
    colorClass: 'text-n-slate-9',
    bgClass: 'bg-n-slate-3',
    hoverClass: 'hover:bg-n-alpha-black2',
  },
];

const currentResult = computed(
  () => RESULT_OPTIONS.find(o => o.key === outcome.value) || RESULT_OPTIONS[2]
);

const labelFor = key => {
  if (key === 'won') return t('CONVERSATION_WORKFLOW.OUTCOME.RESULT_WON');
  if (key === 'lost') return t('CONVERSATION_WORKFLOW.OUTCOME.RESULT_LOST');
  return t('CONVERSATION_WORKFLOW.OUTCOME.RESULT_NONE');
};

const selectOutcome = async outcomeKey => {
  if (isLoading.value || outcomeKey === outcome.value) {
    isDropdownOpen.value = false;
    return;
  }
  isDropdownOpen.value = false;
  isLoading.value = true;
  try {
    const ConversationApi = (await import('dashboard/api/inbox/conversation'))
      .default;
    await ConversationApi.setOutcome({
      conversationId: currentChat.value.id,
      outcome: outcomeKey,
    });
    await store.dispatch('updateConversation', {
      ...currentChat.value,
      result: outcomeKey || 'none',
    });
    useAlert(t('CONVERSATION_WORKFLOW.OUTCOME.RESULT_UPDATED'));
  } catch {
    useAlert(t('CONVERSATION_WORKFLOW.OUTCOME.ERROR'));
  } finally {
    isLoading.value = false;
  }
};
</script>

<template>
  <div
    v-if="currentChat"
    v-on-click-outside="() => (isDropdownOpen = false)"
    class="relative"
  >
    <button
      type="button"
      class="flex items-center gap-1.5 px-2 py-1 rounded-md text-xs font-medium transition-opacity"
      :class="[
        currentResult.bgClass,
        currentResult.colorClass,
        isLoading ? 'opacity-50 cursor-not-allowed' : 'hover:opacity-80',
      ]"
      :disabled="isLoading"
      @click="isDropdownOpen = !isDropdownOpen"
    >
      <span class="size-3.5" :class="[currentResult.icon]" />
      {{ labelFor(currentResult.key) }}
      <span class="i-lucide-chevron-down size-3 opacity-70" />
    </button>

    <div
      v-if="isDropdownOpen"
      class="absolute top-full mt-1 right-0 z-50 flex flex-col gap-0.5 p-1 rounded-lg border border-n-weak bg-n-solid-1 shadow-lg min-w-36"
    >
      <button
        v-for="option in RESULT_OPTIONS"
        :key="String(option.key)"
        type="button"
        class="flex items-center gap-2 w-full px-3 py-2 rounded-md text-sm transition-colors text-left"
        :class="[
          outcome === option.key
            ? [option.bgClass, option.colorClass, 'font-medium']
            : ['text-n-slate-12', option.hoverClass],
        ]"
        @click="selectOutcome(option.key)"
      >
        <span
          class="size-4 shrink-0"
          :class="[option.icon, option.colorClass]"
        />
        {{ labelFor(option.key) }}
      </button>
    </div>
  </div>
</template>
