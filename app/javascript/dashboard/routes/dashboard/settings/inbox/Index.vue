<script setup>
import { computed, ref, reactive, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import Avatar from 'next/avatar/Avatar.vue';
import { useAdmin } from 'dashboard/composables/useAdmin';
import SettingsLayout from '../SettingsLayout.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import {
  useMapGetter,
  useStoreGetters,
  useStore,
} from 'dashboard/composables/store';
import ChannelName from './components/ChannelName.vue';
import ChannelIcon from 'next/icon/ChannelIcon.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import InboxesAPI from 'dashboard/api/inboxes';

const getters = useStoreGetters();
const store = useStore();
const { t } = useI18n();
const { isAdmin } = useAdmin();

const showDeletePopup = ref(false);
const selectedInbox = ref({});

// UazAPI status tracking
const uazapiStatuses = reactive({});
const uazapiLoading = reactive({});

const inboxes = useMapGetter('inboxes/getInboxes');

const inboxesList = computed(() => {
  return inboxes.value?.slice().sort((a, b) => a.name.localeCompare(b.name));
});

const uiFlags = computed(() => getters['inboxes/getUIFlags'].value);

const deleteConfirmText = computed(
  () => `${t('INBOX_MGMT.DELETE.CONFIRM.YES')} ${selectedInbox.value.name}`
);

const deleteRejectText = computed(
  () => `${t('INBOX_MGMT.DELETE.CONFIRM.NO')} ${selectedInbox.value.name}`
);

const confirmDeleteMessage = computed(
  () => `${t('INBOX_MGMT.DELETE.CONFIRM.MESSAGE')} ${selectedInbox.value.name}?`
);
const confirmPlaceHolderText = computed(
  () =>
    `${t('INBOX_MGMT.DELETE.CONFIRM.PLACE_HOLDER', {
      inboxName: selectedInbox.value.name,
    })}`
);

const deleteInbox = async ({ id }) => {
  try {
    await store.dispatch('inboxes/delete', id);
    useAlert(t('INBOX_MGMT.DELETE.API.SUCCESS_MESSAGE'));
  } catch (error) {
    useAlert(t('INBOX_MGMT.DELETE.API.ERROR_MESSAGE'));
  }
};
const closeDelete = () => {
  showDeletePopup.value = false;
  selectedInbox.value = {};
};

const confirmDeletion = () => {
  deleteInbox(selectedInbox.value);
  closeDelete();
};
const openDelete = inbox => {
  showDeletePopup.value = true;
  selectedInbox.value = inbox;
};

// UazAPI connection methods
const isUazapiInbox = inbox => {
  return inbox.is_uazapi === true;
};

const isUazapiConnected = inboxId => {
  const statusData = uazapiStatuses[inboxId];
  if (!statusData) return false;

  // Check if status is "connected" string or connected/logged_in boolean
  return (
    statusData.status === 'connected' ||
    statusData.connected === true ||
    statusData.logged_in === true
  );
};

const fetchUazapiStatus = async inboxId => {
  uazapiLoading[inboxId] = true;
  try {
    const { data } = await InboxesAPI.getUazapiStatus(inboxId);
    uazapiStatuses[inboxId] = data;
  } catch (error) {
    uazapiStatuses[inboxId] = { connected: false, error: true };
  } finally {
    uazapiLoading[inboxId] = false;
  }
};

const reconnectUazapi = async inboxId => {
  uazapiLoading[inboxId] = true;
  try {
    const { data } = await InboxesAPI.connectUazapi(inboxId);
    uazapiStatuses[inboxId] = {
      ...uazapiStatuses[inboxId],
      qr_code: data.qr_code,
      status: data.status,
    };
    useAlert(t('INBOX_MGMT.UAZAPI.RECONNECT_INITIATED'));
  } catch (error) {
    useAlert(t('INBOX_MGMT.UAZAPI.RECONNECT_ERROR'));
  } finally {
    uazapiLoading[inboxId] = false;
  }
};

// Fetch UazAPI status for all UazAPI inboxes on mount
onMounted(() => {
  inboxes.value?.forEach(inbox => {
    if (isUazapiInbox(inbox)) {
      fetchUazapiStatus(inbox.id);
    }
  });
});
</script>

