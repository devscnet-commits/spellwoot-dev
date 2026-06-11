<script setup>
import { ref, computed, watch } from 'vue';
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
// reload); fall back to the native result column. Stored value is the state's canonical key.
const outcome = computed(() => {
  const legacy = currentChat.value?.additional_attributes?.outcome;
  if (legacy && legacy !== 'ai_closed') return legacy;
  const result = currentChat.value?.result;
  return result && result !== 'none' ? result : null;
});

// The caixa's closing flow defines the selectable states and their editable labels;
// fetched once per conversation and reused by selectOutcome.
const closingFlow = ref(null);
const closingFlowForId = ref(null);

const ensureClosingFlow = async () => {
  const id = currentChat.value?.id;
  if (!id) return null;
  if (closingFlowForId.value === id) return closingFlow.value;
  try {
    const ConversationApi = (await import('dashboard/api/inbox/conversation'))
      .default;
    const { data } = await ConversationApi.getClosingFlow(id);
    closingFlow.value = data || null;
  } catch {
    closingFlow.value = null;
  }
  closingFlowForId.value = id;
  return closingFlow.value;
};

watch(() => currentChat.value?.id, ensureClosingFlow, { immediate: true });

// Polarity drives color/icon regardless of the editable label, mirroring ResolveAction.
const POLARITY_STYLE = {
  positive: {
    icon: 'i-lucide-circle-check',
    colorClass: 'text-n-teal-11',
    bgClass: 'bg-n-teal-3',
    hoverClass: 'hover:bg-n-teal-3',
  },
  negative: {
    icon: 'i-lucide-circle-x',
    colorClass: 'text-n-ruby-11',
    bgClass: 'bg-n-ruby-3',
    hoverClass: 'hover:bg-n-ruby-3',
  },
  neutral: {
    icon: 'i-lucide-circle-dot',
    colorClass: 'text-n-slate-11',
    bgClass: 'bg-n-slate-3',
    hoverClass: 'hover:bg-n-alpha-black2',
  },
};

const NONE_OPTION = {
  key: null,
  label: null,
  icon: 'i-lucide-minus-circle',
  colorClass: 'text-n-slate-9',
  bgClass: 'bg-n-slate-3',
  hoverClass: 'hover:bg-n-alpha-black2',
};

const resultOptions = computed(() => {
  const states = closingFlow.value?.resolution_states;
  if (states?.length) {
    return [
      ...[...states]
        .sort((a, b) => a.sort_order - b.sort_order)
        .map(s => ({
          key: s.canonical_key,
          label: s.display_label,
          stateId: s.id,
          ...(POLARITY_STYLE[s.polarity] || POLARITY_STYLE.neutral),
        })),
      NONE_OPTION,
    ];
  }
  return [
    { key: 'won', label: null, ...POLARITY_STYLE.positive },
    { key: 'lost', label: null, ...POLARITY_STYLE.negative },
    NONE_OPTION,
  ];
});

const currentResult = computed(
  () =>
    resultOptions.value.find(o => o.key === outcome.value) ||
    resultOptions.value[resultOptions.value.length - 1]
);

const labelFor = option => {
  if (option.label) return option.label;
  if (option.key === 'won')
    return t('CONVERSATION_WORKFLOW.OUTCOME.RESULT_WON');
  if (option.key === 'lost')
    return t('CONVERSATION_WORKFLOW.OUTCOME.RESULT_LOST');
  return t('CONVERSATION_WORKFLOW.OUTCOME.RESULT_NONE');
};

// Chip label for a set result: the pinned state's CURRENT label (renames inside the same
// flow update history), then the text snapshot taken at closing time (state/flow gone),
// then the live lookup against the caixa's flow (conversations closed before pinning).
const allFlows = useMapGetter('operationalFlows/getFlows');
// Flows (with their states) are needed to resolve pinned labels; fetch once if absent.
if (!(allFlows.value || []).length) store.dispatch('operationalFlows/get');
const pinnedStateLabel = computed(() => {
  const stateId = currentChat.value?.additional_attributes?.outcome_state_id;
  if (!stateId) return null;
  return (
    (allFlows.value || [])
      .flatMap(flow => flow.resolution_states || [])
      .find(st => st.id === stateId)?.display_label || null
  );
});

const chipLabel = computed(() => {
  if (!outcome.value) return labelFor(currentResult.value);
  return (
    pinnedStateLabel.value ||
    currentChat.value?.additional_attributes?.outcome_label ||
    labelFor(currentResult.value)
  );
});

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
    // The chip prefers the dual-written additional_attributes.outcome, so the local copy
    // must be refreshed too — otherwise the stale legacy value keeps the old label on screen.
    const additionalAttributes = {
      ...(currentChat.value.additional_attributes || {}),
    };
    const chosen = resultOptions.value.find(o => o.key === outcomeKey);
    if (outcomeKey) {
      additionalAttributes.outcome = outcomeKey;
      if (chosen?.label) additionalAttributes.outcome_label = chosen.label;
      else delete additionalAttributes.outcome_label;
      if (chosen?.stateId)
        additionalAttributes.outcome_state_id = chosen.stateId;
      else delete additionalAttributes.outcome_state_id;
    } else {
      delete additionalAttributes.outcome;
      delete additionalAttributes.outcome_label;
      delete additionalAttributes.outcome_state_id;
    }

    await store.dispatch('updateConversation', {
      ...currentChat.value,
      result: outcomeKey || 'none',
      additional_attributes: additionalAttributes,
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
  const flow = await ensureClosingFlow();
  isLoading.value = false;

  const currentCustomAttributes = currentChat.value.custom_attributes || {};
  const flowAttrs = flowRequiredAttributes(
    flow,
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
      class="flex items-center gap-1.5 h-10 px-3 rounded-lg text-sm font-medium transition-opacity"
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
      :title="
        isResolved ? $t('CONVERSATION_WORKFLOW.OUTCOME.RESULT_LOCKED') : null
      "
      @click="isDropdownOpen = !isDropdownOpen"
    >
      <span class="size-3.5" :class="[currentResult.icon]" />
      {{ chipLabel }}
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
        v-for="option in resultOptions"
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
        {{ labelFor(option) }}
      </button>
    </div>

    <ConversationResolveAttributesModal
      ref="resolveAttributesModalRef"
      @submit="handleOutcomeAttributes"
    />
  </div>
</template>
