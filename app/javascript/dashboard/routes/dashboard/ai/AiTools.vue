<script setup>
/* global axios */
import { ref, reactive, computed, watch, onMounted } from 'vue';
import { useRoute, useRouter } from 'vue-router';
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
const router = useRouter();
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
  status: 'active',
  // args drive the visual builder; input_schema_text stays the canonical value used on save.
  args: [],
  input_schema_text: '{}',
});
const form = reactive(blank());
const { isDirty, capture } = useFormDirty(() => ({ ...form }));

// Visual argument builder: friendly types map to JSON Schema. The user never writes JSON,
// but an "advanced" escape hatch exposes the raw schema for cases the builder can't model.
const showAdvancedJson = ref(false);
const ARG_TYPES = [
  { value: 'string', i18n: 'TYPE_STRING' },
  { value: 'number', i18n: 'TYPE_NUMBER' },
  { value: 'boolean', i18n: 'TYPE_BOOLEAN' },
  { value: 'date', i18n: 'TYPE_DATE' },
  { value: 'array', i18n: 'TYPE_ARRAY' },
];
const argTypeOptions = computed(() =>
  ARG_TYPES.map(a => ({ value: a.value, label: t(`AI_TOOLS.FORM.${a.i18n}`) }))
);

const blankArg = () => ({
  name: '',
  type: 'string',
  description: '',
  // For the "Lista" (array) type: the allowed options, typed comma-separated.
  optionsText: '',
});

// Split the comma-separated options field into a clean enum list.
const parseOptions = text =>
  (text || '')
    .split(',')
    .map(s => s.trim())
    .filter(Boolean);

// Build a JSON Schema object from the argument rows. Every named argument is required —
// if the user added it, the action needs it.
const buildSchema = () => {
  const properties = {};
  const required = [];
  form.args.forEach(arg => {
    const key = (arg.name || '').trim();
    if (!key) return;
    let prop;
    if (arg.type === 'date') {
      prop = { type: 'string', format: 'date' };
    } else if (arg.type === 'array') {
      // "Lista" = escolha única: a IA deve escolher exatamente uma das opções.
      const options = parseOptions(arg.optionsText);
      prop = { type: 'string' };
      if (options.length) prop.enum = options;
    } else {
      prop = { type: arg.type };
    }
    if ((arg.description || '').trim())
      prop.description = arg.description.trim();
    properties[key] = prop;
    required.push(key);
  });
  const schema = { type: 'object', properties };
  if (required.length) schema.required = required;
  return schema;
};

// Turn an existing JSON Schema back into rows for the builder.
const parseSchema = schema => {
  const schemaProps = schema && schema.properties ? schema.properties : {};
  return Object.entries(schemaProps).map(([name, def]) => {
    const hasEnum = def && Array.isArray(def.enum);
    // A string carrying an enum is shown as the "Lista" (single-choice) builder row;
    // a date format maps back to the "Data" type.
    let type = (def && def.type) || 'string';
    if (def && def.format === 'date') type = 'date';
    else if (hasEnum) type = 'array';
    const enumList = hasEnum ? def.enum : [];
    return {
      name,
      type,
      description: (def && def.description) || '',
      optionsText: enumList.join(', '),
    };
  });
};

const addArg = () => form.args.push(blankArg());
const removeArg = index => form.args.splice(index, 1);

// Keep the canonical schema text in sync while the builder is the active editor.
watch(
  () => form.args,
  () => {
    if (!showAdvancedJson.value) {
      form.input_schema_text = JSON.stringify(buildSchema(), null, 2);
    }
  },
  { deep: true }
);

const toggleAdvanced = () => {
  if (showAdvancedJson.value) {
    // leaving advanced: re-derive rows from whatever JSON the user left behind
    try {
      form.args = parseSchema(JSON.parse(form.input_schema_text || '{}'));
    } catch (error) {
      useAlert(t('AI_TOOLS.INVALID_JSON'));
      return;
    }
  } else {
    form.input_schema_text = JSON.stringify(buildSchema(), null, 2);
  }
  showAdvancedJson.value = !showAdvancedJson.value;
};

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
// Integrations come from Configurações → Integrações; flag inactive ones so the user
// doesn't pick a connector that won't run.
const hasIntegrations = computed(() => integrations.value.length > 0);
const integrationOptions = computed(() => [
  { value: '', label: t('AI_TOOLS.FORM.NONE') },
  ...integrations.value.map(link => ({
    value: link.id,
    label:
      link.status === 'active'
        ? link.name
        : `${link.name} · ${t('AI_TOOLS.FORM.INTEGRATION_INACTIVE')}`,
  })),
]);
const goIntegrations = () =>
  router.push({
    name: 'settings_integrations_ai_systems',
    params: { accountId: route.params.accountId },
  });

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
  showAdvancedJson.value = false;
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
    status: tool.status,
    args: parseSchema(tool.input_schema || {}),
    input_schema_text: JSON.stringify(tool.input_schema || {}, null, 2),
  });
  showAdvancedJson.value = false;
  showForm.value = true;
  capture();
};

