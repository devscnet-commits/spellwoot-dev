<script setup>
import { ref, reactive, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useAccount } from 'dashboard/composables/useAccount';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import integrationSettingsApi from 'dashboard/api/integrationSettings';

const { t } = useI18n();
const { accountId } = useAccount();

const PROVIDERS = [
  {
    key: 'meta',
    name: 'Meta Conversions API',
    description: t('INTEGRATIONS_HUB.META.DESCRIPTION'),
    icon: 'i-lucide-target',
    fields: [
      { key: 'pixelId', label: t('INTEGRATIONS_HUB.META.PIXEL_ID'), sensitive: false, placeholder: '123456789', help: 'https://www.facebook.com/business/help/952192354843755' },
      { key: 'accessToken', label: t('INTEGRATIONS_HUB.META.ACCESS_TOKEN'), sensitive: true, placeholder: 'EAAB...', help: 'https://developers.facebook.com/docs/marketing-api/conversions-api/get-started' },
      { key: 'testEventCode', label: t('INTEGRATIONS_HUB.META.TEST_EVENT_CODE'), sensitive: false, placeholder: 'TEST12345', help: null },
    ],
  },
  {
    key: 'openai',
    name: 'OpenAI',
    description: t('INTEGRATIONS_HUB.OPENAI.DESCRIPTION'),
    icon: 'i-lucide-brain',
    fields: [
      { key: 'apiKey', label: t('INTEGRATIONS_HUB.OPENAI.API_KEY'), sensitive: true, placeholder: 'sk-...', help: 'https://platform.openai.com/api-keys' },
      { key: 'model', label: t('INTEGRATIONS_HUB.OPENAI.MODEL'), sensitive: false, placeholder: 'gpt-4o', help: null },
    ],
  },
  {
    key: 'n8n',
    name: 'N8N',
    description: t('INTEGRATIONS_HUB.N8N.DESCRIPTION'),
    icon: 'i-lucide-workflow',
    fields: [
      { key: 'webhookUrl', label: t('INTEGRATIONS_HUB.N8N.WEBHOOK_URL'), sensitive: false, placeholder: 'https://n8n.example.com/webhook/...', help: null },
      { key: 'token', label: t('INTEGRATIONS_HUB.N8N.TOKEN'), sensitive: true, placeholder: '', help: null },
    ],
  },
  {
    key: 'bitrix',
    name: 'Bitrix24',
    description: t('INTEGRATIONS_HUB.BITRIX.DESCRIPTION'),
    icon: 'i-lucide-building-2',
    fields: [
      { key: 'webhookUrl', label: t('INTEGRATIONS_HUB.BITRIX.WEBHOOK_URL'), sensitive: false, placeholder: 'https://...bitrix24.com/rest/...', help: null },
      { key: 'token', label: t('INTEGRATIONS_HUB.BITRIX.TOKEN'), sensitive: true, placeholder: '', help: null },
    ],
  },
];

const openProvider = ref(null);
const saving = ref(false);
const forms = reactive({});
const loaded = reactive({});
const resetFlags = reactive({});

const isConfigured = (providerKey) => {
  const config = forms[providerKey] || {};
  return Object.values(config).some(v => v && String(v).length > 0);
};

const isMasked = (value) => value && /\*{4,}/.test(value);

const loadProvider = async (providerKey) => {
  if (loaded[providerKey]) return;
  try {
    const { data } = await integrationSettingsApi.get(accountId.value, providerKey);
    forms[providerKey] = { ...(data.config || {}) };
    loaded[providerKey] = true;
  } catch {
    forms[providerKey] = {};
    loaded[providerKey] = true;
  }
};

const openConfigure = async (providerKey) => {
  if (openProvider.value === providerKey) {
    openProvider.value = null;
    return;
  }
  openProvider.value = providerKey;
  await loadProvider(providerKey);
};

const resetField = (providerKey, fieldKey) => {
  if (!resetFlags[providerKey]) resetFlags[providerKey] = {};
  resetFlags[providerKey][fieldKey] = true;
  forms[providerKey][fieldKey] = '';
};

