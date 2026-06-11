<script setup>
import { ref, computed } from 'vue';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import {
  useStore,
  useStoreGetters,
  useMapGetter,
} from 'dashboard/composables/store';
import { useEmitter } from 'dashboard/composables/emitter';
import { useKeyboardEvents } from 'dashboard/composables/useKeyboardEvents';

import wootConstants from 'dashboard/constants/globals';
import {
  CMD_REOPEN_CONVERSATION,
  CMD_RESOLVE_CONVERSATION,
} from 'dashboard/helper/commandbar/events';
import {
  flowRequiredAttributes,
  SYSTEM_OUTCOME_FIELD,
  OUTCOME_TO_SYSTEM_VALUE,
  isAttrVisible,
} from 'dashboard/components-next/ConversationWorkflow/constants';
import { useConversationRequiredAttributes } from 'dashboard/composables/useConversationRequiredAttributes';

import ButtonGroup from 'dashboard/components-next/buttonGroup/ButtonGroup.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import ConversationResolveAttributesModal from 'dashboard/components-next/ConversationWorkflow/ConversationResolveAttributesModal.vue';
import ConversationOutcomeButtons from 'dashboard/components-next/ConversationWorkflow/ConversationOutcomeButtons.vue';

const store = useStore();
const getters = useStoreGetters();
const { t } = useI18n();
const { requiredAttributes: accountRequiredAttributes } =
  useConversationRequiredAttributes();

const isLoading = ref(false);
const resolveAttributesModalRef = ref(null);
const outcomeButtonsRef = ref(null);
const showOutcomePrompt = ref(false);
const closingFlow = ref(null);

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

const missingFrom = (attrs, customAttributes) =>
  attrs.filter(a => {
    const value = customAttributes[a.value];
    if (a.type === 'checkbox') return !(a.value in customAttributes);
    return value == null || String(value).trim() === '';
  });

const currentChat = computed(() => getters.getSelectedChat.value);

// Polarity drives the button color/icon regardless of the editable label.
const POLARITY_STYLE = {
  positive: { color: 'teal', icon: 'i-lucide-circle-check' },
  negative: { color: 'ruby', icon: 'i-lucide-circle-x' },
  neutral: { color: 'slate', icon: 'i-lucide-circle-dot' },
};

// Resolution states from the resolved closing flow, with a legacy won/lost fallback when the
// conversation has no flow.
const outcomeStates = computed(() => {
  const states = closingFlow.value?.resolution_states;
  if (states?.length) {
    return [...states]
      .sort((a, b) => a.sort_order - b.sort_order)
      .map(s => ({
        outcome: s.canonical_key,
        label: s.display_label,
        stateId: s.id,
        ...(POLARITY_STYLE[s.polarity] || POLARITY_STYLE.neutral),
      }));
  }
  return [
    {
      outcome: 'won',
      label: t('CONVERSATION_WORKFLOW.OUTCOME.MARK_WON'),
      ...POLARITY_STYLE.positive,
    },
    {
      outcome: 'lost',
      label: t('CONVERSATION_WORKFLOW.OUTCOME.MARK_LOST'),
      ...POLARITY_STYLE.negative,
    },
  ];
});

const fetchClosingFlow = async () => {
  try {
    const ConversationApi = (await import('dashboard/api/inbox/conversation'))
      .default;
    const { data } = await ConversationApi.getClosingFlow(currentChat.value.id);
    closingFlow.value = data || null;
  } catch {
    closingFlow.value = null;
  }
};

const isOpen = computed(
  () => currentChat.value.status === wootConstants.STATUS_TYPE.OPEN
);

const isResolved = computed(
  () => currentChat.value.status === wootConstants.STATUS_TYPE.RESOLVED
);

const wasHandledByHuman = computed(
  () => !!currentChat.value?.additional_attributes?.was_handled_by_human
);

const outcomeAlreadySet = computed(() => {
  const legacy = currentChat.value?.additional_attributes?.outcome;
  if (legacy === 'won' || legacy === 'lost') return true;
  const result = currentChat.value?.result;
  return !!result && result !== 'none';
});

