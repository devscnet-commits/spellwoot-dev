<script setup>
/* global axios */
import { ref, reactive, computed, onMounted } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import Logo from 'next/icon/Logo.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import { useFormDirty } from 'dashboard/composables/useFormDirty';
import AiTools from './AiTools.vue';

// When embedded inside the agent (the agent's single default department), ids come by prop
// and the page chrome (breadcrumb / outer shell / Cancelar) is hidden.
const props = defineProps({
  embedded: { type: Boolean, default: false },
  embedDepartmentId: { type: [String, Number], default: null },
  // When embedded, which agent-level group of sections to show.
  section: { type: String, default: null },
});
const route = useRoute();
const router = useRouter();
const { t } = useI18n();

const isNew = computed(() => route.params.departmentId === 'new');
const departmentId = ref(
  props.embedDepartmentId || (isNew.value ? null : route.params.departmentId)
);
const activeTab = ref('instructions');

// Flattened into agent-level tabs when embedded: each group maps to underlying sections.
const SECTION_GROUPS = {
  behavior: ['instructions', 'attendance', 'followup', 'integrations'],
  steps: ['steps'],
  tools: ['tools'],
};
const visibleSections = computed(() =>
  props.embedded && props.section
    ? new Set(SECTION_GROUPS[props.section] || [])
    : new Set([activeTab.value])
);
const showSave = computed(() =>
  ['instructions', 'attendance', 'steps', 'followup'].some(s =>
    visibleSections.value.has(s)
  )
);
const isSaving = ref(false);
// Operational summary counts (read-only) served by the departments index serializer.
const summary = ref({ steps: 0, tools: 0, knowledge: 0 });

const replyScopeOptions = computed(() => [
  { value: 'off', label: t('AI_DEPARTMENTS.ATTENDANCE.REPLY_OFF') },
  { value: 'canary', label: t('AI_DEPARTMENTS.ATTENDANCE.REPLY_CANARY') },
  { value: 'all', label: t('AI_DEPARTMENTS.ATTENDANCE.REPLY_ALL') },
]);
const form = reactive({
  name: '',
  objetivo: '',
  instructions: '',
  status: 'active',
  steps: '',
  transfer_when_steps: '',
  close_when_steps: '',
  // Atendimento
  auto_attendance: true,
  group_delay_seconds: '',
  max_input_chars: '',
  followup_enabled: false,
  followup_delay: '',
  followup_message: '',
  reply_scope: 'off',
  canary_label: '',
  disabled_custom_attributes: [],
  is_default: false,
  position: 0,
});
const {
  isDirty: deptDirty,
  capture: captureDept,
  reset: resetDept,
} = useFormDirty(() => ({ ...form }));

const agentUrl = () =>
  `/api/v1/accounts/${route.params.accountId}/ai_agents/${route.params.agentId}`;
const deptCollectionUrl = () => `${agentUrl()}/ai_departments`;

// Custom attributes (account-level): the agent may use all of them by default; the user can
// exclude specific ones per agent (opt-out). New attributes appear enabled automatically.
const customAttributes = ref([]);
const fetchCustomAttributes = async () => {
  try {
    const { data } = await axios.get(
      `/api/v1/accounts/${route.params.accountId}/custom_attribute_definitions`
    );
    customAttributes.value = Array.isArray(data) ? data : [];
  } catch (error) {
    customAttributes.value = [];
  }
};
const attrEnabled = key => !form.disabled_custom_attributes.includes(key);
const toggleAttr = key => {
  const i = form.disabled_custom_attributes.indexOf(key);
  if (i >= 0) form.disabled_custom_attributes.splice(i, 1);
  else form.disabled_custom_attributes.push(key);
};

const linesToArray = value =>
  (value || '')
    .split('\n')
    .map(l => l.trim())
    .filter(Boolean);
const arrayToLines = value => (Array.isArray(value) ? value.join('\n') : '');

