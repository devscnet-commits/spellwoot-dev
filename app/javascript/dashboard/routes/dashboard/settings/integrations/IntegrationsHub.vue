<script setup>
import { ref, reactive } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAccount } from 'dashboard/composables/useAccount';
import { useAlert } from 'dashboard/composables';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';
import integrationSettingsAPI from '../../../../api/integrationSettings';

const { t } = useI18n();
const { accountId } = useAccount();

const PROVIDERS = [
  {
    key: 'meta',
    name: 'Meta Conversions API',
    description:
      'Rastreamento de conversões via CAPI para anúncios no Facebook/Instagram.',
    icon: 'i-lucide-facebook',
    fields: [
      {
        key: 'pixelId',
        label: 'Pixel ID',
        sensitive: false,
        placeholder: '123456789',
        help: 'https://www.facebook.com/business/help/952192354843755',
      },
      {
        key: 'accessToken',
        label: 'Access Token da CAPI',
        sensitive: true,
        placeholder: 'EAAB...',
        help: 'https://developers.facebook.com/docs/marketing-api/conversions-api/get-started',
      },
      {
        key: 'testEventCode',
        label: 'Test Event Code (Opcional)',
        sensitive: false,
        placeholder: 'TEST12345',
        help: null,
      },
    ],
  },
  {
    key: 'openai',
    name: 'OpenAI',
    description: 'Integração com modelos GPT para respostas automáticas.',
    icon: 'i-lucide-brain',
    fields: [
      {
        key: 'apiKey',
        label: 'API Key',
        sensitive: true,
        placeholder: 'sk-...',
        help: 'https://platform.openai.com/api-keys',
      },
      {
        key: 'model',
        label: 'Modelo padrão',
        sensitive: false,
        placeholder: 'gpt-4o',
        help: null,
      },
    ],
  },
  {
    key: 'n8n',
    name: 'N8N',
    description: 'Automação de fluxos via N8N.',
    icon: 'i-lucide-workflow',
    fields: [
      {
        key: 'webhookUrl',
        label: 'Webhook URL',
        sensitive: false,
        placeholder: 'https://n8n.exemplo.com/webhook/...',
        help: null,
      },
      {
        key: 'token',
        label: 'Token de autenticação',
        sensitive: true,
        placeholder: 'Bearer ...',
        help: null,
      },
    ],
  },
  {
    key: 'bitrix',
    name: 'Bitrix24',
    description: 'Integração com CRM Bitrix24.',
    icon: 'i-lucide-building-2',
    fields: [
      {
        key: 'webhookUrl',
        label: 'Webhook URL',
        sensitive: false,
        placeholder: 'https://...bitrix24.com/rest/...',
        help: null,
      },
      {
        key: 'token',
        label: 'Token',
        sensitive: true,
        placeholder: '',
        help: null,
      },
    ],
  },
];

const expandedProvider = ref(null);
const saving = reactive({});
const configs = reactive({});
const maskedValues = reactive({});
const resetFields = reactive({});

function toggleProvider(providerKey) {
  if (expandedProvider.value === providerKey) {
    expandedProvider.value = null;
    return;
  }
  expandedProvider.value = providerKey;
  if (!configs[providerKey]) {
    loadConfig(providerKey);
  }
}

async function loadConfig(providerKey) {
  try {
    const response = await integrationSettingsAPI.get(
      accountId.value,
      providerKey
    );
    const data = response.data;
    configs[providerKey] = {};
    maskedValues[providerKey] = {};
    resetFields[providerKey] = {};

    const provider = PROVIDERS.find(p => p.key === providerKey);
    provider.fields.forEach(field => {
      const rawValue = data.config[field.key];
      if (field.sensitive && rawValue) {
        maskedValues[providerKey][field.key] = rawValue;
        configs[providerKey][field.key] = '';
      } else {
        configs[providerKey][field.key] = rawValue || '';
      }
      resetFields[providerKey][field.key] = false;
    });
  } catch {
    const provider = PROVIDERS.find(p => p.key === providerKey);
    configs[providerKey] = {};
    maskedValues[providerKey] = {};
    resetFields[providerKey] = {};
    provider.fields.forEach(field => {
      configs[providerKey][field.key] = '';
      resetFields[providerKey][field.key] = false;
    });
  }
}

function isConfigured(providerKey, fieldKey) {
  return (
    maskedValues[providerKey]?.[fieldKey] &&
    !resetFields[providerKey]?.[fieldKey]
  );
}

function resetField(providerKey, fieldKey) {
  if (!resetFields[providerKey]) resetFields[providerKey] = {};
  resetFields[providerKey][fieldKey] = true;
  if (!configs[providerKey]) configs[providerKey] = {};
  configs[providerKey][fieldKey] = '';
}

