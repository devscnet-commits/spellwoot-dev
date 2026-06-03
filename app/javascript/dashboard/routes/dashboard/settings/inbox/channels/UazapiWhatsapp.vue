<script setup>
import { ref, computed, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';
import { useVuelidate } from '@vuelidate/core';
import { required } from '@vuelidate/validators';
import { useAlert } from 'dashboard/composables';
import { useAccount } from 'dashboard/composables/useAccount';
import UazapiAPI from 'dashboard/api/uazapi';
import providerInstancesAPI from 'dashboard/api/providerInstances';

import NextButton from 'dashboard/components-next/button/Button.vue';

const { t } = useI18n();
const router = useRouter();
const { accountId } = useAccount();

const inboxName = ref('');
const selectedInstanceId = ref('');
const isCreating = ref(false);
const instances = ref([]);
const loadingInstances = ref(false);
const createdInbox = ref(null);
const webhookUrl = ref('');

const rules = {
  inboxName: { required },
  selectedInstanceId: { required },
};

const v$ = useVuelidate(rules, { inboxName, selectedInstanceId });

const selectedInstance = computed(() =>
  instances.value.find(i => String(i.id) === String(selectedInstanceId.value))
);

const connectedInstances = computed(() =>
  instances.value.filter(i => i.status === 'connected')
);

const hasInstances = computed(() => instances.value.length > 0);

const loadInstances = async () => {
  loadingInstances.value = true;
  try {
    const { data } = await providerInstancesAPI.list(accountId.value, 'uazapi');
    instances.value = data;
  } catch {
    instances.value = [];
  } finally {
    loadingInstances.value = false;
  }
};

const createChannel = async () => {
  v$.value.$touch();
  if (v$.value.$invalid) return;

  isCreating.value = true;
  try {
    const response = await UazapiAPI.fromInstance({
      name: inboxName.value.trim(),
      provider_instance_id: selectedInstanceId.value,
    });

    if (response.data.inbox) {
      createdInbox.value = response.data.inbox;
      webhookUrl.value = response.data.webhook_url || '';
      useAlert(t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.SUCCESS_MESSAGE'));
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

const goToAgents = () => {
  router.replace({
    name: 'settings_inboxes_add_agents',
    params: { page: 'new', inbox_id: createdInbox.value.id },
  });
};

const copyWebhookUrl = async () => {
  try {
    await navigator.clipboard.writeText(webhookUrl.value);
    useAlert(t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.WEBHOOK_URL.COPIED'));
  } catch {
    useAlert(t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.WEBHOOK_URL.COPY_ERROR'));
  }
};

onMounted(loadInstances);
</script>

<template>
  <div class="flex flex-col gap-6">
    <!-- Success screen -->
    <div v-if="createdInbox" class="flex flex-col items-center gap-6">
      <div class="flex items-center gap-2 px-4 py-2 rounded-full bg-n-teal-3 text-n-teal-11">
        <span class="w-3 h-3 rounded-full bg-n-teal-9" />
        <span class="text-sm font-medium">
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.STATUS.CONNECTED') }}
        </span>
      </div>

      <div class="text-center">
        <p class="text-lg font-medium text-n-slate-12">{{ createdInbox.name }}</p>
        <p class="text-sm text-n-slate-11">
          {{ selectedInstance?.phone_number }}
        </p>
      </div>

      <div
        v-if="webhookUrl"
        class="w-full max-w-md p-4 bg-n-slate-2 rounded-lg border border-n-weak"
      >
        <p class="text-sm font-medium text-n-slate-12 mb-2">
          {{ $t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.WEBHOOK_URL.LABEL') }}
        </p>
        <div class="flex items-center gap-2">
          <input
            :value="webhookUrl"
            readonly
            class="flex-1 px-3 py-2 text-xs border rounded-lg border-n-weak bg-n-alpha-black2 text-n-slate-12 font-mono"
          />
          <NextButton
            variant="smooth"
            size="small"
            :label="$t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.WEBHOOK_URL.COPY')"
            @click="copyWebhookUrl"
          />
        </div>
      </div>

      <div class="flex gap-4 mt-4">
        <NextButton
          solid
          blue
          :label="$t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.ADD_AGENTS')"
          @click="goToAgents"
        />
      </div>
    </div>

    <!-- Form -->
    <template v-else>
      <!-- Loading instances -->
      <div v-if="loadingInstances" class="text-sm text-n-slate-11 py-4 text-center">
        Carregando instâncias...
      </div>

      <!-- No instances -->
      <div v-else-if="!hasInstances" class="flex flex-col items-center gap-3 py-8 text-center">
        <span class="i-lucide-smartphone-nfc w-10 h-10 text-n-slate-8" />
        <p class="text-sm font-medium text-n-slate-12">Nenhuma instância sincronizada</p>
        <p class="text-xs text-n-slate-11 max-w-xs">
          Vá em <strong>Configurações → APIs &amp; Credenciais → UazAPI</strong> e clique em
          <strong>Sincronizar Instâncias</strong> antes de criar uma caixa.
        </p>
      </div>

      <!-- Form with instances -->
      <form
        v-else
        class="flex flex-wrap flex-col mx-0 gap-4"
        @submit.prevent="createChannel"
      >
        <!-- Instance selector -->
        <div class="flex flex-col gap-1">
          <label
            class="mb-0.5 text-sm font-medium text-n-slate-12"
            :class="{ 'text-n-ruby-11': v$.selectedInstanceId.$error }"
          >
            Instância WhatsApp
          </label>
          <select
            v-model="selectedInstanceId"
            class="w-full px-3 py-2 text-sm border rounded-lg border-n-weak bg-n-alpha-black2 text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
            :class="{ 'border-n-ruby-9': v$.selectedInstanceId.$error }"
            @blur="v$.selectedInstanceId.$touch"
          >
            <option value="" disabled>Selecione uma instância...</option>
            <option
              v-for="inst in instances"
              :key="inst.id"
              :value="inst.id"
            >
              {{ inst.instance_name }}
              {{ inst.phone_number ? `— ${inst.phone_number}` : '' }}
              {{ inst.status === 'connected' ? '✓' : '○' }}
            </option>
          </select>
          <span v-if="v$.selectedInstanceId.$error" class="text-xs text-n-ruby-11">
            Selecione uma instância.
          </span>
          <span v-if="selectedInstance && selectedInstance.status !== 'connected'" class="text-xs text-n-amber-11">
            Esta instância está desconectada. A caixa será criada, mas mensagens podem não ser entregues.
          </span>
        </div>

        <!-- Inbox name -->
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
            :placeholder="$t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.INBOX_NAME.PLACEHOLDER')"
            @blur="v$.inboxName.$touch"
          />
          <span v-if="v$.inboxName.$error" class="text-xs text-n-ruby-11">
            {{ $t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.INBOX_NAME.ERROR') }}
          </span>
        </div>

        <!-- Disconnected instances warning -->
        <div
          v-if="connectedInstances.length === 0"
          class="flex items-start gap-2 px-3 py-2 rounded-lg bg-n-amber-3 text-n-amber-11 text-xs"
        >
          <span class="i-lucide-triangle-alert w-4 h-4 mt-0.5 shrink-0" />
          <span>
            Todas as instâncias estão desconectadas. Reconecte no UazAPI antes de criar a caixa.
          </span>
        </div>

        <div class="w-full mt-2">
          <NextButton
            :is-loading="isCreating"
            type="submit"
            solid
            blue
            :label="$t('INBOX_MGMT.ADD.WHATSAPP.UAZAPI.SUBMIT_BUTTON')"
          />
        </div>
      </form>
    </template>
  </div>
</template>
