<script setup>
import { ref, computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore, useStoreGetters } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useAccount } from 'dashboard/composables/useAccount';
import { useConversationRequiredAttributes } from 'dashboard/composables/useConversationRequiredAttributes';
import Button from 'dashboard/components-next/button/Button.vue';
import ConversationOutcomeModal from './ConversationOutcomeModal.vue';

const store = useStore();
const getters = useStoreGetters();
const { t } = useI18n();
const { currentAccount } = useAccount();
const { requiredAttributes } = useConversationRequiredAttributes();

const currentChat = computed(() => getters.getSelectedChat.value);
const outcomeModalRef = ref(null);

const metaSettings = computed(
  () => currentAccount.value?.settings?.meta_conversion_settings || {}
);

const isOnCloseStrategy = computed(
  () => metaSettings.value.strategy === 'on_close'
);

const hasCtwaClid = computed(
  () => !!currentChat.value?.custom_attributes?.ctwa_clid
);

const alreadySent = computed(
  () => currentChat.value?.additional_attributes?.meta_conversion?.sent === true
);

const showButtons = computed(
  () => isOnCloseStrategy.value && hasCtwaClid.value && !alreadySent.value
);

const winValue = computed(() => metaSettings.value.win_value || 'Won');
const lossValue = computed(() => metaSettings.value.loss_value || 'Lost');
const winStatusField = computed(() => metaSettings.value.win_status_field);

// Pre-filter attributes relevant to an outcome (condition_value matches win or loss)
const attributesForOutcome = outcomeValue =>
  requiredAttributes.value.filter(
    attr =>
      attr.rule === 'always' ||
      (attr.rule === 'conditional' &&
        attr.condition_field === winStatusField.value &&
        attr.condition_value === outcomeValue)
  );

const openWon = () => {
  outcomeModalRef.value?.open({
    outcome: 'won',
    label: t('CONVERSATION_WORKFLOW.OUTCOME.MARK_WON'),
    statusValue: winValue.value,
    attributes: attributesForOutcome(winValue.value),
    initialValues: currentChat.value?.custom_attributes || {},
  });
};

const openLost = () => {
  outcomeModalRef.value?.open({
    outcome: 'lost',
    label: t('CONVERSATION_WORKFLOW.OUTCOME.MARK_LOST'),
    statusValue: lossValue.value,
    attributes: attributesForOutcome(lossValue.value),
    initialValues: currentChat.value?.custom_attributes || {},
  });
};

const handleOutcomeConfirm = async ({ outcome, customAttributes }) => {
  try {
    const ConversationApi = (await import('dashboard/api/inbox/conversation'))
      .default;
    await ConversationApi.closeOutcome({
      conversationId: currentChat.value.id,
      outcome,
      customAttributes,
    });

    // Refresh conversation so alreadySent computed re-evaluates
    await store.dispatch('updateConversation', {
      ...currentChat.value,
      additional_attributes: {
        ...(currentChat.value.additional_attributes || {}),
        meta_conversion: { sent: true },
      },
      custom_attributes: {
        ...(currentChat.value.custom_attributes || {}),
        ...customAttributes,
      },
    });

    useAlert(t('CONVERSATION_WORKFLOW.OUTCOME.SUCCESS'));
  } catch {
    useAlert(t('CONVERSATION_WORKFLOW.OUTCOME.ERROR'));
  }
};
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