const save = async () => {
  let inputSchema = {};
  if (showAdvancedJson.value) {
    try {
      inputSchema = JSON.parse(form.input_schema_text || '{}');
    } catch (error) {
      useAlert(t('AI_TOOLS.INVALID_JSON'));
      return;
    }
  } else {
    inputSchema = buildSchema();
  }
  const payload = {
    ai_tool: {
      name: form.name,
      description: form.description,
      implementation_type: form.implementation_type,
      capability_key: isCapability.value ? form.capability_key : null,
      integration_link_id: isCapability.value ? null : form.integration_link_id,
      governance: 'allowed',
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
            v-if="hasIntegrations"
            v-model="form.integration_link_id"
            :options="integrationOptions"
          />
          <div
            v-else
            class="rounded-lg border border-dashed border-n-weak bg-n-alpha-1 px-3 py-3 flex flex-col gap-1.5"
          >
            <span class="text-xs text-n-slate-11">
              {{ $t('AI_TOOLS.FORM.INTEGRATION_EMPTY') }}
            </span>
            <button
              type="button"
              class="self-start text-xs font-medium text-n-brand hover:underline"
              @click="goIntegrations"
            >
              {{ $t('AI_TOOLS.FORM.INTEGRATION_CONFIGURE') }}
            </button>
          </div>
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
      <!-- Argumentos da ação: construtor visual + JSON avançado opcional -->
      <div class="flex flex-col gap-2">
        <div class="flex items-center justify-between gap-3">
          <span class="text-sm text-n-slate-12">
            {{ $t('AI_TOOLS.FORM.ARGS_LABEL') }}
          </span>
          <button
            type="button"
            class="text-xs text-n-slate-11 hover:text-n-brand"
            @click="toggleAdvanced"
          >
            {{
              showAdvancedJson
                ? $t('AI_TOOLS.FORM.ARGS_BUILDER')
                : $t('AI_TOOLS.FORM.ARGS_ADVANCED')
            }}
          </button>
        </div>
        <p class="text-xs text-n-slate-11 mb-0">
          {{ $t('AI_TOOLS.FORM.ARGS_HINT') }}
        </p>

        <template v-if="!showAdvancedJson">
          <p v-if="!form.args.length" class="text-xs text-n-slate-11 mb-0 py-1">
            {{ $t('AI_TOOLS.FORM.ARGS_EMPTY') }}
          </p>
          <div
            v-if="form.args.length"
            class="hidden sm:flex items-center gap-2 px-2 text-xs font-medium text-n-slate-11"
          >
            <span class="flex-1 min-w-[8rem]">
              {{ $t('AI_TOOLS.FORM.ARG_COL_NAME') }}
            </span>
            <span class="w-36">{{ $t('AI_TOOLS.FORM.ARG_COL_TYPE') }}</span>
            <span class="flex-[2] min-w-[10rem]">
              {{ $t('AI_TOOLS.FORM.ARG_COL_DESC') }}
            </span>
            <span class="size-4 shrink-0" />
          </div>
          <div
            v-for="(arg, index) in form.args"
            :key="index"
            class="flex flex-wrap items-center gap-2 rounded-lg border border-n-weak bg-n-solid-1 p-2"
          >
            <input
              v-model="arg.name"
              type="text"
              :placeholder="$t('AI_TOOLS.FORM.ARG_NAME')"
              class="flex-1 min-w-[8rem] px-3 py-2 rounded-lg border border-n-weak bg-n-solid-2 text-sm text-n-slate-12"
            />
            <div class="w-36">
              <Select v-model="arg.type" :options="argTypeOptions" />
            </div>
            <input
              v-model="arg.description"
              type="text"
              :placeholder="$t('AI_TOOLS.FORM.ARG_DESC')"
              class="flex-[2] min-w-[10rem] px-3 py-2 rounded-lg border border-n-weak bg-n-solid-2 text-sm text-n-slate-12"
            />
            <button
              type="button"
              class="shrink-0 text-n-slate-11 hover:text-n-ruby-11"
              :aria-label="$t('AI_TOOLS.FORM.ARG_REMOVE')"
              @click="removeArg(index)"
            >
              <span class="i-lucide-x size-4 inline-block" />
            </button>
            <!-- Lista (array): opções que a IA pode escolher, digitadas pelo usuário -->
            <div v-if="arg.type === 'array'" class="w-full flex flex-col gap-1">
              <input
                v-model="arg.optionsText"
                type="text"
                :placeholder="$t('AI_TOOLS.FORM.ARG_OPTIONS_PLACEHOLDER')"
                class="w-full px-3 py-2 rounded-lg border border-n-weak bg-n-solid-2 text-sm text-n-slate-12"
              />
              <span class="text-xs text-n-slate-11">
                {{ $t('AI_TOOLS.FORM.ARG_OPTIONS_HINT') }}
              </span>
            </div>
          </div>
          <button
            type="button"
            class="self-start text-sm font-medium text-n-brand hover:underline"
            @click="addArg"
          >
            + {{ $t('AI_TOOLS.FORM.ARG_ADD') }}
          </button>
        </template>

        <textarea
          v-else
          v-model="form.input_schema_text"
          rows="6"
          class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 font-mono text-xs resize-none"
        />
      </div>
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