const hydrate = dept => {
  const playbook = dept.playbook || {};
  const behavior = dept.behavior || {};
  const followUp = dept.follow_up || {};
  Object.assign(form, {
    name: dept.name || '',
    objetivo: dept.objetivo || '',
    instructions: dept.instructions || behavior.instructions || '',
    status: dept.status || 'active',
    steps: arrayToLines(playbook.steps),
    transfer_when_steps: arrayToLines(playbook.transfer_when),
    close_when_steps: arrayToLines(playbook.close_when),
    auto_attendance: behavior.auto_attendance !== false,
    group_delay_seconds: behavior.grouping?.delay_seconds ?? '',
    max_input_chars: behavior.max_input_chars ?? '',
    followup_enabled: followUp.enabled || false,
    followup_delay: followUp.delay_minutes ?? '',
    followup_message: followUp.message || '',
    reply_scope: behavior.reply_scope || 'off',
    canary_label: behavior.canary_label || '',
    disabled_custom_attributes: Array.isArray(
      behavior.disabled_custom_attributes
    )
      ? [...behavior.disabled_custom_attributes]
      : [],
    is_default: dept.is_default || false,
    position: dept.position ?? 0,
  });
};

const fetchDepartment = async () => {
  if (isNew.value) return;
  const { data } = await axios.get(deptCollectionUrl());
  const dept = (Array.isArray(data) ? data : []).find(
    d => String(d.id) === String(departmentId.value)
  );
  if (dept) {
    hydrate(dept);
    summary.value = {
      steps: dept.steps_count ?? 0,
      tools: dept.tools_count ?? 0,
      knowledge: dept.knowledge_sources_count ?? 0,
    };
  }
  captureDept();
};

const buildPayload = () => ({
  ai_department: {
    name: form.name,
    objetivo: form.objetivo,
    instructions: form.instructions,
    status: form.status,
    is_default: form.is_default,
    position: form.position,
    behavior: {
      auto_attendance: form.auto_attendance,
      grouping: { delay_seconds: Number(form.group_delay_seconds) || 0 },
      max_input_chars: Number(form.max_input_chars) || 0,
      reply_scope: form.reply_scope,
      canary_label: form.canary_label,
      disabled_custom_attributes: form.disabled_custom_attributes,
    },
    follow_up: {
      enabled: form.followup_enabled,
      delay_minutes: Number(form.followup_delay) || 0,
      message: form.followup_message,
    },
    playbook: {
      objetivo: form.objetivo,
      steps: linesToArray(form.steps),
      transfer_when: linesToArray(form.transfer_when_steps),
      close_when: linesToArray(form.close_when_steps),
    },
  },
});

const save = async () => {
  isSaving.value = true;
  try {
    if (isNew.value) {
      const { data } = await axios.post(deptCollectionUrl(), buildPayload());
      departmentId.value = data.id;
      useAlert(t('AI_DEPARTMENTS.SAVED'));
      router.replace({
        name: 'ai_department_detail',
        params: { agentId: route.params.agentId, departmentId: data.id },
      });
    } else {
      await axios.patch(
        `${deptCollectionUrl()}/${departmentId.value}`,
        buildPayload()
      );
      useAlert(t('AI_DEPARTMENTS.SAVED'));
    }
    resetDept();
  } catch (error) {
    useAlert(t('AI_DEPARTMENTS.ERROR'));
  } finally {
    isSaving.value = false;
  }
};

const goBack = () =>
  router.push({
    name: 'ai_agent_detail',
    params: { agentId: route.params.agentId },
  });

// --- Integrations ---
const integrations = ref([]);
const integrationsUrl = () =>
  `${deptCollectionUrl()}/${departmentId.value}/ai_department_integrations`;

