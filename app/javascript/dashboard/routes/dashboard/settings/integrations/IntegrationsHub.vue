<script setup>
import { ref, reactive } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAccount } from 'dashboard/composables/useAccount';
import { useAlert } from 'dashboard/composables';
import integrationSettingsAPI from '../../../../api/integrationSettings';
import providerInstancesAPI from '../../../../api/providerInstances';

const { t } = useI18n();
const { accountId } = useAccount();

const PROVIDERS = [
  {
    key: 'meta',
    name: 'Meta Conversions API',
    description: 'Rastreamento de conversões via CAPI para anúncios no Facebook/Instagram.',
    icon: 'i-lucide-facebook',
    fields: [
      { key: 'pixelId', label: 'Pixel ID', sensitive: false, placeholder: '123456789', help: 'https://www.facebook.com/business/help/952192354843755' },
      { key: 'accessToken', label: 'Access Token da CAPI', sensitive: true, placeholder: 'EAAB...', help: 'https://developers.facebook.com/docs/marketing-api/conversions-api/get-started' },
      { key: 'testEventCode', label: 'Test Event Code (Opcional)', sensitive: false, placeholder: 'TEST12345', help: null },
    ],
  },
  {
    key: 'openai',
    name: 'OpenAI',
    description: 'Integração com modelos GPT para respostas automáticas.',
    icon: 'i-lucide-brain',
    testable: true,
    fields: [
      { key: 'apiKey', label: 'API Key', sensitive: true, placeholder: 'sk-...', help: 'https://platform.openai.com/api-keys' },
      { key: 'model', label: 'Modelo padrão', sensitive: false, placeholder: 'gpt-4o', help: null },
    ],
  },
  {
    key: 'evolution_api',
    name: 'Evolution API',
    description: 'Integração com Evolution API para WhatsApp.',
    icon: 'i-lucide-message-square',
    testable: true,
    fields: [
      { key: 'apiUrl', label: 'URL da API', sensitive: false, placeholder: 'https://evolution.exemplo.com', help: null },
      { key: 'apiKey', label: 'API Key', sensitive: true, placeholder: '', help: null },
      { key: 'instance', label: 'Instância padrão', sensitive: false, placeholder: 'minha-instancia', help: null },
    ],
  },
  {
    key: 'uazapi',
    name: 'UazAPI',
    description: 'Integração com UazAPI para WhatsApp.',
    icon: 'i-lucide-smartphone',
    testable: true,
    syncInstances: true,
    fields: [
      { key: 'apiUrl', label: 'URL do servidor', sensitive: false, placeholder: 'https://seu-servidor.uazapi.com', help: null },
      { key: 'token', label: 'Admin Token', sensitive: true, placeholder: '', help: null },
      { key: 'webhookBaseUrl', label: 'URL base de webhooks (opcional)', sensitive: false, placeholder: 'https://sandbox.suaempresa.com.br', help: null },
    ],
  },
  {
    key: 'bitrix',
    name: 'Bitrix24',
    description: 'Integração com CRM Bitrix24.',
    icon: 'i-lucide-building-2',
    fields: [
      { key: 'webhookUrl', label: 'Webhook URL', sensitive: false, placeholder: 'https://...bitrix24.com/rest/...', help: null },
      { key: 'token', label: 'Token', sensitive: true, placeholder: '', help: null },
    ],
  },
  {
    key: 'n8n',
    name: 'N8N',
    description: 'Automação de fluxos via N8N.',
    icon: 'i-lucide-workflow',
    fields: [
      { key: 'webhookUrl', label: 'Webhook URL', sensitive: false, placeholder: 'https://n8n.exemplo.com/webhook/...', help: null },
      { key: 'token', label: 'Token de autenticação', sensitive: true, placeholder: '', help: null },
    ],
  },
  {
    key: 'google',
    name: 'Google',
    managedByEnv: true,
    description: 'Integração com APIs Google.',
    icon: 'i-lucide-search',
    fields: [
      { key: 'clientId', label: 'Client ID', sensitive: false, placeholder: '', help: null },
      { key: 'clientSecret', label: 'Client Secret', sensitive: true, placeholder: '', help: null },
      { key: 'refreshToken', label: 'Refresh Token', sensitive: true, placeholder: '', help: null },
    ],
  },
];