const getConversationParams = () => {
  const allConversations = document.querySelectorAll(
    '.conversations-list .conversation'
  );
  const activeConversation = document.querySelector(
    'div.conversations-list div.conversation.active'
  );
  const activeConversationIndex = [...allConversations].indexOf(
    activeConversation
  );
  return {
    all: allConversations,
    activeIndex: activeConversationIndex,
    lastIndex: allConversations.length - 1,
  };
};

const toggleStatus = (status, snoozedUntil, customAttributes = null) => {
  isLoading.value = true;
  const payload = {
    conversationId: currentChat.value.id,
    status,
    snoozedUntil,
  };
  if (customAttributes) payload.customAttributes = customAttributes;
  store.dispatch('toggleStatus', payload).then(() => {
    useAlert(t('CONVERSATION.CHANGE_STATUS'));
    isLoading.value = false;
  });
};

const closeAsAi = async () => {
  isLoading.value = true;
  try {
    const ConversationApi = (await import('dashboard/api/inbox/conversation'))
      .default;
    await ConversationApi.closeAsAi(currentChat.value.id);
    await store.dispatch('updateConversation', {
      ...currentChat.value,
      status: wootConstants.STATUS_TYPE.RESOLVED,
      closed_by_ai: true,
    });
    useAlert(t('CONVERSATION.CHANGE_STATUS'));
  } catch {
    useAlert(t('CONVERSATION_WORKFLOW.OUTCOME.ERROR'));
  } finally {
    isLoading.value = false;
  }
};