async function saveConfig(providerKey) {
  saving[providerKey] = true;
  try {
    const provider = PROVIDERS.find(p => p.key === providerKey);
    const configToSave = {};
    provider.fields.forEach(field => {
      if (
        field.sensitive &&
        isConfigured(providerKey, field.key) &&
        !configs[providerKey][field.key]
      ) {
        // keep existing masked value unchanged — don't overwrite with empty
      } else {
        configToSave[field.key] = configs[providerKey]?.[field.key] || '';
      }
    });

    await integrationSettingsAPI.update(
      accountId.value,
      providerKey,
      configToSave
    );
    useAlert(t('INTEGRATIONS_HUB.SAVED'));
    await loadConfig(providerKey);
  } catch {
    useAlert(t('INTEGRATIONS_HUB.ERROR'));
  } finally {
    saving[providerKey] = false;
  }
}
</script>

<template>
  <SettingsLayout>
    <template #header>
      <BaseSettingsHeader
        :title="$t('INTEGRATIONS_HUB.TITLE')"
        :description="$t('INTEGRATIONS_HUB.DESCRIPTION')"
      />
    </template>
    <template #body>
      <div class="flex flex-col gap-4 mt-4">
        <div
          v-for="provider in PROVIDERS"
          :key="provider.key"
          class="border border-slate-100 dark:border-slate-700 rounded-xl overflow-hidden"
        >
          <button
            class="w-full flex items-center justify-between px-5 py-4 bg-white dark:bg-slate-800 hover:bg-slate-50 dark:hover:bg-slate-700 transition-colors text-left"
            @click="toggleProvider(provider.key)"
          >
            <div class="flex items-center gap-3">
              <span
                :class="provider.icon"
                class="size-5 text-slate-500 dark:text-slate-400"
              />
              <div>
                <p
                  class="text-sm font-semibold text-slate-800 dark:text-slate-100"
                >
                  {{ provider.name }}
                </p>
                <p class="text-xs text-slate-500 dark:text-slate-400 mt-0.5">
                  {{ provider.description }}
                </p>
              </div>
            </div>
            <span
              class="size-4 text-slate-400 transition-transform"
              :class="
                expandedProvider === provider.key
                  ? 'i-lucide-chevron-up'
                  : 'i-lucide-chevron-down'
              "
            />
          </button>

          <div
            v-if="expandedProvider === provider.key"
            class="px-5 py-5 bg-slate-50 dark:bg-slate-900 border-t border-slate-100 dark:border-slate-700"
          >
            <div
              v-if="!configs[provider.key]"
              class="text-sm text-slate-400 py-2"
            >
              Loading...
            </div>
            <template v-else>
              <div class="flex flex-col gap-4">
                <div
                  v-for="field in provider.fields"
                  :key="field.key"
                  class="flex flex-col gap-1"
                >
                  <div class="flex items-center gap-2">
                    <label
                      class="text-xs font-medium text-slate-600 dark:text-slate-300"
                    >
                      {{ field.label }}
                    </label>
                    <span
                      v-if="isConfigured(provider.key, field.key)"
                      class="inline-flex items-center gap-1 text-xs text-green-600 dark:text-green-400 font-medium"
                    >
                      <span class="i-lucide-lock size-3" />
                      {{ $t('INTEGRATIONS_HUB.CONFIGURED') }}
                    </span>
                    <a
                      v-if="field.help"
                      :href="field.help"
                      target="_blank"
                      rel="noopener noreferrer"
                      class="text-xs text-blue-500 hover:text-blue-600 ml-auto"
                    >
                      {{ $t('INTEGRATIONS_HUB.HOW_TO') }}
                    </a>
                  </div>

                  <div
                    v-if="isConfigured(provider.key, field.key)"
                    class="flex items-center gap-2"
                  >
                    <input
                      disabled
                      :value="maskedValues[provider.key][field.key]"
                      class="flex-1 px-3 py-2 text-sm rounded-lg border border-slate-200 dark:border-slate-600 bg-slate-100 dark:bg-slate-800 text-slate-400 dark:text-slate-500 cursor-not-allowed"
                    />
                    <button
                      class="text-xs text-red-500 hover:text-red-600 whitespace-nowrap"
                      @click="resetField(provider.key, field.key)"
                    >
                      {{ $t('INTEGRATIONS_HUB.RESET') }}
                    </button>
                  </div>
                  <input
                    v-else
                    v-model="configs[provider.key][field.key]"
                    :placeholder="field.placeholder"
                    :type="field.sensitive ? 'password' : 'text'"
                    class="px-3 py-2 text-sm rounded-lg border border-slate-200 dark:border-slate-600 bg-white dark:bg-slate-800 text-slate-800 dark:text-slate-100 focus:outline-none focus:ring-2 focus:ring-woot-500 focus:border-transparent"
                  />
                </div>
              </div>

              <div class="flex justify-end mt-5">
                <button
                  :disabled="saving[provider.key]"
                  class="px-4 py-2 text-sm font-medium text-white bg-woot-500 hover:bg-woot-600 disabled:opacity-50 rounded-lg transition-colors"
                  @click="saveConfig(provider.key)"
                >
                  {{
                    saving[provider.key]
                      ? $t('INTEGRATIONS_HUB.SAVING')
                      : $t('INTEGRATIONS_HUB.SAVE')
                  }}
                </button>
              </div>
            </template>
          </div>
        </div>
      </div>
    </template>
  </SettingsLayout>
</template>