const SOURCE_LABELS = {
  account: { label: 'Esta conta', color: 'bg-n-teal-3 text-n-teal-11' },
  global:  { label: 'Global',    color: 'bg-n-blue-3 text-n-blue-11' },
  env:     { label: 'Servidor',  color: 'bg-n-slate-3 text-n-slate-11' },
};

// Per-account editing rolls out provider by provider: those still marked managedByEnv
// stay read-only (credentials from server ENV) until their flows are validated.
const FORCE_ENV_MANAGED = false;
const isEnvManaged = provider => FORCE_ENV_MANAGED || provider.managedByEnv;

const getConfigSource = providerKey => {
  const sources = state[providerKey].sources;
  if (!sources || Object.keys(sources).length === 0) return null;
  const values = Object.values(sources);
  if (values.some(v => v === 'account')) return 'account';
  if (values.some(v => v === 'global')) return 'global';
  return 'env';
};

// State per provider
const state = reactive(
  Object.fromEntries(
    PROVIDERS.map(p => [
      p.key,
      {
        open: false, loading: false, saving: false, importing: false,
        testing: false, syncing: false, loadingInstances: false,
        testResult: null, syncResult: null, instances: [],
        enabled: true, config: {}, sources: {}, reset: {}, dirty: false,
      },
    ])
  )
);

const loadProvider = async providerKey => {
  const s = state[providerKey];
  s.loading = true;
  try {
    const { data } = await integrationSettingsAPI.get(accountId.value, providerKey);
    s.enabled = data.enabled ?? true;
    s.config  = { ...data.config };
    s.sources = data.sources || {};
    s.reset   = {};
    s.dirty   = false;
  } catch {
    // provider not configured yet — leave empty
  } finally {
    s.loading = false;
  }
};

const loadInstances = async providerKey => {
  const s = state[providerKey];
  s.loadingInstances = true;
  try {
    const { data } = await providerInstancesAPI.list(accountId.value, providerKey);
    s.instances = data;
  } catch {
    s.instances = [];
  } finally {
    s.loadingInstances = false;
  }
};

const toggleOpen = async providerKey => {
  const s = state[providerKey];
  s.open = !s.open;
  const provider = PROVIDERS.find(p => p.key === providerKey);
  // Env-managed providers are read-only — don't hit integration_settings at all.
  if (s.open && !s.dirty && !isEnvManaged(provider)) {
    await loadProvider(providerKey);
    if (provider?.syncInstances) loadInstances(providerKey);
  }
};

const isSensitive = (field, s) => field.sensitive && s.config[field.key] && !s.reset[field.key];

const showToken = ref({});
const toggleShowToken = key => { showToken.value[key] = !showToken.value[key]; };

const resetField = (field, s) => {
  s.reset[field.key] = true;
  s.config[field.key] = '';
  s.dirty = true;
};

const saveProvider = async providerKey => {
  const s = state[providerKey];
  s.saving = true;
  try {
    await integrationSettingsAPI.update(accountId.value, providerKey, s.config, s.enabled);
    await loadProvider(providerKey);
    useAlert(t('INTEGRATIONS_HUB.SAVED'));
  } catch {
    useAlert(t('INTEGRATIONS_HUB.ERROR'));
  } finally {
    s.saving = false;
  }
};

const importFromEnv = async providerKey => {
  const s = state[providerKey];
  s.importing = true;
  try {
    const { data } = await integrationSettingsAPI.importFromEnv(accountId.value, providerKey);
    if (data.imported > 0) {
      await loadProvider(providerKey);
      useAlert(`${data.imported} variáveis importadas do servidor.`);
    } else {
      useAlert('Nenhuma variável de ambiente encontrada para este provedor.');
    }
  } catch {
    useAlert(t('INTEGRATIONS_HUB.ERROR'));
  } finally {
    s.importing = false;
  }
};

const syncInstances = async providerKey => {
  const s = state[providerKey];
  s.syncing = true;
  s.syncResult = null;
  try {
    const { data } = await integrationSettingsAPI.syncInstances(accountId.value, providerKey);
    s.syncResult = { ok: true, message: data.message || 'Instâncias sincronizadas!' };
    await loadInstances(providerKey);
  } catch (err) {
    const msg = err?.response?.data?.message || 'Falha ao sincronizar. Verifique as configurações.';
    s.syncResult = { ok: false, message: msg };
  } finally {
    s.syncing = false;
  }
};