const {
  isDirty: integrationsDirty,
  capture: captureIntegrations,
  reset: resetIntegrations,
} = useFormDirty(() => integrations.value.map(i => !!i.enabled));
const fetchIntegrations = async () => {
  if (isNew.value) return;
  const { data } = await axios.get(integrationsUrl());
  integrations.value = (Array.isArray(data) ? data : []).map(i => ({
    ...i,
    enabled: !!i.enabled,
  }));
  captureIntegrations();
};
// Operational readiness (%): a checklist over data already loaded — no backend.
const readinessChecks = computed(() => [
  { key: 'OBJETIVO', ok: !!form.objetivo?.trim() },
  { key: 'INSTRUCTIONS', ok: !!form.instructions?.trim() },
  { key: 'STEPS', ok: summary.value.steps > 0 },
  { key: 'KNOWLEDGE', ok: summary.value.knowledge > 0 },
  { key: 'TOOLS', ok: summary.value.tools > 0 },
]);
const readinessPct = computed(() => {
  const checks = readinessChecks.value;
  return checks.length
    ? Math.round((checks.filter(c => c.ok).length / checks.length) * 100)
    : 0;
});

const saveIntegrations = async () => {
  const ids = integrations.value.filter(i => i.enabled).map(i => i.id);
  try {
    await axios.put(integrationsUrl(), { integration_link_ids: ids });
    useAlert(t('AI_DEPARTMENTS.SAVED'));
    resetIntegrations();
  } catch (error) {
    useAlert(t('AI_DEPARTMENTS.ERROR'));
  }
};

// --- Inbox routing (caixa -> departamento) ---
const mappedInboxes = ref([]);
const inboxesUrl = () =>
  `${deptCollectionUrl()}/${departmentId.value}/ai_department_inboxes`;

const {
  isDirty: mappedInboxesDirty,
  capture: captureMappedInboxes,
  reset: resetMappedInboxes,
} = useFormDirty(() => mappedInboxes.value.map(i => !!i.enabled));
const fetchMappedInboxes = async () => {
  if (isNew.value) return;
  const { data } = await axios.get(inboxesUrl());
  mappedInboxes.value = (Array.isArray(data) ? data : []).map(i => ({
    ...i,
    enabled: !!i.enabled,
  }));
  captureMappedInboxes();
};
const saveMappedInboxes = async () => {
  const ids = mappedInboxes.value.filter(i => i.enabled).map(i => i.inbox_id);
  try {
    await axios.put(inboxesUrl(), { inbox_ids: ids });
    useAlert(t('AI_DEPARTMENTS.SAVED'));
    resetMappedInboxes();
  } catch (error) {
    useAlert(t('AI_DEPARTMENTS.ERROR'));
  }
};

// --- Histórico de versões do playbook ---
const versions = ref([]);
const showVersions = ref(false);
const versionsUrl = () =>
  `${deptCollectionUrl()}/${departmentId.value}/ai_playbook_versions`;
const fetchVersions = async () => {
  if (isNew.value) return;
  const { data } = await axios.get(versionsUrl());
  versions.value = Array.isArray(data) ? data : [];
};
const restoreVersion = async v => {
  // eslint-disable-next-line no-alert
  if (!window.confirm(t('AI_AGENTS.VERSIONS.CONFIRM', { n: v.version_number })))
    return;
  try {
    await axios.post(`${versionsUrl()}/${v.id}/restore`);
    useAlert(t('AI_AGENTS.VERSIONS.RESTORED'));
    await fetchDepartment();
    await fetchVersions();
  } catch (error) {
    useAlert(t('AI_DEPARTMENTS.ERROR'));
  }
};
const formatVersionDate = iso => (iso ? new Date(iso).toLocaleString() : '');

onMounted(async () => {
  await fetchDepartment();
  captureDept();
  await Promise.all([
    fetchIntegrations(),
    fetchMappedInboxes(),
    fetchVersions(),
    fetchCustomAttributes(),
  ]);
});
</script>

