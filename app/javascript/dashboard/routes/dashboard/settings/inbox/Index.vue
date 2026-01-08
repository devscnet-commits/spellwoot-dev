<script setup>
import {
  computed,
  ref,
  reactive,
  onBeforeMount,
  onUnmounted,
  watch,
} from 'vue';
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
import Spinner from 'shared/components/Spinner.vue';

const getters = useStoreGetters();
const store = useStore();
const { t } = useI18n();
const { isAdmin } = useAdmin();

const showDeletePopup = ref(false);
const selectedInbox = ref({});

// Uazapi status tracking
const uazapiStatuses = reactive({});
const uazapiLoading = reactive({});

// Uazapi reconnect modal state
const showUazapiReconnectPopup = ref(false);
const reconnectInbox = ref(null);
const reconnectQrCode = ref('');
const reconnectPairCode = ref('');
const reconnectStatus = ref('');
const reconnectProfileName = ref('');
const reconnectPollingInterval = ref(null);
const reconnectLoading = ref(false);

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

// Uazapi connection methods
const isUazapiInbox = inbox => {
  // Check if it's marked as UazAPI or if it's an API channel with UazAPI attributes
  return (
    inbox.is_uazapi === true ||
    (inbox.channel_type === 'Channel::Api' &&
      inbox.additional_attributes?.uazapi_instance_token)
  );
};

const isUazapiConnected = inboxId => {
  const statusData = uazapiStatuses[inboxId];
  if (!statusData) return false;

  // Check exclusively the status field from backend
  return statusData.status === 'connected';
};