const handleResolveWithAttributes = ({ attributes, context, resolve }) => {
  if (!context) return;
  const mergedAttributes = {
    ...(currentChat.value.custom_attributes || {}),
    ...attributes,
  };
  // "Salvar" only persists the attributes and keeps the conversation open.
  if (resolve === false) {
    store.dispatch('updateCustomAttributes', {
      conversationId: currentChat.value.id,
      customAttributes: mergedAttributes,
    });
    useAlert(t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.MODAL.SAVED'));
    return;
  }
  toggleStatus(
    wootConstants.STATUS_TYPE.RESOLVED,
    context.snoozedUntil,
    mergedAttributes
  );
};

const onCmdOpenConversation = () => {
  toggleStatus(wootConstants.STATUS_TYPE.OPEN);
};

const onCmdResolveConversation = async () => {
  // AI-only conversation with no manual outcome → close as ai_closed.
  // If an agent already picked Won/Lost, respect it instead of overwriting with ai_closed.
  if (!wasHandledByHuman.value && !outcomeAlreadySet.value) {
    closeAsAi();
    return;
  }

  // Human handled but no outcome yet → prompt for the flow's resolution states
  if (!outcomeAlreadySet.value) {
    fetchClosingFlow();
    showOutcomePrompt.value = true;
    return;
  }

  // Outcome already set → collect the required attributes for that outcome — the flow's
  // closing requirements plus the account-level ones (always + conditional) — then resolve.
  const currentCustomAttributes = currentChat.value.custom_attributes || {};
  const legacy = currentChat.value.additional_attributes?.outcome;
  const result = currentChat.value.result;
  const picked = legacy === 'won' || legacy === 'lost' ? legacy : result;
  const outcome = picked === 'won' || picked === 'lost' ? picked : null;

  await fetchClosingFlow();
  const flowAttrs = flowRequiredAttributes(
    closingFlow.value,
    outcome,
    attributeOptions.value
  );
  const seen = new Set(flowAttrs.map(a => a.value));
  const allAttrs = [
    ...flowAttrs,
    ...accountRequiredAttributes.value.filter(a => !seen.has(a.value)),
  ];
  // Conditional account rules only count when their condition matches the current context.
  const conditionContext = {
    ...currentCustomAttributes,
    [SYSTEM_OUTCOME_FIELD]: OUTCOME_TO_SYSTEM_VALUE[outcome] ?? null,
  };
  const applicableAttrs = allAttrs.filter(a =>
    isAttrVisible(a, conditionContext)
  );
  const missing = missingFrom(applicableAttrs, currentCustomAttributes);

  if (missing.length) {
    resolveAttributesModalRef.value?.open(allAttrs, currentCustomAttributes, {
      id: currentChat.value.id,
      snoozedUntil: null,
      outcome,
    });
  } else {
    toggleStatus(wootConstants.STATUS_TYPE.RESOLVED);
  }
};

const onSelectState = state => {
  showOutcomePrompt.value = false;
  // Render the flow's required attributes for the chosen state in the modal (empty = none).
  const flowAttrs = flowRequiredAttributes(
    closingFlow.value,
    state.outcome,
    attributeOptions.value
  );
  outcomeButtonsRef.value?.openOutcome({
    outcome: state.outcome,
    label: state.label,
    statusValue: state.label,
    attributes: flowAttrs,
    outcomeLabel: closingFlow.value?.resolution_states?.length
      ? state.label
      : null,
    outcomeStateId: state.stateId || null,
  });
};

const keyboardEvents = {
  'Alt+KeyE': { action: () => onCmdResolveConversation() },
  '$mod+Alt+KeyE': {
    action: event => {
      const { all, activeIndex, lastIndex } = getConversationParams();
      onCmdResolveConversation();
      if (activeIndex < lastIndex) all[activeIndex + 1].click();
      else if (all.length > 1) {
        all[0].click();
        document.querySelector('.conversations-list').scrollTop = 0;
      }
      event.preventDefault();
    },
  },
};

useKeyboardEvents(keyboardEvents);
useEmitter(CMD_REOPEN_CONVERSATION, onCmdOpenConversation);
useEmitter(CMD_RESOLVE_CONVERSATION, onCmdResolveConversation);
</script>

<template>
  <div class="flex relative justify-end items-center resolve-actions">
    <!-- Hidden outcome buttons used programmatically when prompted -->
    <ConversationOutcomeButtons ref="outcomeButtonsRef" class="hidden" />

    <!-- Outcome prompt overlay -->
    <div
      v-if="showOutcomePrompt"
      class="absolute bottom-full mb-2 right-0 z-50 flex flex-col gap-2 p-3 rounded-xl bg-n-solid-3 shadow-lg border border-n-weak min-w-48"
    >
      <p class="text-body-small text-n-slate-11 mb-1">
        {{ $t('CONVERSATION_WORKFLOW.OUTCOME.PROMPT_RESOLVE') }}
      </p>
      <Button
        v-for="state in outcomeStates"
        :key="state.outcome"
        size="sm"
        :color="state.color"
        :icon="state.icon"
        :label="state.label"
        class="w-full rounded-md"
        @click="onSelectState(state)"
      />
      <Button
        size="sm"
        variant="ghost"
        color="slate"
        icon="i-lucide-minus-circle"
        :label="$t('CONVERSATION_WORKFLOW.OUTCOME.MARK_NO_RESULT')"
        class="w-full rounded-md"
        @click="
          () => {
            showOutcomePrompt = false;
            toggleStatus(wootConstants.STATUS_TYPE.RESOLVED);
          }
        "
      />
    </div>

    <ButtonGroup
      class="flex-shrink-0 rounded-lg shadow outline-1 outline outline-n-container"
    >
      <Button
        v-if="isOpen"
        :label="t('CONVERSATION.HEADER.RESOLVE_ACTION')"
        size="md"
        color="slate"
        no-animation
        :is-loading="isLoading"
        @click="onCmdResolveConversation"
      />
      <Button
        v-else-if="isResolved"
        :label="t('CONVERSATION.HEADER.REOPEN_ACTION')"
        size="md"
        color="slate"
        no-animation
        :is-loading="isLoading"
        @click="onCmdOpenConversation"
      />
    </ButtonGroup>

    <ConversationResolveAttributesModal
      ref="resolveAttributesModalRef"
      @submit="handleResolveWithAttributes"
    />
  </div>
</template>