const testConnection = async providerKey => {
  const s = state[providerKey];
  s.testing = true;
  s.testResult = null;
  try {
    const { data } = await integrationSettingsAPI.testConnection(accountId.value, providerKey);
    s.testResult = { ok: true, message: data.message || 'Conexão bem-sucedida.' };
  } catch (err) {
    const msg = err?.response?.data?.message || 'Falha na conexão. Verifique as credenciais.';
    s.testResult = { ok: false, message: msg };
  } finally {
    s.testing = false;
  }
};
</script>

<template>
  <div class="flex flex-col gap-1 p-6 max-w-3xl">
    <div class="mb-6">
      <h2 class="text-heading-2 font-semibold text-n-slate-12">
        {{ t('INTEGRATIONS_HUB.TITLE') }}
      </h2>
      <p class="text-body-para text-n-slate-11 mt-1">
        {{ t('INTEGRATIONS_HUB.DESCRIPTION') }}
      </p>
    </div>

    <div
      v-for="provider in PROVIDERS"
      :key="provider.key"
      class="rounded-xl border border-n-weak bg-n-solid-2 overflow-hidden"
    >
      <!-- Provider header -->
      <button
        class="w-full flex items-center justify-between px-5 py-4 hover:bg-n-slate-2 dark:hover:bg-n-solid-3 transition-colors text-left"
        @click="toggleOpen(provider.key)"
      >
        <div class="flex items-center gap-3">
          <span :class="[provider.icon, 'w-5 h-5 text-n-slate-9']" />
          <div>
            <p class="text-body-para font-medium text-n-slate-12">{{ provider.name }}</p>
            <p class="text-body-small text-n-slate-11">{{ provider.description }}</p>
          </div>
        </div>
        <div class="flex items-center gap-2">
          <span
            v-if="state[provider.key].sources && Object.keys(state[provider.key].sources).length"
            class="text-xs px-2 py-0.5 rounded-full bg-n-teal-3 text-n-teal-11"
          >
            Configurado
          </span>
          <span
            :class="[
              'w-4 h-4 transition-transform',
              state[provider.key].open ? 'i-lucide-chevron-up' : 'i-lucide-chevron-down',
              'text-n-slate-9'
            ]"
          />
        </div>
      </button>

      <!-- Expanded form -->
      <div v-if="state[provider.key].open" class="border-t border-n-weak px-5 py-4 flex flex-col gap-4">
        <!-- Loading -->
        <div v-if="state[provider.key].loading" class="text-body-small text-n-slate-11 py-2">
          Carregando...
        </div>

        <!-- Managed by environment variables (read-only) -->
        <div
          v-else-if="isEnvManaged(provider)"
          class="flex items-start gap-3 px-4 py-3 rounded-lg bg-n-slate-2 border border-n-weak"
        >
          <span class="i-lucide-server w-4 h-4 text-n-slate-9 shrink-0 mt-0.5" />
          <div class="flex flex-col gap-1 text-body-small text-n-slate-11">
            <p class="font-medium text-n-slate-12">Esta instalação utiliza configuração por variáveis de ambiente.</p>
            <p>As credenciais são gerenciadas pelo servidor.</p>
            <p>A configuração via interface será disponibilizada em uma versão futura.</p>
          </div>
        </div>

        <template v-else>
          <!-- Config source indicator -->
          <div v-if="getConfigSource(provider.key)" class="flex items-center gap-2 px-3 py-2 rounded-lg bg-n-slate-2 border border-n-weak text-body-small">
            <span class="i-lucide-database w-3.5 h-3.5 text-n-slate-9 shrink-0" />
            <span class="text-n-slate-11 shrink-0">Fonte da configuração:</span>
            <span
              :class="[
                'text-xs px-2 py-0.5 rounded-full font-medium',
                SOURCE_LABELS[getConfigSource(provider.key)]?.color
              ]"
            >
              {{ SOURCE_LABELS[getConfigSource(provider.key)]?.label }}
            </span>
            <span v-if="getConfigSource(provider.key) === 'env'" class="text-xs text-n-slate-10 truncate">
              — variáveis de ambiente do servidor
            </span>
          </div>

          <!-- Enabled toggle -->
          <div class="flex items-center justify-between">
            <span class="text-body-small font-medium text-n-slate-12">Ativar integração</span>
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                v-model="state[provider.key].enabled"
                type="checkbox"
                class="w-4 h-4 rounded accent-n-teal-9"
                @change="state[provider.key].dirty = true"
              />
            </label>
          </div>

          <!-- Fields -->
          <div
            v-for="field in provider.fields"
            :key="field.key"
            class="flex flex-col gap-1"
          >
            <div class="flex items-center justify-between">
              <label class="text-body-small font-medium text-n-slate-12">{{ field.label }}</label>
              <div class="flex items-center gap-2">
                <!-- Source badge -->
                <span
                  v-if="state[provider.key].sources[field.key]"
                  :class="[
                    'text-xs px-1.5 py-0.5 rounded-full font-medium',
                    SOURCE_LABELS[state[provider.key].sources[field.key]]?.color
                  ]"
                >
                  {{ SOURCE_LABELS[state[provider.key].sources[field.key]]?.label }}
                </span>
                <!-- Reset link for masked sensitive fields -->
                <button
                  v-if="isSensitive(field, state[provider.key])"
                  class="text-xs text-n-ruby-11 hover:underline"
                  @click="resetField(field, state[provider.key])"
                >
                  Redefinir
                </button>
                <!-- Help link -->
                <a
                  v-if="field.help"
                  :href="field.help"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="text-xs text-n-blue-11 hover:underline"
                >
                  Como encontrar?
                </a>
              </div>
            </div>

            <!-- Masked display when sensitive and set -->
            <div
              v-if="isSensitive(field, state[provider.key])"
              class="flex items-center gap-2 px-3 py-2 rounded-lg bg-n-slate-2 text-n-slate-11 text-body-small font-mono"
            >
              <span class="flex-1 tracking-widest">
                {{ showToken[`${provider.key}.${field.key}`] ? state[provider.key].config[field.key] : '••••••••••••' }}
              </span>
              <button
                type="button"
                class="shrink-0 text-n-slate-9 hover:text-n-slate-12 transition-colors"
                @click="toggleShowToken(`${provider.key}.${field.key}`)"
              >
                <span :class="showToken[`${provider.key}.${field.key}`] ? 'i-lucide-eye-off' : 'i-lucide-eye'" class="w-4 h-4" />
              </button>
            </div>
            <!-- Editable input -->
            <div v-else-if="field.sensitive" class="relative">
              <input
                v-model="state[provider.key].config[field.key]"
                :type="showToken[`${provider.key}.${field.key}_edit`] ? 'text' : 'password'"
                :placeholder="field.placeholder"
                class="w-full px-3 py-2 pr-10 rounded-lg border border-n-weak bg-n-solid-1 text-body-small text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
                @input="state[provider.key].dirty = true"
              />
              <button
                type="button"
                class="absolute right-3 top-1/2 -translate-y-1/2 text-n-slate-9 hover:text-n-slate-12 transition-colors"
                @click="toggleShowToken(`${provider.key}.${field.key}_edit`)"
              >
                <span :class="showToken[`${provider.key}.${field.key}_edit`] ? 'i-lucide-eye-off' : 'i-lucide-eye'" class="w-4 h-4" />
              </button>
            </div>
            <input
              v-else
              v-model="state[provider.key].config[field.key]"
              type="text"
              :placeholder="field.placeholder"
              class="w-full px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-body-small text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
              @input="state[provider.key].dirty = true"
            />
          </div>

          <!-- Synced instances list -->
          <div v-if="provider.syncInstances" class="flex flex-col gap-2 pt-2 border-t border-n-weak/50">
            <div class="flex items-center justify-between">
              <span class="text-body-small font-medium text-n-slate-12">Instâncias sincronizadas</span>
              <span v-if="state[provider.key].loadingInstances" class="text-xs text-n-slate-11">Carregando...</span>
            </div>
            <div v-if="state[provider.key].instances.length === 0 && !state[provider.key].loadingInstances" class="text-xs text-n-slate-11 py-1">
              Nenhuma instância sincronizada. Clique em "Sincronizar Instâncias" para buscar as instâncias disponíveis.
            </div>
            <div v-else class="flex flex-col gap-1">
              <div class="grid grid-cols-[1fr_1fr_auto] gap-2 text-xs text-n-slate-11 px-1">
                <span>Instância</span>
                <span>Número</span>
                <span>Status</span>
              </div>
              <div
                v-for="inst in state[provider.key].instances"
                :key="inst.id"
                class="grid grid-cols-[1fr_1fr_auto] gap-2 items-center px-1 py-1.5 rounded-lg bg-n-slate-2/50"
              >
                <span class="text-body-small text-n-slate-12 truncate">{{ inst.instance_name }}</span>
                <span class="text-body-small text-n-slate-11 font-mono">{{ inst.phone_number || '—' }}</span>
                <span
                  :class="[
                    'text-xs px-2 py-0.5 rounded-full font-medium whitespace-nowrap',
                    inst.status === 'connected' ? 'bg-n-teal-3 text-n-teal-11' : 'bg-n-slate-3 text-n-slate-11'
                  ]"
                >
                  {{
                    inst.status === 'connected'
                      ? 'Conectada'
                      : inst.status === 'disconnected'
                        ? 'Desconectada'
                        : inst.status
                  }}
                </span>
              </div>
            </div>
          </div>

          <!-- Sync result -->
          <div
            v-if="state[provider.key].syncResult"
            :class="[
              'flex flex-col gap-1 px-3 py-2 rounded-lg text-body-small',
              state[provider.key].syncResult.ok ? 'bg-n-teal-3 text-n-teal-11' : 'bg-n-ruby-3 text-n-ruby-11'
            ]"
          >
            <div class="flex items-center gap-2">
              <span :class="state[provider.key].syncResult.ok ? 'i-lucide-circle-check w-4 h-4' : 'i-lucide-circle-x w-4 h-4'" />
              {{ state[provider.key].syncResult.message }}
            </div>
            <div v-if="state[provider.key].syncResult.webhookUrl" class="text-xs font-mono opacity-80 break-all">
              Webhook: {{ state[provider.key].syncResult.webhookUrl }}
            </div>
          </div>

          <!-- Test result -->
          <div
            v-if="state[provider.key].testResult"
            :class="[
              'flex items-center gap-2 px-3 py-2 rounded-lg text-body-small',
              state[provider.key].testResult.ok
                ? 'bg-n-teal-3 text-n-teal-11'
                : 'bg-n-ruby-3 text-n-ruby-11'
            ]"
          >
            <span :class="state[provider.key].testResult.ok ? 'i-lucide-circle-check w-4 h-4' : 'i-lucide-circle-x w-4 h-4'" />
            {{ state[provider.key].testResult.message }}
          </div>

          <!-- Action buttons -->
          <div class="flex items-center justify-between pt-2 border-t border-n-weak/50">
            <div class="flex items-center gap-3">
              <button
                class="text-body-small text-n-slate-11 hover:text-n-slate-12 flex items-center gap-1 disabled:opacity-50"
                :disabled="state[provider.key].importing"
                @click="importFromEnv(provider.key)"
              >
                <span class="i-lucide-download w-3.5 h-3.5" />
                {{ state[provider.key].importing ? 'Importando...' : 'Importar do servidor' }}
              </button>
              <button
                v-if="provider.testable"
                class="text-body-small text-n-slate-11 hover:text-n-slate-12 flex items-center gap-1 disabled:opacity-50"
                :disabled="state[provider.key].testing"
                @click="testConnection(provider.key)"
              >
                <span class="i-lucide-plug w-3.5 h-3.5" />
                {{ state[provider.key].testing ? 'Testando...' : 'Testar conexão' }}
              </button>
              <button
                v-if="provider.syncInstances"
                class="text-body-small text-n-teal-11 hover:text-n-teal-12 flex items-center gap-1 disabled:opacity-50 font-medium"
                :disabled="state[provider.key].syncing"
                @click="syncInstances(provider.key)"
              >
                <span class="i-lucide-refresh-cw w-3.5 h-3.5" />
                {{ state[provider.key].syncing ? 'Sincronizando...' : 'Sincronizar Instâncias' }}
              </button>
            </div>
            <button
              class="px-4 py-1.5 rounded-lg bg-n-brand text-white text-body-small font-medium hover:opacity-90 disabled:opacity-50 transition-opacity"
              :disabled="state[provider.key].saving || !state[provider.key].dirty"
              @click="saveProvider(provider.key)"
            >
              {{ state[provider.key].saving ? t('INTEGRATIONS_HUB.SAVING') : t('INTEGRATIONS_HUB.SAVE') }}
            </button>
          </div>
        </template>
      </div>
    </div>
  </div>
</template>
