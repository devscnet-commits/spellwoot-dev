<script setup>
import { ref, computed } from 'vue';
import { useI18n } from 'vue-i18n';
import {
  useStore,
  useStoreGetters,
  useMapGetter,
} from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { vOnClickOutside } from '@vueuse/components';
import wootConstants from 'dashboard/constants/globals';
import ConversationResolveAttributesModal from './ConversationResolveAttributesModal.vue';
import {
  flowRequiredAttributes,
  SYSTEM_OUTCOME_FIELD,
  OUTCOME_TO_SYSTEM_VALUE,
  isAttrVisible,
} from './constants';
import { useConversationRequiredAttributes } from 'dashboard/composables/useConversationRequiredAttributes';

const store = useStore();
const getters = useStoreGetters();
const { t } = useI18n();
const { requiredAttributes: accountRequiredAttributes } =
  useConversationRequiredAttributes();

const conversationAttributes = useMapGetter(
  'attributes/getConversationAttributes'
);
const attributeOptions = computed(() =>
  (conversationAttributes.value || []).map(a => ({
    value: a.attributeKey,
    label: a.attributeDisplayName,
    type: a.attributeDisplayType,
    attributeValues: a.attributeValues,
  }))
);

const currentChat = computed(() => getters.getSelectedChat.value);
const isDropdownOpen = ref(false);
const isLoading = ref(false);

// A resolved conversation's result is locked: the status can only change after reopening.
// Reflect that visually so it reads as non-editable until the conversation is reopened.
const isResolved = computed(
  () => currentChat.value?.status === wootConstants.STATUS_TYPE.RESOLVED
);

// Prefer the dual-written additional_attributes.outcome (reliably preserved by the store on
// reload); fall back to the native result column. Only won/lost are selectable values here.
const outcome = computed(() => {
  const legacy = currentChat.value?.additional_attributes?.outcome;
  if (legacy === 'won' || legacy === 'lost') return legacy;
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

const resolveAttributesModalRef = ref(null);

const persistOutcome = async (outcomeKey, customAttributes = null) => {
  isLoading.value = true;
  try {
    const ConversationApi = (await import('dashboard/api/inbox/conversation'))
      .default;
    await ConversationApi.setOutcome({
      conversationId: currentChat.value.id,
      outcome: outcomeKey,
      customAttributes,
    });
    await store.dispatch('updateConversation', {
      ...currentChat.value,
      result: outcomeKey || 'none',
      custom_attributes: {
        ...(currentChat.value.custom_attributes || {}),
        ...(customAttributes || {}),
      },
    });
    useAlert(t('CONVERSATION_WORKFLOW.OUTCOME.RESULT_UPDATED'));
  } catch {
    useAlert(t('CONVERSATION_WORKFLOW.OUTCOME.ERROR'));
  } finally {
    isLoading.value = false;
  }
};

// Marking a result is gated like closing: collect the flow's requirements for the chosen state
// plus the account-level required attributes, prompt for whatever is missing, then persist.
const selectOutcome = async outcomeKey => {
  if (isLoading.value || outcomeKey === outcome.value) {
    isDropdownOpen.value = false;
    return;
  }
  isDropdownOpen.value = false;

  if (!outcomeKey) {
    persistOutcome(outcomeKey);
    return;
  }

  isLoading.value = true;
  let closingFlow = null;
  try {
    const ConversationApi = (await import('dashboard/api/inbox/conversation'))
      .default;
    const { data } = await ConversationApi.getClosingFlow(currentChat.value.id);
    closingFlow = data || null;
  } catch {
    closingFlow = null;
  } finally {
    isLoading.value = false;
  }

  const currentCustomAttributes = currentChat.value.custom_attributes || {};
  const flowAttrs = flowRequiredAttributes(
    closingFlow,
    outcomeKey,
    attributeOptions.value
  );
  const seen = new Set(flowAttrs.map(a => a.value));
  const allAttrs = [
    ...flowAttrs,
    ...accountRequiredAttributes.value.filter(a => !seen.has(a.value)),
  ];
  const conditionContext = {
    ...currentCustomAttributes,
    [SYSTEM_OUTCOME_FIELD]: OUTCOME_TO_SYSTEM_VALUE[outcomeKey] ?? null,
  };
  const missing = allAttrs.filter(a => {
    if (!isAttrVisible(a, conditionContext)) return false;
    const value = currentCustomAttributes[a.value];
    if (a.type === 'checkbox') return !(a.value in currentCustomAttributes);
    return value == null || String(value).trim() === '';
  });

  if (missing.length) {
    resolveAttributesModalRef.value?.open(allAttrs, currentCustomAttributes, {
      outcome: outcomeKey,
    });
  } else {
    persistOutcome(outcomeKey);
  }
};

// "Salvar" keeps the conversation open (result + attributes + Meta);
// "Salvar e resolver" additionally resolves it right away.
const handleOutcomeAttributes = async ({ attributes, context, resolve }) => {
  if (!context?.outcome) return;
  await persistOutcome(context.outcome, attributes);
  if (resolve) {
    await store.dispatch('toggleStatus', {
      conversationId: currentChat.value.id,
      status: wootConstants.STATUS_TYPE.RESOLVED,
      snoozedUntil: null,
    });
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
      class="flex items-center gap-1.5 px-3 py-1.5 rounded-md text-sm font-medium transition-opacity"
      :class="[
        isResolved
          ? 'bg-n-slate-2 text-n-slate-9 cursor-not-allowed'
          : [
              currentResult.bgClass,
              currentResult.colorClass,
              isLoading ? 'opacity-50 cursor-not-allowed' : 'hover:opacity-80',
            ],
      ]"
      :disabled="isLoading || isResolved"
      :title="isResolved ? $t('CONVERSATION_WORKFLOW.OUTCOME.RESULT_LOCKED') : null"
      @click="isDropdownOpen = !isDropdownOpen"
    >
      <span class="size-3.5" :class="[currentResult.icon]" />
      {{ labelFor(currentResult.key) }}
      <span
        v-if="!isResolved"
        class="i-lucide-chevron-down size-3 opacity-70"
      />
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

    <ConversationResolveAttributesModal
      ref="resolveAttributesModalRef"
      @submit="handleOutcomeAttributes"
    />
  </div>
</template>
