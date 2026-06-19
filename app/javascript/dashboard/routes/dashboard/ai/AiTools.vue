<script setup>
/* global axios */
import { ref, reactive, computed, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';

const route = useRoute();
const { t } = useI18n();

const tools = ref([]);
const integrations = ref([]);
const isLoading = ref(false);
const showForm = ref(false);

const blank = () => ({
  id: null,
  name: '',
  description: '',
  implementation_type: 'capability',
  capability_key: '',
  integration_link_id: '',
  governance: 'allowed',
  status: 'active',
  input_schema_text: '{}',
});
const form = reactive(blank());

// Business-friendly names for the internal capabilities (hide the technical keys from the UI).
const CAPABILITIES = [
  { key: 'contact.read', i18n: 'CONTACT_READ' },
  { key: 'contact.update_attributes', i18n: 'CONTACT_UPDATE' },
  { key: 'conversation.transfer', i18n: 'CONVERSATION_TRANSFER' },
  { key: 'conversation.resolve', i18n: 'CONVERSATION_RESOLVE' },
];
const capabilityLabel = key => {
  const cap = CAPABILITIES.find(c => c.key === key);
  return cap ? t(`AI_TOOLS.CAPABILITIES.${cap.i18n}`) : key;
};
const GOVERNANCE_I18N = {
  allowed: 'GOV_ALLOWED',
  require_confirmation: 'GOV_CONFIRMATION',
  require_approval: 'GOV_APPROVAL',
};
const governanceLabel = g =>
  t(`AI_TOOLS.FORM.${GOVERNANCE_I18N[g] || 'GOV_ALLOWED'}`);
const governanceBadge = g =>
  ({
    allowed: 'bg-n-teal-3 text-n-teal-11',
    require_confirmation: 'bg-n-amber-3 text-n-amber-11',
    require_approval: 'bg-n-ruby-3 text-n-ruby-11',
  })[g] || 'bg-n-alpha-2 text-n-slate-11';

const integrationName = id =>
  integrations.value.find(link => link.id === id)?.name || '';

const isCapability = computed(() => form.implementation_type === 'capability');

const baseUrl = () => {
  const { accountId, agentId, departmentId } = route.params;
  return `/api/v1/accounts/${accountId}/ai_agents/${agentId}/ai_departments/${departmentId}/ai_tools`;
};

const fetchTools = async () => {
  isLoading.value = true;
  try {
    const { data } = await axios.get(baseUrl());
    tools.value = Array.isArray(data) ? data : [];
  } finally {
    isLoading.value = false;
  }
};

const fetchIntegrations = async () => {
  try {
    const { data } = await axios.get(
      `/api/v1/accounts/${route.params.accountId}/ai_integration_links`
    );
    integrations.value = Array.isArray(data) ? data : [];
  } catch (error) {
    integrations.value = [];
  }
};

const openNew = () => {
  Object.assign(form, blank());
  showForm.value = true;
};

const openEdit = tool => {
  Object.assign(form, blank(), {
    id: tool.id,
    name: tool.name,
    description: tool.description,
    implementation_type: tool.implementation_type,
    capability_key: tool.capability_key || '',
    integration_link_id: tool.integration_link_id || '',
    governance: tool.governance,
    status: tool.status,
    input_schema_text: JSON.stringify(tool.input_schema || {}, null, 2),
  });
  showForm.value = true;
};

const save = async () => {
  let inputSchema = {};
  try {
    inputSchema = JSON.parse(form.input_schema_text || '{}');
  } catch (error) {
    useAlert(t('AI_TOOLS.INVALID_JSON'));
    return;
  }
  const payload = {
    ai_tool: {
      name: form.name,
      description: form.description,
      implementation_type: form.implementation_type,
      capability_key: isCapability.value ? form.capability_key : null,
      integration_link_id: isCapability.value ? null : form.integration_link_id,
      governance: form.governance,
      status: form.status,
      input_schema: inputSchema,
    },
  };
  try {
    if (form.id) {
      await axios.patch(`${baseUrl()}/${form.id}`, payload);
    } else {
      await axios.post(baseUrl(), payload);
    }
    useAlert(t('AI_TOOLS.SAVED'));
    showForm.value = false;
    fetchTools();
  } catch (error) {
    useAlert(t('AI_TOOLS.ERROR'));
  }
};

const remove = async tool => {
  // eslint-disable-next-line no-alert
  if (!window.confirm(t('AI_TOOLS.CONFIRM_DELETE'))) return;
  try {
    await axios.delete(`${baseUrl()}/${tool.id}`);
    useAlert(t('AI_TOOLS.DELETED'));
    fetchTools();
  } catch (error) {
    useAlert(t('AI_TOOLS.ERROR'));
  }
};

onMounted(() => {
  fetchTools();
  fetchIntegrations();
});
</script>

<template>
  <div class="flex flex-col w-full h-full overflow-auto p-6 gap-4">
    <div class="flex items-start justify-between gap-4">
      <div class="flex flex-col gap-1">
        <h1 class="text-xl font-semibold text-n-slate-12">
          {{ $t('AI_TOOLS.TITLE') }}
        </h1>
        <p class="text-sm text-n-slate-11 mb-0">
          {{ $t('AI_TOOLS.DESCRIPTION') }}
        </p>
      </div>
      <button
        type="button"
        class="shrink-0 text-sm font-medium px-3 py-2 rounded-lg bg-n-brand text-white"
        @click="openNew"
      >
        {{ $t('AI_TOOLS.NEW') }}
      </button>
    </div>

    <p
      v-if="!isLoading && !tools.length"
      class="text-sm text-n-slate-11 py-8 text-center"
    >
      {{ $t('AI_TOOLS.EMPTY') }}
    </p>
    <div v-else class="border border-n-weak rounded-xl divide-y divide-n-weak">
      <div
        v-for="tool in tools"
        :key="tool.id"
        class="flex items-center justify-between px-4 py-3"
      >
        <div class="min-w-0 flex items-center gap-2">
          <div class="min-w-0">
            <p class="text-sm font-medium text-n-slate-12">{{ tool.name }}</p>
            <p class="text-xs text-n-slate-11 truncate">
              {{
                tool.implementation_type === 'capability'
                  ? capabilityLabel(tool.capability_key)
                  : integrationName(tool.integration_link_id)
              }}
            </p>
          </div>
          <span
            class="shrink-0 inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium"
            :class="governanceBadge(tool.governance)"
          >
            {{ governanceLabel(tool.governance) }}
          </span>
        </div>
        <div class="shrink-0 whitespace-nowrap">
          <button
            class="text-n-brand hover:underline mx-2"
            @click="openEdit(tool)"
          >
            {{ $t('AI_TOOLS.FORM.EDIT') }}
          </button>
          <button class="text-n-ruby-11 hover:underline" @click="remove(tool)">
            {{ $t('AI_TOOLS.FORM.DELETE') }}
          </button>
        </div>
      </div>
    </div>

    <div
      v-if="showForm"
      class="border border-n-weak rounded-xl p-5 flex flex-col gap-3 bg-n-solid-2"
    >
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_TOOLS.FORM.NAME') }}
          <input
            v-model="form.name"
            type="text"
            class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
          />
        </label>
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_TOOLS.FORM.TYPE') }}
          <select
            v-model="form.implementation_type"
            class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
          >
            <option value="capability">
              {{ $t('AI_TOOLS.FORM.TYPE_CAPABILITY') }}
            </option>
            <option value="integration">
              {{ $t('AI_TOOLS.FORM.TYPE_INTEGRATION') }}
            </option>
          </select>
        </label>
        <label
          v-if="isCapability"
          class="flex flex-col gap-1 text-sm text-n-slate-12"
        >
          {{ $t('AI_TOOLS.FORM.CAPABILITY_KEY') }}
          <select
            v-model="form.capability_key"
            class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
          >
            <option value="">{{ $t('AI_TOOLS.FORM.NONE') }}</option>
            <option v-for="cap in CAPABILITIES" :key="cap.key" :value="cap.key">
              {{ $t(`AI_TOOLS.CAPABILITIES.${cap.i18n}`) }}
            </option>
          </select>
        </label>
        <label v-else class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_TOOLS.FORM.INTEGRATION') }}
          <select
            v-model="form.integration_link_id"
            class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
          >
            <option value="">{{ $t('AI_TOOLS.FORM.NONE') }}</option>
            <option
              v-for="link in integrations"
              :key="link.id"
              :value="link.id"
            >
              {{ link.name }}
            </option>
          </select>
        </label>
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_TOOLS.FORM.GOVERNANCE') }}
          <select
            v-model="form.governance"
            class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
          >
            <option value="allowed">
              {{ $t('AI_TOOLS.FORM.GOV_ALLOWED') }}
            </option>
            <option value="require_confirmation">
              {{ $t('AI_TOOLS.FORM.GOV_CONFIRMATION') }}
            </option>
            <option value="require_approval">
              {{ $t('AI_TOOLS.FORM.GOV_APPROVAL') }}
            </option>
          </select>
        </label>
      </div>
      <label class="flex flex-col gap-1 text-sm text-n-slate-12">
        {{ $t('AI_TOOLS.FORM.DESCRIPTION') }}
        <input
          v-model="form.description"
          type="text"
          class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
        />
      </label>
      <label class="flex flex-col gap-1 text-sm text-n-slate-12">
        {{ $t('AI_TOOLS.FORM.INPUT_SCHEMA') }}
        <textarea
          v-model="form.input_schema_text"
          rows="4"
          class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 font-mono text-xs resize-none"
        />
      </label>
      <div class="flex justify-end gap-2">
        <button
          type="button"
          class="text-sm px-3 py-2 rounded-lg bg-n-alpha-2 text-n-slate-12"
          @click="showForm = false"
        >
          {{ $t('AI_TOOLS.FORM.CANCEL') }}
        </button>
        <button
          type="button"
          class="text-sm font-medium px-3 py-2 rounded-lg bg-n-brand text-white"
          @click="save"
        >
          {{ $t('AI_TOOLS.FORM.SAVE') }}
        </button>
      </div>
    </div>
  </div>
</template>
