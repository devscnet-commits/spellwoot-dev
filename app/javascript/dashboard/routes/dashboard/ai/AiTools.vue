<script setup>
/* global axios */
import { ref, reactive, computed, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import Select from 'dashboard/components-next/select/Select.vue';
import ConfirmDeleteModal from 'dashboard/components/widgets/modal/ConfirmDeleteModal.vue';
import { useFormDirty } from 'dashboard/composables/useFormDirty';

const props = defineProps({
  // Optional overrides so this view can be embedded inside the agent (default department).
  agentId: { type: [String, Number], default: null },
  departmentId: { type: [String, Number], default: null },
});

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
const { isDirty, capture } = useFormDirty(() => ({ ...form }));

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
const governanceHint = g =>
  t(`AI_TOOLS.FORM.${GOVERNANCE_I18N[g] || 'GOV_ALLOWED'}_HINT`);
const governanceBadge = g =>
  ({
    allowed: 'bg-n-teal-3 text-n-teal-11',
    require_confirmation: 'bg-n-amber-3 text-n-amber-11',
    require_approval: 'bg-n-ruby-3 text-n-ruby-11',
  })[g] || 'bg-n-alpha-2 text-n-slate-11';

const integrationName = id =>
  integrations.value.find(link => link.id === id)?.name || '';

const isCapability = computed(() => form.implementation_type === 'capability');

const typeOptions = computed(() => [
  { value: 'capability', label: t('AI_TOOLS.FORM.TYPE_CAPABILITY') },
  { value: 'integration', label: t('AI_TOOLS.FORM.TYPE_INTEGRATION') },
]);
const capabilityOptions = computed(() => [
  { value: '', label: t('AI_TOOLS.FORM.NONE') },
  ...CAPABILITIES.map(c => ({
    value: c.key,
    label: t(`AI_TOOLS.CAPABILITIES.${c.i18n}`),
  })),
]);
const integrationOptions = computed(() => [
  { value: '', label: t('AI_TOOLS.FORM.NONE') },
  ...integrations.value.map(link => ({ value: link.id, label: link.name })),
]);
const governanceOptions = computed(() => [
  { value: 'allowed', label: t('AI_TOOLS.FORM.GOV_ALLOWED') },
  { value: 'require_confirmation', label: t('AI_TOOLS.FORM.GOV_CONFIRMATION') },
  { value: 'require_approval', label: t('AI_TOOLS.FORM.GOV_APPROVAL') },
]);

const baseUrl = () => {
  const accountId = route.params.accountId;
  const agentId = props.agentId || route.params.agentId;
  const departmentId = props.departmentId || route.params.departmentId;
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
  capture();
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
  capture();
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

const deleteTarget = ref(null);
const confirmRemove = async () => {
  try {
    await axios.delete(`${baseUrl()}/${deleteTarget.value.id}`);
    useAlert(t('AI_TOOLS.DELETED'));
    deleteTarget.value = null;
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
  <div class="flex flex-col gap-4">
    <div class="flex items-center justify-between gap-4">
      <span class="text-sm font-medium text-n-slate-12">
        {{ $t('AI_TOOLS.DESCRIPTION') }}
      </span>
      <button
        type="button"
        class="shrink-0 text-sm font-medium px-4 py-1.5 rounded-full bg-n-brand text-white"
        @click="openNew"
      >
        + {{ $t('AI_TOOLS.NEW') }}
      </button>
    </div>

    <p
      v-if="!isLoading && !tools.length"
      class="text-sm text-n-slate-11 py-6 text-center"
    >
      {{ $t('AI_TOOLS.EMPTY') }}
    </p>
    <div v-else class="flex flex-col gap-2">
      <div
        v-for="tool in tools"
        :key="tool.id"
        class="flex items-center justify-between gap-3 rounded-xl border border-n-weak bg-n-solid-1 px-4 py-3"
      >
        <div class="min-w-0 flex items-center gap-2">
          <span class="i-lucide-wrench size-4 text-n-slate-11 shrink-0" />
          <div class="min-w-0">
            <p class="text-sm font-medium text-n-slate-12 mb-0 truncate">
              {{ tool.name }}
            </p>
            <p class="text-xs text-n-slate-11 truncate mb-0">
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
        <div class="shrink-0 flex items-center gap-2 text-n-slate-11">
          <button
            type="button"
            class="hover:text-n-slate-12"
            :aria-label="$t('AI_TOOLS.FORM.EDIT')"
            @click="openEdit(tool)"
          >
            <span class="i-lucide-pencil size-4 inline-block" />
          </button>
          <button
            type="button"
            class="hover:text-n-ruby-11"
            :aria-label="$t('AI_TOOLS.FORM.DELETE')"
            @click="deleteTarget = tool"
          >
            <span class="i-lucide-trash-2 size-4 inline-block" />
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
        <div class="flex flex-col gap-1 text-sm text-n-slate-12">
          <span>{{ $t('AI_TOOLS.FORM.TYPE') }}</span>
          <Select v-model="form.implementation_type" :options="typeOptions" />
        </div>
        <div
          v-if="isCapability"
          class="flex flex-col gap-1 text-sm text-n-slate-12"
        >
          <span>{{ $t('AI_TOOLS.FORM.CAPABILITY_KEY') }}</span>
          <Select v-model="form.capability_key" :options="capabilityOptions" />
        </div>
        <div v-else class="flex flex-col gap-1 text-sm text-n-slate-12">
          <span>{{ $t('AI_TOOLS.FORM.INTEGRATION') }}</span>
          <Select
            v-model="form.integration_link_id"
            :options="integrationOptions"
          />
        </div>
        <div class="flex flex-col gap-1 text-sm text-n-slate-12">
          <span>{{ $t('AI_TOOLS.FORM.GOVERNANCE') }}</span>
          <Select v-model="form.governance" :options="governanceOptions" />
          <span class="text-xs text-n-slate-11">
            {{ governanceHint(form.governance) }}
          </span>
        </div>
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
          :disabled="!isDirty"
          class="text-sm font-medium px-3 py-2 rounded-lg bg-n-brand text-white disabled:opacity-50 disabled:cursor-not-allowed"
          @click="save"
        >
          {{ $t('AI_TOOLS.FORM.SAVE') }}
        </button>
      </div>
    </div>

    <ConfirmDeleteModal
      v-if="deleteTarget"
      show
      :title="$t('AI_TOOLS.DELETE_MODAL.TITLE')"
      :message="
        $t('AI_TOOLS.DELETE_MODAL.MESSAGE', { name: deleteTarget.name })
      "
      :confirm-text="$t('AI_TOOLS.DELETE_MODAL.CONFIRM')"
      :reject-text="$t('AI_TOOLS.DELETE_MODAL.CANCEL')"
      :confirm-value="deleteTarget.name"
      :confirm-place-holder-text="
        $t('AI_TOOLS.DELETE_MODAL.PLACEHOLDER', { name: deleteTarget.name })
      "
      @on-confirm="confirmRemove"
      @on-close="deleteTarget = null"
    />
  </div>
</template>