<template>
  <div
    :class="
      embedded
        ? 'w-full'
        : 'w-full h-full overflow-auto bg-n-background p-4 sm:p-6'
    "
  >
    <div
      :class="
        embedded
          ? 'w-full flex flex-col gap-3'
          : 'max-w-4xl mx-auto flex flex-col gap-3'
      "
    >
      <button
        v-if="!embedded"
        type="button"
        class="self-start text-sm text-n-slate-11 hover:text-n-slate-12"
        @click="goBack"
      >
        {{ $t('AI_DEPARTMENTS.BACK') }}
      </button>

      <div
        :class="
          embedded
            ? 'flex flex-col gap-6'
            : 'rounded-2xl border border-n-weak bg-n-solid-1 px-4 sm:px-10 py-6 sm:py-7 flex flex-col gap-6'
        "
      >
        <div v-if="!embedded" class="flex items-center justify-between gap-4">
          <h1
            class="text-2xl sm:text-3xl font-semibold text-n-slate-12 truncate"
          >
            {{ form.name || $t('AI_DEPARTMENTS.NEW') }}
          </h1>
          <Logo class="h-8 w-auto shrink-0" />
        </div>

        <!-- Operational summary: what this department is made of, at a glance -->
        <div
          v-if="!isNew && !embedded"
          class="flex flex-wrap items-center gap-x-4 gap-y-2 text-sm text-n-slate-11"
        >
          <span class="inline-flex items-center gap-1.5">
            <span class="i-lucide-list-checks size-4" />
            {{ $t('AI_DEPARTMENTS.STATS_STEPS', { count: summary.steps }) }}
          </span>
          <span class="inline-flex items-center gap-1.5">
            <span class="i-lucide-wrench size-4" />
            {{ $t('AI_DEPARTMENTS.STATS_TOOLS', { count: summary.tools }) }}
          </span>
          <span class="inline-flex items-center gap-1.5">
            <span class="i-lucide-book-open size-4" />
            {{
              $t('AI_DEPARTMENTS.STATS_KNOWLEDGE', { count: summary.knowledge })
            }}
          </span>
          <span
            class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium"
            :class="
              form.auto_attendance
                ? 'bg-n-teal-3 text-n-teal-11'
                : 'bg-n-alpha-2 text-n-slate-11'
            "
          >
            <span
              class="size-1.5 rounded-full"
              :class="form.auto_attendance ? 'bg-n-teal-9' : 'bg-n-slate-7'"
            />
            {{
              form.auto_attendance
                ? $t('AI_DEPARTMENTS.AUTO_ON')
                : $t('AI_DEPARTMENTS.AUTO_OFF')
            }}
          </span>
        </div>

        <!-- Prontidão Operacional: checklist sobre dados já carregados (sem backend) -->
        <div
          v-if="!isNew && !embedded"
          class="rounded-xl border border-n-weak bg-n-solid-2 p-4 flex flex-col gap-3"
        >
          <div class="flex items-center justify-between gap-3">
            <span class="text-sm font-semibold text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.READINESS.TITLE') }}
            </span>
            <span
              class="text-lg font-semibold"
              :class="
                readinessPct === 100
                  ? 'text-n-teal-11'
                  : readinessPct >= 60
                    ? 'text-n-slate-12'
                    : 'text-n-amber-11'
              "
            >
              {{ `${readinessPct}%` }}
            </span>
          </div>
          <div class="flex flex-wrap gap-x-4 gap-y-1.5">
            <span
              v-for="check in readinessChecks"
              :key="check.key"
              class="inline-flex items-center gap-1.5 text-xs"
              :class="check.ok ? 'text-n-slate-11' : 'text-n-amber-11'"
            >
              <span
                class="size-3.5"
                :class="
                  check.ok
                    ? 'i-lucide-check-circle-2 text-n-teal-11'
                    : 'i-lucide-alert-circle'
                "
              />
              {{ $t(`AI_DEPARTMENTS.READINESS.${check.key}`) }}
            </span>
          </div>
        </div>

        <div
          v-if="!embedded"
          class="flex flex-wrap items-center gap-x-5 gap-y-1 border-b border-n-weak"
        >
          <button
            v-for="tab in ['instructions', 'steps', 'tools']"
            :key="tab"
            type="button"
            class="pb-2.5 text-sm font-medium border-b-2 -mb-px disabled:opacity-40"
            :class="
              activeTab === tab
                ? 'border-n-brand text-n-brand'
                : 'border-transparent text-n-slate-11 hover:text-n-slate-12'
            "
            :disabled="isNew && tab !== 'instructions'"
            @click="activeTab = tab"
          >
            {{ $t(`AI_DEPARTMENTS.DETAIL_TABS.${tab.toUpperCase()}`) }}
          </button>
          <span class="flex items-center gap-2 pb-2.5 ml-1 text-n-slate-10">
            <span class="w-px h-3.5 bg-n-weak" />
            <span class="text-xs">{{
              $t('AI_DEPARTMENTS.ADVANCED_LABEL')
            }}</span>
          </span>
          <button
            v-for="tab in ['attendance', 'followup', 'integrations']"
            :key="tab"
            type="button"
            class="pb-2.5 text-sm font-medium border-b-2 -mb-px disabled:opacity-40"
            :class="
              activeTab === tab
                ? 'border-n-brand text-n-brand'
                : 'border-transparent text-n-slate-10 hover:text-n-slate-12'
            "
            :disabled="isNew"
            @click="activeTab = tab"
          >
            {{ $t(`AI_DEPARTMENTS.DETAIL_TABS.${tab.toUpperCase()}`) }}
          </button>
        </div>

        <!-- INSTRUÇÕES -->
        <div
          v-if="visibleSections.has('instructions')"
          class="flex flex-col gap-5"
        >
          <section
            class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-4"
          >
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
                {{ $t('AI_DEPARTMENTS.FORM.NAME') }}
                <input
                  v-model="form.name"
                  type="text"
                  class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
                />
              </label>
            </div>
            <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.OBJETIVO_LABEL') }}
              <input
                v-model="form.objetivo"
                type="text"
                :placeholder="$t('AI_DEPARTMENTS.OBJETIVO_PLACEHOLDER')"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
              />
            </label>
            <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.INSTRUCTIONS_LABEL') }}
              <textarea
                v-model="form.instructions"
                rows="6"
                :placeholder="$t('AI_DEPARTMENTS.INSTRUCTIONS_PLACEHOLDER')"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none"
              />
            </label>
          </section>

          <!-- Atributos personalizados (da conta): usar ou excluir por agente -->
          <section
            class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-3"
          >
            <div class="flex flex-col gap-0.5">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('AI_DEPARTMENTS.CUSTOM_ATTRS.TITLE') }}
              </span>
              <p class="text-xs text-n-slate-11 mb-0">
                {{ $t('AI_DEPARTMENTS.CUSTOM_ATTRS.HINT') }}
              </p>
            </div>
            <p
              v-if="!customAttributes.length"
              class="text-sm text-n-slate-11 mb-0"
            >
              {{ $t('AI_DEPARTMENTS.CUSTOM_ATTRS.EMPTY') }}
            </p>
            <div
              v-else
              class="border border-n-weak rounded-xl divide-y divide-n-weak"
            >
              <div
                v-for="attr in customAttributes"
                :key="attr.attribute_key"
                class="flex items-center justify-between gap-3 px-4 py-2.5"
              >
                <div class="min-w-0">
                  <p class="text-sm text-n-slate-12 mb-0 truncate">
                    {{ attr.attribute_display_name }}
                  </p>
                  <p class="text-xs text-n-slate-11 mb-0">
                    {{
                      attr.attribute_model === 'contact_attribute'
                        ? $t('AI_DEPARTMENTS.CUSTOM_ATTRS.MODEL_CONTACT')
                        : $t('AI_DEPARTMENTS.CUSTOM_ATTRS.MODEL_CONVERSATION')
                    }}
                  </p>
                </div>
                <button
                  type="button"
                  class="shrink-0 text-xs font-medium px-3 py-1 rounded-full transition-colors"
                  :class="
                    attrEnabled(attr.attribute_key)
                      ? 'bg-n-teal-3 text-n-teal-11'
                      : 'bg-n-alpha-2 text-n-slate-11'
                  "
                  @click="toggleAttr(attr.attribute_key)"
                >
                  {{
                    attrEnabled(attr.attribute_key)
                      ? $t('AI_DEPARTMENTS.CUSTOM_ATTRS.USING')
                      : $t('AI_DEPARTMENTS.CUSTOM_ATTRS.EXCLUDED')
                  }}
                </button>
              </div>
            </div>
          </section>
        </div>

        <!-- ATENDIMENTO -->
        <div
          v-if="visibleSections.has('attendance')"
          class="flex flex-col gap-5"
        >
          <section
            class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-3"
          >
            <div class="flex items-start justify-between gap-3">
              <div class="flex flex-col gap-0.5 min-w-0">
                <h2 class="text-base font-semibold text-n-slate-12 mb-0">
                  {{ $t('AI_DEPARTMENTS.ATTENDANCE.AUTO_TITLE') }}
                </h2>
                <p class="text-xs text-n-slate-11 mb-0">
                  {{
                    form.auto_attendance
                      ? $t('AI_DEPARTMENTS.ATTENDANCE.AUTO_HINT_ON')
                      : $t('AI_DEPARTMENTS.ATTENDANCE.AUTO_HINT_OFF')
                  }}
                </p>
              </div>
              <span
                class="shrink-0 inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium"
                :class="
                  form.auto_attendance
                    ? 'bg-n-teal-3 text-n-teal-11'
                    : 'bg-n-alpha-2 text-n-slate-11'
                "
              >
                <span
                  class="size-1.5 rounded-full"
                  :class="form.auto_attendance ? 'bg-n-teal-9' : 'bg-n-slate-7'"
                />
                {{
                  form.auto_attendance
                    ? $t('AI_DEPARTMENTS.STATE_ON')
                    : $t('AI_DEPARTMENTS.STATE_OFF')
                }}
              </span>
            </div>
            <label class="flex items-center gap-2 text-sm text-n-slate-12">
              <input v-model="form.auto_attendance" type="checkbox" />
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.AUTO_TOGGLE') }}
            </label>
          </section>

          <section
            class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-3"
          >
            <div class="flex items-start justify-between gap-3">
              <div class="flex flex-col gap-0.5 min-w-0">
                <h2 class="text-base font-semibold text-n-slate-12 mb-0">
                  {{ $t('AI_DEPARTMENTS.ATTENDANCE.DEFAULT_TITLE') }}
                </h2>
                <p class="text-xs text-n-slate-11 mb-0">
                  {{ $t('AI_DEPARTMENTS.ATTENDANCE.DEFAULT_HINT') }}
                </p>
              </div>
              <span
                v-if="form.is_default"
                class="shrink-0 inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium bg-n-brand/10 text-n-brand"
              >
                <span class="i-lucide-star size-3" />
                {{ $t('AI_DEPARTMENTS.DEFAULT_BADGE') }}
              </span>
            </div>
            <label class="flex items-center gap-2 text-sm text-n-slate-12">
              <input v-model="form.is_default" type="checkbox" />
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.DEFAULT_TOGGLE') }}
            </label>
          </section>

          <section
            class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-3"
          >
            <h2 class="text-base font-semibold text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.INBOXES_TITLE') }}
            </h2>
            <p class="text-sm text-n-slate-11 mb-0">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.INBOXES_HINT') }}
            </p>
            <p v-if="!mappedInboxes.length" class="text-sm text-n-slate-11">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.INBOXES_EMPTY') }}
            </p>
            <template v-else>
              <div
                class="border border-n-weak rounded-xl divide-y divide-n-weak"
              >
                <label
                  v-for="inbox in mappedInboxes"
                  :key="inbox.inbox_id"
                  class="flex items-center gap-3 px-4 py-3 text-sm text-n-slate-12"
                >
                  <input v-model="inbox.enabled" type="checkbox" />
                  <span>{{ inbox.name }}</span>
                </label>
              </div>
              <div class="flex justify-end">
                <button
                  type="button"
                  :disabled="!mappedInboxesDirty"
                  class="text-sm font-medium px-3 py-2 rounded-lg bg-n-alpha-2 text-n-slate-12 disabled:opacity-50 disabled:cursor-not-allowed"
                  @click="saveMappedInboxes"
                >
                  {{ $t('AI_DEPARTMENTS.ATTENDANCE.INBOXES_SAVE') }}
                </button>
              </div>
            </template>
          </section>

          <section
            class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-3"
          >
            <h2 class="text-base font-semibold text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.REPLY_TITLE') }}
            </h2>
            <p class="text-sm text-n-slate-11 mb-0">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.REPLY_HINT') }}
            </p>
            <div class="flex flex-col gap-1 text-sm text-n-slate-12">
              <span>{{ $t('AI_DEPARTMENTS.ATTENDANCE.REPLY_SCOPE') }}</span>
              <Select v-model="form.reply_scope" :options="replyScopeOptions" />
            </div>
            <label
              v-if="form.reply_scope === 'canary'"
              class="flex flex-col gap-1 text-sm text-n-slate-12"
            >
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.CANARY_LABEL') }}
              <input
                v-model="form.canary_label"
                type="text"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
              />
            </label>
          </section>

          <section
            class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-3"
          >
            <h2 class="text-base font-semibold text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.GROUPING_TITLE') }}
            </h2>
            <p class="text-sm text-n-slate-11 mb-0">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.GROUPING_HINT') }}
            </p>
            <label class="flex flex-col gap-1 text-sm text-n-slate-12 max-w-xs">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.GROUPING_DELAY') }}
              <input
                v-model="form.group_delay_seconds"
                type="number"
                min="0"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
              />
            </label>
          </section>

          <section
            class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-3"
          >
            <h2 class="text-base font-semibold text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.INPUT_LIMIT_TITLE') }}
            </h2>
            <p class="text-sm text-n-slate-11 mb-0">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.INPUT_LIMIT_HINT') }}
            </p>
            <label class="flex flex-col gap-1 text-sm text-n-slate-12 max-w-xs">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.INPUT_LIMIT_FIELD') }}
              <input
                v-model="form.max_input_chars"
                type="number"
                min="0"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
              />
            </label>
          </section>
        </div>

        <!-- FOLLOW-UP -->
        <div v-if="visibleSections.has('followup')" class="flex flex-col gap-5">
          <section
            class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-3"
          >
            <h2 class="text-base font-semibold text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.FOLLOWUP_TITLE') }}
            </h2>
            <label class="flex items-center gap-2 text-sm text-n-slate-12">
              <input v-model="form.followup_enabled" type="checkbox" />
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.FOLLOWUP_TOGGLE') }}
            </label>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                {{ $t('AI_DEPARTMENTS.ATTENDANCE.FOLLOWUP_DELAY') }}
                <input
                  v-model="form.followup_delay"
                  type="number"
                  min="0"
                  class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
                />
              </label>
              <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                {{ $t('AI_DEPARTMENTS.ATTENDANCE.FOLLOWUP_MESSAGE') }}
                <input
                  v-model="form.followup_message"
                  type="text"
                  class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
                />
              </label>
            </div>
          </section>
        </div>

        <!-- ETAPAS -->
        <div v-if="visibleSections.has('steps')" class="flex flex-col gap-5">
          <section
            class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-4"
          >
            <span class="text-sm font-medium text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.STEPS_TITLE') }}
            </span>
            <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.FORM.STEPS') }}
              <textarea
                v-model="form.steps"
                rows="8"
                class="px-3 py-2.5 rounded-lg border border-n-weak bg-n-solid-1 resize-y min-h-32 leading-relaxed"
              />
            </label>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
                {{ $t('AI_DEPARTMENTS.FORM.TRANSFER_WHEN') }}
                <textarea
                  v-model="form.transfer_when_steps"
                  rows="6"
                  class="px-3 py-2.5 rounded-lg border border-n-weak bg-n-solid-1 resize-y min-h-28 leading-relaxed"
                />
              </label>
              <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
                {{ $t('AI_DEPARTMENTS.FORM.CLOSE_WHEN') }}
                <textarea
                  v-model="form.close_when_steps"
                  rows="6"
                  class="px-3 py-2.5 rounded-lg border border-n-weak bg-n-solid-1 resize-y min-h-28 leading-relaxed"
                />
              </label>
            </div>
          </section>

          <!-- Histórico de versões do playbook -->
          <div
            v-if="!isNew"
            class="border-t border-n-weak pt-4 flex flex-col gap-3"
          >
            <button
              type="button"
              class="flex items-center gap-2 text-sm font-medium text-n-slate-12"
              @click="showVersions = !showVersions"
            >
              <span
                class="size-4 inline-block"
                :class="
                  showVersions
                    ? 'i-lucide-chevron-down'
                    : 'i-lucide-chevron-right'
                "
              />
              {{ $t('AI_AGENTS.VERSIONS.TITLE') }}
              <span class="text-n-slate-11 font-normal">{{
                `(${versions.length})`
              }}</span>
            </button>
            <div
              v-if="showVersions"
              class="border border-n-weak rounded-xl divide-y divide-n-weak max-h-72 overflow-auto"
            >
              <p
                v-if="!versions.length"
                class="text-sm text-n-slate-11 px-4 py-3 mb-0"
              >
                {{ $t('AI_AGENTS.VERSIONS.EMPTY') }}
              </p>
              <div
                v-for="v in versions"
                :key="v.id"
                class="flex items-center justify-between gap-3 px-4 py-2.5"
              >
                <div class="min-w-0">
                  <p class="text-sm text-n-slate-12 mb-0">
                    {{ `v${v.version_number}` }}
                    <span v-if="v.note" class="text-n-slate-11">{{
                      ` · ${v.note}`
                    }}</span>
                  </p>
                  <p class="text-xs text-n-slate-11 mb-0">
                    {{ formatVersionDate(v.created_at) }}
                  </p>
                </div>
                <button
                  type="button"
                  class="shrink-0 text-sm text-n-brand hover:underline"
                  @click="restoreVersion(v)"
                >
                  {{ $t('AI_AGENTS.VERSIONS.RESTORE') }}
                </button>
              </div>
            </div>
          </div>
        </div>

        <!-- FERRAMENTAS -->
        <AiTools
          v-if="visibleSections.has('tools') && !isNew"
          :agent-id="route.params.agentId"
          :department-id="departmentId"
        />

        <!-- INTEGRAÇÕES -->
        <div
          v-if="visibleSections.has('integrations')"
          class="flex flex-col gap-4"
        >
          <h2 class="text-base font-semibold text-n-slate-12">
            {{ $t('AI_DEPARTMENTS.INTEGRATIONS.TITLE') }}
          </h2>
          <p v-if="!integrations.length" class="text-sm text-n-slate-11">
            {{ $t('AI_DEPARTMENTS.INTEGRATIONS.EMPTY') }}
          </p>
          <div
            v-else
            class="border border-n-weak rounded-xl divide-y divide-n-weak"
          >
            <label
              v-for="i in integrations"
              :key="i.id"
              class="flex items-center gap-3 px-4 py-3 text-sm text-n-slate-12"
            >
              <input v-model="i.enabled" type="checkbox" />
              <span class="font-medium">{{ i.name }}</span>
            </label>
          </div>
          <div v-if="integrations.length" class="flex justify-end">
            <button
              type="button"
              :disabled="!integrationsDirty"
              class="text-sm font-medium px-3 py-2 rounded-lg bg-n-brand text-white disabled:opacity-50 disabled:cursor-not-allowed"
              @click="saveIntegrations"
            >
              {{ $t('AI_DEPARTMENTS.INTEGRATIONS.SAVE') }}
            </button>
          </div>
        </div>

        <!-- Save bar (config tabs only) -->
        <div
          v-if="showSave"
          class="flex justify-end gap-2 border-t border-n-weak pt-4"
        >
          <button
            v-if="!embedded"
            type="button"
            class="text-sm px-3 py-2 rounded-lg bg-n-alpha-2 text-n-slate-12"
            @click="goBack"
          >
            {{ $t('AI_DEPARTMENTS.FORM.CANCEL') }}
          </button>
          <button
            type="button"
            class="text-sm font-medium px-4 py-2 rounded-lg bg-n-brand text-white disabled:opacity-50 disabled:cursor-not-allowed"
            :disabled="isSaving || !deptDirty"
            @click="save"
          >
            {{ $t('AI_DEPARTMENTS.FORM.SAVE') }}
          </button>
        </div>
      </div>
    </div>
  </div>
</template>
