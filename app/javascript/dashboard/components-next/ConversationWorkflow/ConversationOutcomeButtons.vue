<script setup>
import { ref, computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore, useStoreGetters } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useAccount } from 'dashboard/composables/useAccount';
import { useConversationRequiredAttributes } from 'dashboard/composables/useConversationRequiredAttributes';
import Button from 'dashboard/components-next/button/Button.vue';
import ConversationOutcomeModal from './ConversationOutcomeModal.vue';
import wootConstants from 'dashboard/constants/globals';
import { SYSTEM_OUTCOME_FIELD, OUTCOME_TO_SYSTEM_VALUE } from './constants';

const store = useStore();
const getters = useStoreGetters();
const { t } = useI18n();
const { currentAccount } = useAccount();
const { requiredAttributes } = useConversationRequiredAttributes();

const currentChat = computed(() => getters.getSelectedChat.value);
const outcomeModalRef = ref(null);
const pendingStatusSeed = ref({});

const metaSettings = computed(
  () => currentAccount.value?.settings?.meta_conversion_settings || {}
);

const isOnCloseStrategy = computed(
  () => metaSettings.value.strategy === 'on_close'
);

const outcomeAlreadySet = computed(() => {
  const result = currentChat.value?.result;
  return !!result && result !== 'none';
});

// Show buttons on all open conversations without outcome set
const showButtons = computed(
  () => currentChat.value?.status === wootConstants.STATUS_TYPE.OPEN && !outcomeAlreadySet.value
);

const winValue = computed(() => metaSettings.value.win_value || 'Ganho');
const lossValue = computed(() => metaSettings.value.loss_value || 'Perdido');
const winStatusField = computed(
  () => metaSettings.value.win_status_field || 'marcado_como_ganho_ou_perdido'
);

const hasCtwaClid = computed(
  () =>
    !!currentChat.value?.custom_attributes?.ctwa_clid ||
    !!currentChat.value?.additional_attributes?.attribution?.ctwa_clid
);

const buildInitialValues = (statusValue, outcome) => {
  const base = { ...(currentChat.value?.custom_attributes || {}) };
  if (winStatusField.value) {
    base[winStatusField.value] = statusValue;
  }
  // Inject system field so resultado_conversa conditions evaluate correctly in the modal
  base[SYSTEM_OUTCOME_FIELD] = OUTCOME_TO_SYSTEM_VALUE[outcome] ?? null;
  return base;
};

const openWon = () => {
  const initialValues = buildInitialValues(winValue.value, 'won');
  pendingStatusSeed.value = winStatusField.value
    ? { [winStatusField.value]: winValue.value }
    : {};
  outcomeModalRef.value?.open({
    outcome: 'won',
    label: t('CONVERSATION_WORKFLOW.OUTCOME.MARK_WON'),
    statusValue: winValue.value,
    attributes: requiredAttributes.value,
    initialValues,
  });
};

const openLost = () => {
  const initialValues = buildInitialValues(lossValue.value, 'lost');
  pendingStatusSeed.value = winStatusField.value
    ? { [winStatusField.value]: lossValue.value }
    : {};
  outcomeModalRef.value?.open({
    outcome: 'lost',
    label: t('CONVERSATION_WORKFLOW.OUTCOME.MARK_LOST'),
    statusValue: lossValue.value,
    attributes: requiredAttributes.value,
    initialValues,
  });
};

const handleOutcomeConfirm = async ({ outcome, customAttributes }) => {
  try {
    const ConversationApi = (await import('dashboard/api/inbox/conversation'))
      .default;
    // Merge the seeded status field value so it's persisted alongside form fields
    const mergedAttributes = { ...pendingStatusSeed.value, ...customAttributes };
    await ConversationApi.closeOutcome({
      conversationId: currentChat.value.id,
      outcome,
      customAttributes: mergedAttributes,
    });

    await store.dispatch('updateConversation', {
      ...currentChat.value,
      status: wootConstants.STATUS_TYPE.RESOLVED,
      result: outcome,
      additional_attributes: {
        ...(currentChat.value.additional_attributes || {}),
        outcome,
        ...(isOnCloseStrategy.value && hasCtwaClid.value
          ? { meta_conversion: { sent: true } }
          : {}),
      },
      custom_attributes: {
        ...(currentChat.value.custom_attributes || {}),
        ...mergedAttributes,
      },
    });

    useAlert(t('CONVERSATION_WORKFLOW.OUTCOME.SUCCESS'));
  } catch {
    useAlert(t('CONVERSATION_WORKFLOW.OUTCOME.ERROR'));
  }
};

defineExpose({ openWon, openLost });
</script>

<template>
  <div v-if="showButtons" class="flex items-center gap-1">
    <Button
      size="sm"
      variant="ghost"
      color="teal"
      icon="i-lucide-circle-check"
      :label="$t('CONVERSATION_WORKFLOW.OUTCOME.MARK_WON')"
      class="rounded-md"
      @click="openWon"
    />
    <Button
      size="sm"
      variant="ghost"
      color="ruby"
      icon="i-lucide-circle-x"
      :label="$t('CONVERSATION_WORKFLOW.OUTCOME.MARK_LOST')"
      class="rounded-md"
      @click="openLost"
    />
    <ConversationOutcomeModal
      ref="outcomeModalRef"
      @confirm="handleOutcomeConfirm"
    />
  </div>
</template>
