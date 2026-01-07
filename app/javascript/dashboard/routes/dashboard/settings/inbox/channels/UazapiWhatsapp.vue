<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';
import { useVuelidate } from '@vuelidate/core';
import { required } from '@vuelidate/validators';
import { useAlert } from 'dashboard/composables';
import UazapiAPI from 'dashboard/api/uazapi';
import { isNumber } from 'shared/helpers/Validators';

import NextButton from 'dashboard/components-next/button/Button.vue';
import Spinner from 'shared/components/Spinner.vue';

const { t } = useI18n();
const router = useRouter();

// Form state
const inboxName = ref('');
const phoneNumber = ref('');
const isCreating = ref(false);

// QR Code state
const showQrCode = ref(false);
const qrCode = ref('');
const connectionStatus = ref('');
const createdInbox = ref(null);
const pollingInterval = ref(null);
const profileName = ref('');

// Custom validator for Uazapi phone number (exactly 13 digits, all numeric)
const phoneNumberValidator = value => {
  if (!value) return true; // required validator handles empty
  const numericOnly = value.replace(/\D/g, '');
  return numericOnly.length === 13 && isNumber(numericOnly);
};

// Validation rules
const rules = {
  inboxName: { required },
  phoneNumber: {
    required,
    phoneNumberValidator: {
      $validator: phoneNumberValidator,
      $message: () =>
        t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.PHONE_NUMBER.VALIDATION_ERROR'),
    },
  },
};

const v$ = useVuelidate(rules, { inboxName, phoneNumber });

const isConnected = computed(() => connectionStatus.value === 'connected');
const isConnecting = computed(
  () =>
    connectionStatus.value === 'connecting' ||
    connectionStatus.value === 'disconnected'
);
const statusLabel = computed(() => {
  switch (connectionStatus.value) {
    case 'connected':
      return t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.STATUS.CONNECTED');
    case 'connecting':
      return t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.STATUS.CONNECTING');
    case 'disconnected':
      return t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.STATUS.DISCONNECTED');
    default:
      return t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.STATUS.UNKNOWN');
  }
});

const stopStatusPolling = () => {
  if (pollingInterval.value) {
    clearInterval(pollingInterval.value);
    pollingInterval.value = null;
  }
};