const hasUazapiIntegrationError = inboxId => {
  const statusData = uazapiStatuses[inboxId];
  if (!statusData) return false;

  // Check if integration has error
  const integrationStatus = statusData.integration_status;
  return (
    integrationStatus?.status === 'error' ||
    statusData.integration_error === true
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

const stopReconnectPolling = () => {
  if (reconnectPollingInterval.value) {
    clearTimeout(reconnectPollingInterval.value);
    reconnectPollingInterval.value = null;
  }
};

const closeUazapiReconnect = () => {
  stopReconnectPolling();
  showUazapiReconnectPopup.value = false;
  reconnectInbox.value = null;
  reconnectQrCode.value = '';
  reconnectPairCode.value = '';
  reconnectStatus.value = '';
  reconnectProfileName.value = '';
  reconnectLoading.value = false;
};

const pollReconnectStatus = async inboxId => {
  try {
    const { data } = await InboxesAPI.getUazapiStatus(inboxId);
    uazapiStatuses[inboxId] = data;
    reconnectStatus.value = data.status || '';
    reconnectProfileName.value = data.profile_name || '';
    if (data.qr_code) reconnectQrCode.value = data.qr_code;
    if (data.pair_code !== undefined) reconnectPairCode.value = data.pair_code;

    if (data.status === 'connected') {
      // Reconfigure integration after connection
      try {
        await InboxesAPI.reconfigureUazapi(inboxId);
        // Removed success toast - not needed
      } catch (error) {
        useAlert(t('INBOX_MGMT.UAZAPI.RECONFIGURE_ERROR'));
      }
      closeUazapiReconnect();
      return;
    }

    // Schedule next poll only after current one completes
    reconnectPollingInterval.value = setTimeout(
      () => pollReconnectStatus(inboxId),
      5000
    );
  } catch {
    // Silently fail on polling errors, but still schedule next poll
    reconnectPollingInterval.value = setTimeout(
      () => pollReconnectStatus(inboxId),
      5000
    );
  }
};

const startReconnectPolling = inboxId => {
  stopReconnectPolling();
  // Start first poll immediately
  pollReconnectStatus(inboxId);
};

const initiateReconnect = async inboxId => {
  reconnectLoading.value = true;
  try {
    // Check if already connected - if so, disconnect first
    const currentStatus = uazapiStatuses[inboxId];
    if (currentStatus?.status === 'connected') {
      try {
        await InboxesAPI.disconnectUazapi(inboxId);
        // Wait a bit for disconnect to complete
        await new Promise(resolve => {
          setTimeout(() => {
            resolve();
          }, 1000);
        });
      } catch (error) {
        // If disconnect fails, continue anyway
        // Silently continue
      }
    }

    const { data } = await InboxesAPI.connectUazapi(inboxId);
    uazapiStatuses[inboxId] = { ...(uazapiStatuses[inboxId] || {}), ...data };
    reconnectQrCode.value = data.qr_code || '';
    reconnectStatus.value = data.status || 'connecting';
    reconnectPairCode.value = data.pair_code || '';
    startReconnectPolling(inboxId);
  } catch (error) {
    useAlert(t('INBOX_MGMT.UAZAPI.RECONNECT_ERROR'));
  } finally {
    reconnectLoading.value = false;
  }
};

const openUazapiReconnect = async inbox => {
  reconnectInbox.value = inbox;
  showUazapiReconnectPopup.value = true;

  // Check if there's already a status with QR code (e.g., from integration error)
  const existingStatus = uazapiStatuses[inbox.id];

  // If already connected, we need to disconnect first, so don't use existing QR code
  if (isUazapiConnected(inbox.id)) {
    reconnectQrCode.value = '';
    reconnectPairCode.value = '';
    reconnectProfileName.value = '';
    reconnectStatus.value = 'connecting';
    await initiateReconnect(inbox.id);
    return;
  }

  if (existingStatus?.qr_code && !isUazapiConnected(inbox.id)) {
    reconnectQrCode.value = existingStatus.qr_code;
    reconnectStatus.value = existingStatus.status || 'connecting';
    reconnectPairCode.value = existingStatus.pair_code || '';
    reconnectProfileName.value = existingStatus.profile_name || '';
    startReconnectPolling(inbox.id);
  } else {
    // If there's an integration error but no QR code, fetch status first
    if (hasUazapiIntegrationError(inbox.id) && !existingStatus?.qr_code) {
      await fetchUazapiStatus(inbox.id);
      const updatedStatus = uazapiStatuses[inbox.id];
      if (updatedStatus?.qr_code) {
        reconnectQrCode.value = updatedStatus.qr_code;
        reconnectStatus.value = updatedStatus.status || 'connecting';
        reconnectPairCode.value = updatedStatus.pair_code || '';
        reconnectProfileName.value = updatedStatus.profile_name || '';
        startReconnectPolling(inbox.id);
        return;
      }
    }

    reconnectQrCode.value = '';
    reconnectPairCode.value = '';
    reconnectProfileName.value = '';
    reconnectStatus.value = 'connecting';
    await initiateReconnect(inbox.id);
  }
};

// Ensure inboxes are loaded
onBeforeMount(() => {
  store.dispatch('inboxes/get');
});

// Fetch Uazapi status once inboxes are available
watch(
  inboxesList,
  list => {
    list?.forEach(inbox => {
      if (!isUazapiInbox(inbox)) return;
      if (uazapiLoading[inbox.id]) return;
      if (uazapiStatuses[inbox.id]) return;
      fetchUazapiStatus(inbox.id);
    });
  },
  { immediate: true }
);

onUnmounted(() => {
  stopReconnectPolling();
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
                    {{
                      isUazapiInbox(inbox) ? `${inbox.name} - Beta` : inbox.name
                    }}
                  </span>
                  <ChannelName
                    :channel-type="inbox.channel_type"
                    :medium="inbox.medium"
                  />
                </div>
                <!-- Uazapi Status Badges -->
                <template v-if="isUazapiInbox(inbox)">
                  <div class="flex items-center gap-2">
                    <!-- Connection Status Badge -->
                    <span
                      v-if="
                        uazapiLoading[inbox.id] || !uazapiStatuses[inbox.id]
                      "
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

                    <!-- Webhook Status Badge -->
                    <span
                      v-if="
                        !uazapiLoading[inbox.id] &&
                        uazapiStatuses[inbox.id] &&
                        (hasUazapiIntegrationError(inbox.id) ||
                          uazapiStatuses[inbox.id]?.webhook_url)
                      "
                      class="inline-flex items-center px-2 py-1 text-xs font-medium rounded-full"
                      :class="{
                        'bg-amber-100 text-amber-700 dark:bg-amber-900 dark:text-amber-300':
                          hasUazapiIntegrationError(inbox.id),
                        'bg-green-100 text-green-700 dark:bg-green-900 dark:text-green-300':
                          !hasUazapiIntegrationError(inbox.id) &&
                          uazapiStatuses[inbox.id]?.webhook_url,
                      }"
                    >
                      {{
                        hasUazapiIntegrationError(inbox.id)
                          ? $t('INBOX_MGMT.UAZAPI.WEBHOOK_STATUS.ERROR')
                          : $t('INBOX_MGMT.UAZAPI.WEBHOOK_STATUS.OK')
                      }}
                    </span>
                  </div>
                </template>
              </div>
            </td>

            <td class="py-4">
              <div class="flex gap-1 justify-end">
                <!-- Uazapi Reconnect Button -->
                <Button
                  v-if="
                    isAdmin &&
                    isUazapiInbox(inbox) &&
                    (!isUazapiConnected(inbox.id) ||
                      hasUazapiIntegrationError(inbox.id)) &&
                    !uazapiLoading[inbox.id]
                  "
                  v-tooltip.top="$t('INBOX_MGMT.UAZAPI.RECONNECT')"
                  icon="i-lucide-refresh-cw"
                  xs
                  amber
                  faded
                  @click="openUazapiReconnect(inbox)"
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

    <!-- Uazapi reconnect modal -->
    <woot-modal
      v-model:show="showUazapiReconnectPopup"
      :on-close="closeUazapiReconnect"
    >
      <div class="p-6 flex flex-col items-center gap-4">
        <div class="flex flex-col items-center gap-1">
          <h3 class="text-lg font-medium text-n-slate-12">
            {{ $t('INBOX_MGMT.UAZAPI.RECONNECT') }}
          </h3>
          <p
            v-if="reconnectInbox && reconnectInbox.name"
            class="text-sm text-n-slate-11"
          >
            {{ reconnectInbox.name }}
          </p>
        </div>

        <div
          class="flex items-center gap-2 px-4 py-2 rounded-full"
          :class="{
            'bg-n-teal-3 text-n-teal-11': reconnectStatus === 'connected',
            'bg-n-amber-3 text-n-amber-11': reconnectStatus !== 'connected',
          }"
        >
          <span
            v-if="reconnectStatus !== 'connected'"
            class="relative flex h-3 w-3"
          >
            <span
              class="absolute inline-flex w-full h-full rounded-full opacity-75 animate-ping bg-n-amber-9"
            />
            <span
              class="relative inline-flex w-3 h-3 rounded-full bg-n-amber-9"
            />
          </span>
          <span v-else class="w-3 h-3 rounded-full bg-n-teal-9" />
          <span class="text-sm font-medium">
            {{
              reconnectStatus === 'connected'
                ? $t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.STATUS.CONNECTED')
                : $t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.STATUS.CONNECTING')
            }}
          </span>
        </div>

        <!-- Show integration error message if present -->
        <div
          v-if="
            reconnectInbox &&
            hasUazapiIntegrationError(reconnectInbox.id) &&
            uazapiStatuses[reconnectInbox.id]?.integration_status
          "
          class="w-full max-w-md p-3 bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 rounded-lg"
        >
          <p
            class="text-sm font-medium text-amber-800 dark:text-amber-200 mb-1"
          >
            {{ $t('INBOX_MGMT.UAZAPI.INTEGRATION_ERROR_TITLE') }}
          </p>
          <p class="text-xs text-amber-700 dark:text-amber-300">
            {{
              uazapiStatuses[reconnectInbox.id].integration_status
                ?.error_message ||
              uazapiStatuses[reconnectInbox.id].integration_status?.details?.[0]
            }}
          </p>
        </div>

        <p v-if="reconnectProfileName" class="text-sm text-n-slate-11">
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.CONNECTED_AS') }}:
          {{ reconnectProfileName }}
        </p>

        <div v-if="reconnectQrCode" class="flex flex-col items-center gap-4">
          <div class="p-4 bg-white rounded-2xl shadow-lg">
            <img
              :src="reconnectQrCode"
              alt="WhatsApp QR Code"
              class="w-64 h-64 object-contain"
            />
          </div>

          <p class="text-sm text-center text-n-slate-11 max-w-sm">
            {{ $t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.QR_CODE_INSTRUCTIONS') }}
          </p>
        </div>

        <div v-else class="flex flex-col items-center gap-3">
          <Spinner size="large" />
          <p class="text-sm text-n-slate-11">
            {{ $t('INBOX_MGMT.UAZAPI.GENERATING_QR_CODE') }}
          </p>
        </div>
      </div>
    </woot-modal>
  </SettingsLayout>
</template>