<template>
  <SettingsLayout
    :no-records-found="!inboxesList.length"
    :no-records-message="$t('INBOX_MGMT.LIST.404')"
    :is-loading="uiFlags.isFetching"
  >
    <template #header>
      <BaseSettingsHeader
        :title="$t('INBOX_MGMT.HEADER')"
        :description="$t('INBOX_MGMT.DESCRIPTION')"
        :link-text="$t('INBOX_MGMT.LEARN_MORE')"
        feature-name="inboxes"
      >
        <template #actions>
          <router-link v-if="isAdmin" :to="{ name: 'settings_inbox_new' }">
            <Button
              icon="i-lucide-circle-plus"
              :label="$t('SETTINGS.INBOXES.NEW_INBOX')"
            />
          </router-link>
        </template>
      </BaseSettingsHeader>
    </template>
    <template #body>
      <table class="min-w-full overflow-x-auto">
        <tbody class="divide-y divide-n-weak flex-1 text-n-slate-12">
          <tr v-for="inbox in inboxesList" :key="inbox.id">
            <td class="py-4 ltr:pr-4 rtl:pl-4">
              <div class="flex items-center flex-row gap-4">
                <div
                  v-if="inbox.avatar_url"
                  class="bg-n-alpha-3 rounded-full size-12 p-2 ring ring-n-solid-1 border border-n-strong shadow-sm"
                >
                  <Avatar
                    :src="inbox.avatar_url"
                    :name="inbox.name"
                    :size="30"
                    rounded-full
                  />
                </div>
                <div
                  v-else
                  class="size-12 flex justify-center items-center bg-n-alpha-3 rounded-full p-2 ring ring-n-solid-1 border border-n-strong shadow-sm"
                >
                  <ChannelIcon class="size-5 text-n-slate-10" :inbox="inbox" />
                </div>
                <div>
                  <span class="block font-medium capitalize">
                    {{ inbox.name }}
                  </span>
                  <ChannelName
                    :channel-type="inbox.channel_type"
                    :medium="inbox.medium"
                  />
                </div>
                <!-- UazAPI Connection Status -->
                <template v-if="isUazapiInbox(inbox)">
                  <span
                    v-if="uazapiLoading[inbox.id]"
                    class="inline-flex items-center px-2 py-1 text-xs font-medium rounded-full bg-slate-100 text-slate-700 dark:bg-slate-800 dark:text-slate-300"
                  >
                    {{ $t('INBOX_MGMT.UAZAPI.STATUS.CHECKING') }}
                  </span>
                  <span
                    v-else-if="isUazapiConnected(inbox.id)"
                    class="inline-flex items-center px-2 py-1 text-xs font-medium rounded-full bg-green-100 text-green-700 dark:bg-green-900 dark:text-green-300"
                  >
                    {{ $t('INBOX_MGMT.UAZAPI.STATUS.CONNECTED') }}
                  </span>
                  <span
                    v-else
                    class="inline-flex items-center px-2 py-1 text-xs font-medium rounded-full bg-red-100 text-red-700 dark:bg-red-900 dark:text-red-300"
                  >
                    {{ $t('INBOX_MGMT.UAZAPI.STATUS.DISCONNECTED') }}
                  </span>
                </template>
              </div>
            </td>

            <td class="py-4">
              <div class="flex gap-1 justify-end">
                <!-- UazAPI Reconnect Button -->
                <Button
                  v-if="
                    isAdmin &&
                    isUazapiInbox(inbox) &&
                    !isUazapiConnected(inbox.id) &&
                    !uazapiLoading[inbox.id]
                  "
                  v-tooltip.top="$t('INBOX_MGMT.UAZAPI.RECONNECT')"
                  icon="i-lucide-refresh-cw"
                  xs
                  amber
                  faded
                  @click="reconnectUazapi(inbox.id)"
                />
                <!-- Refresh Status Button -->
                <Button
                  v-if="isAdmin && isUazapiInbox(inbox)"
                  v-tooltip.top="$t('INBOX_MGMT.UAZAPI.REFRESH_STATUS')"
                  icon="i-lucide-activity"
                  xs
                  slate
                  faded
                  :loading="uazapiLoading[inbox.id]"
                  @click="fetchUazapiStatus(inbox.id)"
                />
                <router-link
                  :to="{
                    name: 'settings_inbox_show',
                    params: { inboxId: inbox.id },
                  }"
                >
                  <Button
                    v-if="isAdmin"
                    v-tooltip.top="$t('INBOX_MGMT.SETTINGS')"
                    icon="i-lucide-settings"
                    slate
                    xs
                    faded
                  />
                </router-link>
                <Button
                  v-if="isAdmin"
                  v-tooltip.top="$t('INBOX_MGMT.DELETE.BUTTON_TEXT')"
                  icon="i-lucide-trash-2"
                  xs
                  ruby
                  faded
                  @click="openDelete(inbox)"
                />
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </template>

    <woot-confirm-delete-modal
      v-if="showDeletePopup"
      v-model:show="showDeletePopup"
      :title="$t('INBOX_MGMT.DELETE.CONFIRM.TITLE')"
      :message="confirmDeleteMessage"
      :confirm-text="deleteConfirmText"
      :reject-text="deleteRejectText"
      :confirm-value="selectedInbox.name"
      :confirm-place-holder-text="confirmPlaceHolderText"
      @on-confirm="confirmDeletion"
      @on-close="closeDelete"
    />
  </SettingsLayout>
</template>
