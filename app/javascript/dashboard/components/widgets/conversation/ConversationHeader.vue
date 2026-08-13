<script setup>
import { computed, ref } from 'vue';
import { useRoute } from 'vue-router';
import { useStore } from 'vuex';
import { useElementSize } from '@vueuse/core';
import BackButton from '../BackButton.vue';
import MoreActions from './MoreActions.vue';
import Avatar from 'next/avatar/Avatar.vue';
import SLACardLabel from './components/SLACardLabel.vue';
import { conversationListPageURL } from 'dashboard/helper/URLHelper';
import { useInbox } from 'dashboard/composables/useInbox';
import { useI18n } from 'vue-i18n';

const props = defineProps({
  chat: {
    type: Object,
    default: () => ({}),
  },
  showBackButton: {
    type: Boolean,
    default: false,
  },
});

useI18n();
const store = useStore();
const route = useRoute();
const conversationHeader = ref(null);
const { width } = useElementSize(conversationHeader);
const { isAWebWidgetInbox } = useInbox();

const currentChat = computed(() => store.getters.getSelectedChat);
const accountId = computed(() => store.getters.getCurrentAccountId);

const chatMetadata = computed(() => props.chat.meta);

const backButtonUrl = computed(() => {
  const {
    params: { inbox_id: inboxId, label, teamId, id: customViewId },
    name,
  } = route;

  const conversationTypeMap = {
    conversation_through_mentions: 'mention',
    conversation_through_participating: 'participating',
    conversation_through_unattended: 'unattended',
  };
  return conversationListPageURL({
    accountId: accountId.value,
    inboxId,
    label,
    teamId,
    conversationType: conversationTypeMap[name],
    customViewId,
  });
});

const isHMACVerified = computed(() => {
  if (!isAWebWidgetInbox.value) {
    return true;
  }
  return chatMetadata.value.hmac_verified;
});

const currentContact = computed(() =>
  store.getters['contacts/getContact'](props.chat.meta.sender?.id)
);

// The inbox (Caixa) this conversation belongs to — shown under the contact name.
const inbox = computed(() =>
  store.getters['inboxes/getInbox'](props.chat?.inbox_id)
);

const hasSlaPolicyId = computed(() => props.chat?.sla_policy_id);

const isReopened = computed(
  () => !!props.chat?.additional_attributes?.was_reopened
);
</script>

<template>
  <div
    ref="conversationHeader"
    class="flex flex-col gap-3 items-center justify-between flex-1 w-full min-w-0 xl:flex-row px-4 py-3 h-28 xl:h-16"
  >
    <div
      class="flex items-center justify-start w-full xl:w-auto max-w-full min-w-0 xl:flex-1"
    >
      <BackButton
        v-if="showBackButton"
        :back-url="backButtonUrl"
        class="ltr:mr-2 rtl:ml-2"
      />
      <Avatar
        :name="currentContact.name"
        :src="currentContact.thumbnail"
        :size="44"
        :status="currentContact.availability_status"
        hide-offline-status
        rounded-full
      />
      <div
        class="flex flex-col items-start min-w-0 ml-3 overflow-hidden rtl:ml-0 rtl:mr-3"
      >
        <div class="flex flex-row items-center max-w-full gap-1 p-0 m-0">
          <span
            class="text-base font-medium truncate leading-tight text-n-slate-12"
          >
            {{ currentContact.name }}
          </span>
          <fluent-icon
            v-if="!isHMACVerified"
            v-tooltip="$t('CONVERSATION.UNVERIFIED_SESSION')"
            size="14"
            class="text-n-amber-10 my-0 mx-0 min-w-[14px] flex-shrink-0"
            icon="warning"
          />
          <span
            v-if="isReopened"
            class="flex-shrink-0 px-1.5 py-0.5 text-xs font-medium leading-none rounded-md text-n-amber-11 bg-n-amber-3"
          >
            {{ $t('CONVERSATION.REOPENED_TAG') }}
          </span>
        </div>

        <div
          v-if="inbox?.name"
          class="flex items-center gap-1 overflow-hidden text-xs text-n-slate-11 conversation--header--actions text-ellipsis whitespace-nowrap"
        >
          <span class="i-lucide-inbox size-3 shrink-0" />
          <span class="truncate">{{ inbox.name }}</span>
        </div>
      </div>
    </div>
    <div
      class="flex flex-row items-center justify-start xl:justify-end flex-shrink-0 gap-2 w-full xl:w-auto header-actions-wrap"
    >
      <SLACardLabel
        v-if="hasSlaPolicyId"
        :chat="chat"
        show-extended-info
        :parent-width="width"
        class="hidden md:flex"
      />
      <MoreActions :conversation-id="currentChat.id" />
    </div>
  </div>
</template>