const save = async (providerKey) => {
  saving.value = true;
  try {
    await integrationSettingsApi.update(accountId.value, providerKey, forms[providerKey]);
    loaded[providerKey] = false;
    await loadProvider(providerKey);
    if (resetFlags[providerKey]) resetFlags[providerKey] = {};
    useAlert(t('INTEGRATIONS_HUB.SAVED'));
  } catch {
    useAlert(t('INTEGRATIONS_HUB.ERROR'));
  } finally {
    saving.value = false;
  }
};

onMounted(() => {
  PROVIDERS.forEach(p => { forms[p.key] = {}; });
});
</script>

<template>
  <div class="flex flex-col gap-4 p-6 max-w-3xl">
    <div>
      <h2 class="text-lg font-semibold text-n-slate-12">{{ $t('INTEGRATIONS_HUB.TITLE') }}</h2>
      <p class="text-sm text-n-slate-11 mt-1">{{ $t('INTEGRATIONS_HUB.DESCRIPTION') }}</p>
    </div>

    <div class="flex flex-col gap-3">
      <div
        v-for="provider in PROVIDERS"
        :key="provider.key"
        class="rounded-xl border border-n-weak bg-n-solid-2"
      >
        <!-- Card header -->
        <div class="flex items-center justify-between p-4">
          <div class="flex items-center gap-3">
            <span :class="[provider.icon, 'w-5 h-5 text-n-slate-10']" />
            <div>
              <p class="text-sm font-medium text-n-slate-12">{{ provider.name }}</p>
              <p class="text-xs text-n-slate-11">{{ provider.description }}</p>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <span
              v-if="isConfigured(provider.key)"
              class="text-xs px-2 py-0.5 rounded-full bg-n-teal-3 text-n-teal-11 font-medium"
            >
              {{ $t('INTEGRATIONS_HUB.CONFIGURED') }}
            </span>
            <Button
              size="sm"
              variant="ghost"
              color="slate"
              :label="openProvider === provider.key ? $t('INTEGRATIONS_HUB.CLOSE') : $t('INTEGRATIONS_HUB.CONFIGURE')"
              :icon="openProvider === provider.key ? 'i-lucide-chevron-up' : 'i-lucide-settings-2'"
              @click="openConfigure(provider.key)"
            />
          </div>
        </div>

        <!-- Expanded form -->
        <div
          v-if="openProvider === provider.key"
          class="border-t border-n-weak px-4 pb-4 pt-4 flex flex-col gap-4"
        >
          <div
            v-for="field in provider.fields"
            :key="field.key"
            class="flex flex-col gap-1.5"
          >
            <div class="flex items-center justify-between">
              <label class="text-sm font-medium text-n-slate-12">{{ field.label }}</label>
              <a
                v-if="field.help"
                :href="field.help"
                target="_blank"
                rel="noopener noreferrer"
                class="text-xs text-n-blue-11 hover:underline flex items-center gap-1"
              >
                <span class="i-lucide-external-link w-3 h-3" />
                {{ $t('INTEGRATIONS_HUB.HOW_TO') }}
              </a>
            </div>

            <div class="flex items-center gap-2">
              <Input
                v-model="forms[provider.key][field.key]"
                class="flex-1"
                size="md"
                :type="field.sensitive && isMasked(forms[provider.key]?.[field.key]) ? 'password' : 'text'"
                :placeholder="field.placeholder"
              />
              <Button
                v-if="field.sensitive && isMasked(forms[provider.key]?.[field.key])"
                size="sm"
                variant="ghost"
                color="slate"
                icon="i-lucide-refresh-cw"
                :label="$t('INTEGRATIONS_HUB.RESET')"
                @click="resetField(provider.key, field.key)"
              />
            </div>
          </div>

          <div class="flex justify-end pt-2">
            <Button
              size="sm"
              color="slate"
              :label="saving ? $t('INTEGRATIONS_HUB.SAVING') : $t('INTEGRATIONS_HUB.SAVE')"
              :is-loading="saving"
              @click="save(provider.key)"
            />
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