const startStatusPolling = () => {
  if (pollingInterval.value) {
    clearInterval(pollingInterval.value);
  }

  pollingInterval.value = setInterval(async () => {
    if (!createdInbox.value?.id) return;

    try {
      const response = await UazapiAPI.getStatus(createdInbox.value.id);
      const data = response.data;

      connectionStatus.value = data.status;
      profileName.value = data.profile_name || '';

      if (data.qr_code) {
        qrCode.value = data.qr_code;
      }

      if (data.status === 'connected') {
        stopStatusPolling();
        useAlert(t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.SUCCESS_MESSAGE'));
      }
    } catch {
      // Silently fail on polling errors
    }
  }, 3000);
};

const createChannel = async () => {
  v$.value.$touch();
  if (v$.value.$invalid) {
    return;
  }

  isCreating.value = true;

  try {
    // Clean phone number: remove all non-numeric characters
    const cleanedPhoneNumber = phoneNumber.value.replace(/\D/g, '');

    const response = await UazapiAPI.createInbox({
      name: inboxName.value.trim(),
      phone_number: cleanedPhoneNumber,
    });

    if (response.data.inbox) {
      createdInbox.value = response.data.inbox;
      qrCode.value = response.data.qr_code;
      connectionStatus.value = response.data.status || 'connecting';
      showQrCode.value = true;

      // Start polling for status
      startStatusPolling();
    }
  } catch (error) {
    useAlert(
      error.response?.data?.error ||
        t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.API.ERROR_MESSAGE')
    );
  } finally {
    isCreating.value = false;
  }
};

const refreshQrCode = async () => {
  if (!createdInbox.value?.id) return;

  try {
    const response = await UazapiAPI.connect(createdInbox.value.id);
    if (response.data.qr_code) {
      qrCode.value = response.data.qr_code;
      connectionStatus.value = response.data.status || 'connecting';
    }
  } catch {
    useAlert(t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.REFRESH_ERROR'));
  }
};

const goToAgents = () => {
  router.replace({
    name: 'settings_inboxes_add_agents',
    params: {
      page: 'new',
      inbox_id: createdInbox.value.id,
    },
  });
};

onMounted(() => {
  // Cleanup on mount just in case
});

onUnmounted(() => {
  stopStatusPolling();
});
</script>

<template>
  <div class="flex flex-col gap-6">
    <!-- Form Section -->
    <form
      v-if="!showQrCode"
      class="flex flex-wrap flex-col mx-0 gap-4"
      @submit.prevent="createChannel"
    >
      <div class="flex flex-col gap-1">
        <label
          for="inbox-name"
          class="mb-0.5 text-sm font-medium text-n-slate-12"
          :class="{ 'text-n-ruby-11': v$.inboxName.$error }"
        >
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.INBOX_NAME.LABEL') }}
        </label>
        <input
          id="inbox-name"
          v-model="inboxName"
          type="text"
          class="w-full px-3 py-2 text-sm border rounded-lg border-n-weak bg-n-alpha-black2 text-n-slate-12 placeholder:text-n-slate-9 focus:outline-none focus:ring-2 focus:ring-n-brand"
          :class="{ 'border-n-ruby-9': v$.inboxName.$error }"
          :placeholder="
            $t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.INBOX_NAME.PLACEHOLDER')
          "
          @blur="v$.inboxName.$touch"
        />
        <span v-if="v$.inboxName.$error" class="text-xs text-n-ruby-11">
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.INBOX_NAME.ERROR') }}
        </span>
      </div>

      <div class="flex flex-col gap-1">
        <label
          for="phone-number"
          class="mb-0.5 text-sm font-medium text-n-slate-12"
          :class="{ 'text-n-ruby-11': v$.phoneNumber.$error }"
        >
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.PHONE_NUMBER.LABEL') }}
        </label>
        <input
          id="phone-number"
          v-model="phoneNumber"
          type="text"
          class="w-full px-3 py-2 text-sm border rounded-lg border-n-weak bg-n-alpha-black2 text-n-slate-12 placeholder:text-n-slate-9 focus:outline-none focus:ring-2 focus:ring-n-brand"
          :class="{ 'border-n-ruby-9': v$.phoneNumber.$error }"
          :placeholder="
            $t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.PHONE_NUMBER.PLACEHOLDER')
          "
          @blur="v$.phoneNumber.$touch"
        />
        <span v-if="v$.phoneNumber.$error" class="text-xs text-n-ruby-11">
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.PHONE_NUMBER.ERROR') }}
        </span>
        <span class="text-xs text-n-slate-11">
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.PHONE_NUMBER.HELP') }}
        </span>
      </div>

      <div class="w-full mt-4">
        <NextButton
          :is-loading="isCreating"
          type="submit"
          solid
          blue
          :label="$t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.SUBMIT_BUTTON')"
        />
      </div>
    </form>

    <!-- QR Code Section -->
    <div v-else class="flex flex-col items-center gap-6">
      <!-- Status Badge -->
      <div
        class="flex items-center gap-2 px-4 py-2 rounded-full"
        :class="{
          'bg-n-teal-3 text-n-teal-11': isConnected,
          'bg-n-amber-3 text-n-amber-11': isConnecting,
        }"
      >
        <span v-if="isConnecting" class="relative flex h-3 w-3">
          <span
            class="absolute inline-flex w-full h-full rounded-full opacity-75 animate-ping bg-n-amber-9"
          />
          <span
            class="relative inline-flex w-3 h-3 rounded-full bg-n-amber-9"
          />
        </span>
        <span v-else class="w-3 h-3 rounded-full bg-n-teal-9" />
        <span class="text-sm font-medium">{{ statusLabel }}</span>
      </div>

      <!-- Profile Info (when connected) -->
      <div v-if="isConnected && profileName" class="text-center">
        <p class="text-lg font-medium text-n-slate-12">{{ profileName }}</p>
        <p class="text-sm text-n-slate-11">
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.CONNECTED_AS') }}
        </p>
      </div>

      <!-- QR Code Display -->
      <div
        v-if="!isConnected && qrCode"
        class="flex flex-col items-center gap-4"
      >
        <div class="p-4 bg-white rounded-2xl shadow-lg">
          <img
            :src="qrCode"
            alt="WhatsApp QR Code"
            class="w-64 h-64 object-contain"
          />
        </div>

        <p class="text-sm text-center text-n-slate-11 max-w-sm">
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.QR_CODE_INSTRUCTIONS') }}
        </p>

        <NextButton
          variant="smooth"
          :label="$t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.REFRESH_QR')"
          icon="i-lucide-refresh-cw"
          @click="refreshQrCode"
        />
      </div>

      <!-- Loading State -->
      <div
        v-else-if="!isConnected && !qrCode"
        class="flex flex-col items-center gap-4"
      >
        <Spinner size="large" />
        <p class="text-sm text-n-slate-11">
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.LOADING_QR') }}
        </p>
      </div>

      <!-- Success Actions -->
      <div v-if="isConnected" class="flex gap-4 mt-4">
        <NextButton
          solid
          blue
          :label="$t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.ADD_AGENTS')"
          @click="goToAgents"
        />
      </div>
    </div>
  </div>
</template>
