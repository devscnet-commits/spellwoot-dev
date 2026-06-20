<script setup>
/* global axios */
import { ref, reactive, computed, onMounted } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import Logo from 'next/icon/Logo.vue';
import AiTools from './AiTools.vue';
import AiKnowledge from './AiKnowledge.vue';

const route = useRoute();
const router = useRouter();
const { t } = useI18n();

const isNew = computed(() => route.params.departmentId === 'new');
const departmentId = ref(isNew.value ? null : route.params.departmentId);
const activeTab = ref('instructions');
const isSaving = ref(false);

const VAR_TYPES = ['texto', 'numero', 'booleano', 'lista'];

const form = reactive({
  name: '',
  objetivo: '',
  status: 'active',
  greeting: '',
  steps: '',
  transfer_when_steps: '',
  close_when_steps: '',
  // Atendimento
  auto_attendance: true,
  transfer_when: '',
  transfer_message: '',
  sla_timeout: '',
  on_timeout: 'resolve',
  hours_enabled: false,
  hours_message: '',
  close_when: '',
  close_inactivity: '',
  copilot_enabled: false,
  escalation_when: '',
  followup_enabled: false,
  followup_delay: '',
  followup_message: '',
  reply_scope: 'off',
  canary_label: '',
});

const agentUrl = () =>
  `/api/v1/accounts/${route.params.accountId}/ai_agents/${route.params.agentId}`;
const deptCollectionUrl = () => `${agentUrl()}/ai_departments`;

const linesToArray = value =>
  (value || '')
    .split('\n')
    .map(l => l.trim())
    .filter(Boolean);
const arrayToLines = value => (Array.isArray(value) ? value.join('\n') : '');

const hydrate = dept => {
  const playbook = dept.playbook || {};
  const behavior = dept.behavior || {};
  const transfer = dept.transfer_rules || {};
  const sla = dept.sla || {};
  const close = dept.close_rules || {};
  const followUp = dept.follow_up || {};
  Object.assign(form, {
    name: dept.name || '',
    objetivo: dept.objetivo || '',
    status: dept.status || 'active',
    greeting: playbook.default_messages?.greeting || '',
    steps: arrayToLines(playbook.steps),
    transfer_when_steps: arrayToLines(playbook.transfer_when),
    close_when_steps: arrayToLines(playbook.close_when),
    auto_attendance: behavior.auto_attendance !== false,
    transfer_when: arrayToLines(transfer.when),
    transfer_message: transfer.message || '',
    sla_timeout: sla.response_timeout_minutes ?? '',
    on_timeout: sla.on_timeout || 'resolve',
    hours_enabled: behavior.business_hours?.enabled || false,
    hours_message: behavior.business_hours?.message || '',
    close_when: arrayToLines(close.when),
    close_inactivity: close.inactivity_minutes ?? '',
    copilot_enabled: behavior.copilot?.enabled || false,
    escalation_when: arrayToLines(behavior.escalation?.when),
    followup_enabled: followUp.enabled || false,
    followup_delay: followUp.delay_minutes ?? '',
    followup_message: followUp.message || '',
    reply_scope: behavior.reply_scope || 'off',
    canary_label: behavior.canary_label || '',
  });
};

const fetchDepartment = async () => {
  if (isNew.value) return;
  const { data } = await axios.get(deptCollectionUrl());
  const dept = (Array.isArray(data) ? data : []).find(
    d => String(d.id) === String(departmentId.value)
  );
  if (dept) hydrate(dept);
};

const buildPayload = () => ({
  ai_department: {
    name: form.name,
    objetivo: form.objetivo,
    status: form.status,
    sla: {
      response_timeout_minutes: Number(form.sla_timeout) || 0,
      on_timeout: form.on_timeout,
    },
    transfer_rules: {
      when: linesToArray(form.transfer_when),
      message: form.transfer_message,
    },
    close_rules: {
      when: linesToArray(form.close_when),
      inactivity_minutes: Number(form.close_inactivity) || 0,
    },
    behavior: {
      auto_attendance: form.auto_attendance,
      business_hours: {
        enabled: form.hours_enabled,
        message: form.hours_message,
      },
      copilot: { enabled: form.copilot_enabled },
      escalation: { when: linesToArray(form.escalation_when) },
      reply_scope: form.reply_scope,
      canary_label: form.canary_label,
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
      default_messages: { greeting: form.greeting },
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

// --- Lead variables ---
const leadVars = ref([]);
const showVarForm = ref(false);
const varForm = reactive({
  id: null,
  name: '',
  description: '',
  var_type: 'texto',
  visible_in_first_chat: true,
  values: '',
});
const leadVarsUrl = () =>
  `${deptCollectionUrl()}/${departmentId.value}/ai_lead_variables`;

const fetchLeadVars = async () => {
  if (isNew.value) return;
  const { data } = await axios.get(leadVarsUrl());
  leadVars.value = Array.isArray(data) ? data : [];
};

const openVarNew = () => {
  Object.assign(varForm, {
    id: null,
    name: '',
    description: '',
    var_type: 'texto',
    visible_in_first_chat: true,
    values: '',
  });
  showVarForm.value = true;
};
const openVarEdit = v => {
  Object.assign(varForm, {
    id: v.id,
    name: v.name,
    description: v.description || '',
    var_type: v.var_type,
    visible_in_first_chat: v.visible_in_first_chat,
    values: arrayToLines(v.values),
  });
  showVarForm.value = true;
};
const saveVar = async () => {
  const payload = {
    ai_lead_variable: {
      name: varForm.name,
      description: varForm.description,
      var_type: varForm.var_type,
      visible_in_first_chat: varForm.visible_in_first_chat,
      values: linesToArray(varForm.values),
    },
  };
  try {
    if (varForm.id) {
      await axios.patch(`${leadVarsUrl()}/${varForm.id}`, payload);
    } else {
      await axios.post(leadVarsUrl(), payload);
    }
    showVarForm.value = false;
    fetchLeadVars();
  } catch (error) {
    useAlert(t('AI_DEPARTMENTS.ERROR'));
  }
};
const removeVar = async v => {
  // eslint-disable-next-line no-alert
  if (!window.confirm(t('AI_DEPARTMENTS.LEAD_VARS.CONFIRM_DELETE'))) return;
  await axios.delete(`${leadVarsUrl()}/${v.id}`);
  fetchLeadVars();
};

// --- Integrations ---
const integrations = ref([]);
const integrationsUrl = () =>
  `${deptCollectionUrl()}/${departmentId.value}/ai_department_integrations`;

const fetchIntegrations = async () => {
  if (isNew.value) return;
  const { data } = await axios.get(integrationsUrl());
  integrations.value = (Array.isArray(data) ? data : []).map(i => ({
    ...i,
    enabled: !!i.enabled,
  }));
};
const saveIntegrations = async () => {
  const ids = integrations.value.filter(i => i.enabled).map(i => i.id);
  try {
    await axios.put(integrationsUrl(), { integration_link_ids: ids });
    useAlert(t('AI_DEPARTMENTS.SAVED'));
  } catch (error) {
    useAlert(t('AI_DEPARTMENTS.ERROR'));
  }
};

// --- Inbox routing (caixa -> departamento) ---
const mappedInboxes = ref([]);
const inboxesUrl = () =>
  `${deptCollectionUrl()}/${departmentId.value}/ai_department_inboxes`;

const fetchMappedInboxes = async () => {
  if (isNew.value) return;
  const { data } = await axios.get(inboxesUrl());
  mappedInboxes.value = (Array.isArray(data) ? data : []).map(i => ({
    ...i,
    enabled: !!i.enabled,
  }));
};
const saveMappedInboxes = async () => {
  const ids = mappedInboxes.value.filter(i => i.enabled).map(i => i.inbox_id);
  try {
    await axios.put(inboxesUrl(), { inbox_ids: ids });
    useAlert(t('AI_DEPARTMENTS.SAVED'));
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
  await Promise.all([
    fetchLeadVars(),
    fetchIntegrations(),
    fetchMappedInboxes(),
    fetchVersions(),
  ]);
});
</script>

<template>
  <div class="w-full h-full overflow-auto bg-n-background p-4 sm:p-6">
    <div class="max-w-5xl mx-auto flex flex-col gap-3">
      <button
        type="button"
        class="self-start text-sm text-n-slate-11 hover:text-n-slate-12"
        @click="goBack"
      >
        {{ $t('AI_DEPARTMENTS.BACK') }}
      </button>

      <div
        class="rounded-2xl border border-n-weak bg-n-solid-1 px-6 sm:px-8 py-6 flex flex-col gap-5"
      >
        <div class="flex items-start justify-between gap-4">
          <h1 class="text-2xl font-semibold text-n-slate-12 truncate">
            {{ form.name || $t('AI_DEPARTMENTS.NEW') }}
          </h1>
          <Logo class="h-7 w-auto shrink-0" />
        </div>

        <div class="flex flex-wrap gap-1 border-b border-n-weak">
          <button
            v-for="tab in [
              'instructions',
              'attendance',
              'knowledge',
              'steps',
              'tools',
              'followup',
              'integrations',
            ]"
            :key="tab"
            type="button"
            class="px-4 py-2 text-sm font-medium border-b-2 -mb-px disabled:opacity-40"
            :class="
              activeTab === tab
                ? 'border-n-brand text-n-brand'
                : 'border-transparent text-n-slate-11'
            "
            :disabled="isNew && tab !== 'instructions'"
            @click="activeTab = tab"
          >
            {{ $t(`AI_DEPARTMENTS.DETAIL_TABS.${tab.toUpperCase()}`) }}
          </button>
        </div>

        <!-- INSTRUÇÕES -->
        <div v-if="activeTab === 'instructions'" class="flex flex-col gap-5">
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.FORM.NAME') }}
              <input
                v-model="form.name"
                type="text"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
              />
            </label>
            <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.FORM.GREETING') }}
              <input
                v-model="form.greeting"
                type="text"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
              />
            </label>
          </div>

          <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
            {{ $t('AI_DEPARTMENTS.INSTRUCTIONS_LABEL') }}
            <textarea
              v-model="form.objetivo"
              rows="5"
              :placeholder="$t('AI_DEPARTMENTS.INSTRUCTIONS_PLACEHOLDER')"
              class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none"
            />
          </label>

          <div class="flex flex-col gap-3">
            <span class="text-sm font-medium text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.LEAD_VARS.TITLE') }}
            </span>
            <p v-if="!leadVars.length" class="text-sm text-n-slate-11 mb-0">
              {{ $t('AI_DEPARTMENTS.LEAD_VARS.EMPTY') }}
            </p>
            <div
              v-for="v in leadVars"
              :key="v.id"
              class="flex items-center justify-between gap-3 rounded-xl border border-n-weak px-4 py-3"
            >
              <div class="min-w-0">
                <p
                  class="text-sm font-medium text-n-slate-12 flex items-center gap-2"
                >
                  {{ v.name }}
                  <span
                    class="inline-flex items-center px-2 py-0.5 rounded-md bg-n-alpha-2 text-xs font-normal text-n-slate-11"
                  >
                    {{ $t(`AI_DEPARTMENTS.LEAD_VARS.TYPES.${v.var_type}`) }}
                  </span>
                </p>
                <p class="text-xs text-n-slate-11 truncate mb-0">
                  {{ v.description }}
                </p>
              </div>
              <div class="shrink-0 flex items-center gap-2 text-n-slate-11">
                <button
                  type="button"
                  class="hover:text-n-slate-12"
                  :aria-label="$t('AI_DEPARTMENTS.LEAD_VARS.EDIT')"
                  @click="openVarEdit(v)"
                >
                  <span class="i-lucide-pencil size-4 inline-block" />
                </button>
                <button
                  type="button"
                  class="hover:text-n-ruby-11"
                  :aria-label="$t('AI_DEPARTMENTS.LEAD_VARS.DELETE')"
                  @click="removeVar(v)"
                >
                  <span class="i-lucide-trash-2 size-4 inline-block" />
                </button>
              </div>
            </div>
            <div class="flex justify-end">
              <button
                type="button"
                class="text-sm font-medium px-4 py-2 rounded-full bg-n-brand text-white disabled:opacity-50"
                :disabled="isNew"
                @click="openVarNew"
              >
                + {{ $t('AI_DEPARTMENTS.LEAD_VARS.NEW') }}
              </button>
            </div>
          </div>

          <!-- Modal: adicionar/editar variável -->
          <div
            v-if="showVarForm"
            class="fixed inset-0 z-50 flex items-center justify-center bg-n-alpha-black2 p-4"
            @click.self="showVarForm = false"
          >
            <div
              class="w-full max-w-md rounded-2xl border border-n-weak bg-n-solid-1 p-5 flex flex-col gap-3"
            >
              <h3 class="text-sm font-semibold text-n-slate-12">
                {{ $t('AI_DEPARTMENTS.LEAD_VARS.MODAL_TITLE') }}
              </h3>
              <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
                {{ $t('AI_DEPARTMENTS.LEAD_VARS.NAME') }}
                <input
                  v-model="varForm.name"
                  type="text"
                  class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
                />
              </label>
              <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
                {{ $t('AI_DEPARTMENTS.LEAD_VARS.DESCRIPTION') }}
                <input
                  v-model="varForm.description"
                  type="text"
                  class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
                />
              </label>
              <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
                {{ $t('AI_DEPARTMENTS.LEAD_VARS.TYPE') }}
                <select
                  v-model="varForm.var_type"
                  class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
                >
                  <option v-for="vt in VAR_TYPES" :key="vt" :value="vt">
                    {{ $t(`AI_DEPARTMENTS.LEAD_VARS.TYPES.${vt}`) }}
                  </option>
                </select>
              </label>
              <label
                v-if="varForm.var_type === 'lista'"
                class="flex flex-col gap-1.5 text-sm text-n-slate-12"
              >
                {{ $t('AI_DEPARTMENTS.LEAD_VARS.VALUES') }}
                <textarea
                  v-model="varForm.values"
                  rows="3"
                  class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none"
                />
              </label>
              <label class="flex items-center gap-2 text-sm text-n-slate-12">
                <input
                  v-model="varForm.visible_in_first_chat"
                  type="checkbox"
                />
                {{ $t('AI_DEPARTMENTS.LEAD_VARS.VISIBLE') }}
              </label>
              <div class="flex justify-end gap-2">
                <button
                  type="button"
                  class="text-sm px-3 py-2 rounded-lg bg-n-alpha-2 text-n-slate-12"
                  @click="showVarForm = false"
                >
                  {{ $t('AI_DEPARTMENTS.LEAD_VARS.CANCEL') }}
                </button>
                <button
                  type="button"
                  class="text-sm font-medium px-4 py-2 rounded-full bg-n-brand text-white"
                  @click="saveVar"
                >
                  + {{ $t('AI_DEPARTMENTS.LEAD_VARS.SAVE') }}
                </button>
              </div>
            </div>
          </div>
        </div>

        <!-- ATENDIMENTO -->
        <div
          v-else-if="activeTab === 'attendance'"
          class="flex flex-col gap-5 max-w-3xl"
        >
          <section class="flex flex-col gap-2">
            <h2 class="text-base font-semibold text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.AUTO_TITLE') }}
            </h2>
            <label class="flex items-center gap-2 text-sm text-n-slate-12">
              <input v-model="form.auto_attendance" type="checkbox" />
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.AUTO_TOGGLE') }}
            </label>
          </section>

          <section class="flex flex-col gap-2">
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
                  class="text-sm font-medium px-3 py-2 rounded-lg bg-n-alpha-2 text-n-slate-12"
                  @click="saveMappedInboxes"
                >
                  {{ $t('AI_DEPARTMENTS.ATTENDANCE.INBOXES_SAVE') }}
                </button>
              </div>
            </template>
          </section>

          <section class="flex flex-col gap-2">
            <h2 class="text-base font-semibold text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.REPLY_TITLE') }}
            </h2>
            <p class="text-sm text-n-slate-11 mb-0">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.REPLY_HINT') }}
            </p>
            <label class="flex flex-col gap-1 text-sm text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.REPLY_SCOPE') }}
              <select
                v-model="form.reply_scope"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
              >
                <option value="off">
                  {{ $t('AI_DEPARTMENTS.ATTENDANCE.REPLY_OFF') }}
                </option>
                <option value="canary">
                  {{ $t('AI_DEPARTMENTS.ATTENDANCE.REPLY_CANARY') }}
                </option>
                <option value="all">
                  {{ $t('AI_DEPARTMENTS.ATTENDANCE.REPLY_ALL') }}
                </option>
              </select>
            </label>
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

          <section class="flex flex-col gap-2">
            <h2 class="text-base font-semibold text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.TRANSFER_TITLE') }}
            </h2>
            <label class="flex flex-col gap-1 text-sm text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.TRANSFER_WHEN') }}
              <textarea
                v-model="form.transfer_when"
                rows="3"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none"
              />
            </label>
            <label class="flex flex-col gap-1 text-sm text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.TRANSFER_MESSAGE') }}
              <input
                v-model="form.transfer_message"
                type="text"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
              />
            </label>
          </section>

          <section class="flex flex-col gap-2">
            <h2 class="text-base font-semibold text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.SLA_TITLE') }}
            </h2>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                {{ $t('AI_DEPARTMENTS.ATTENDANCE.SLA_TIMEOUT') }}
                <input
                  v-model="form.sla_timeout"
                  type="number"
                  min="0"
                  class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
                />
              </label>
              <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                {{ $t('AI_DEPARTMENTS.ATTENDANCE.ON_TIMEOUT') }}
                <select
                  v-model="form.on_timeout"
                  class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
                >
                  <option value="resolve">
                    {{ $t('AI_DEPARTMENTS.ATTENDANCE.ON_TIMEOUT_RESOLVE') }}
                  </option>
                  <option value="none">
                    {{ $t('AI_DEPARTMENTS.ATTENDANCE.ON_TIMEOUT_NONE') }}
                  </option>
                </select>
              </label>
            </div>
          </section>

          <section class="flex flex-col gap-2">
            <h2 class="text-base font-semibold text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.HOURS_TITLE') }}
            </h2>
            <label class="flex items-center gap-2 text-sm text-n-slate-12">
              <input v-model="form.hours_enabled" type="checkbox" />
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.HOURS_TOGGLE') }}
            </label>
            <label class="flex flex-col gap-1 text-sm text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.HOURS_MESSAGE') }}
              <input
                v-model="form.hours_message"
                type="text"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
              />
            </label>
          </section>

          <section class="flex flex-col gap-2">
            <h2 class="text-base font-semibold text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.CLOSE_TITLE') }}
            </h2>
            <label class="flex flex-col gap-1 text-sm text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.CLOSE_WHEN') }}
              <textarea
                v-model="form.close_when"
                rows="3"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none"
              />
            </label>
            <label class="flex flex-col gap-1 text-sm text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.CLOSE_INACTIVITY') }}
              <input
                v-model="form.close_inactivity"
                type="number"
                min="0"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
              />
            </label>
          </section>

          <section class="flex flex-col gap-2">
            <h2 class="text-base font-semibold text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.COPILOT_TITLE') }}
            </h2>
            <label class="flex items-center gap-2 text-sm text-n-slate-12">
              <input v-model="form.copilot_enabled" type="checkbox" />
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.COPILOT_TOGGLE') }}
            </label>
          </section>

          <section class="flex flex-col gap-2">
            <h2 class="text-base font-semibold text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.ESCALATION_TITLE') }}
            </h2>
            <label class="flex flex-col gap-1 text-sm text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.ESCALATION_WHEN') }}
              <textarea
                v-model="form.escalation_when"
                rows="3"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none"
              />
            </label>
          </section>
        </div>

        <!-- FOLLOW-UP -->
        <div
          v-else-if="activeTab === 'followup'"
          class="flex flex-col gap-5 max-w-3xl"
        >
          <section class="flex flex-col gap-2">
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
        <div
          v-else-if="activeTab === 'steps'"
          class="flex flex-col gap-4 max-w-3xl"
        >
          <label class="flex flex-col gap-1 text-sm text-n-slate-12">
            {{ $t('AI_DEPARTMENTS.FORM.STEPS') }}
            <textarea
              v-model="form.steps"
              rows="5"
              class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none"
            />
          </label>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <label class="flex flex-col gap-1 text-sm text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.FORM.TRANSFER_WHEN') }}
              <textarea
                v-model="form.transfer_when_steps"
                rows="3"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none"
              />
            </label>
            <label class="flex flex-col gap-1 text-sm text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.FORM.CLOSE_WHEN') }}
              <textarea
                v-model="form.close_when_steps"
                rows="3"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none"
              />
            </label>
          </div>

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

        <!-- CONHECIMENTO -->
        <AiKnowledge v-else-if="activeTab === 'knowledge' && !isNew" />

        <!-- FERRAMENTAS -->
        <AiTools v-else-if="activeTab === 'tools' && !isNew" />

        <!-- INTEGRAÇÕES -->
        <div
          v-else-if="activeTab === 'integrations'"
          class="flex flex-col gap-4 max-w-3xl"
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
              class="text-sm font-medium px-3 py-2 rounded-lg bg-n-brand text-white"
              @click="saveIntegrations"
            >
              {{ $t('AI_DEPARTMENTS.INTEGRATIONS.SAVE') }}
            </button>
          </div>
        </div>

        <!-- Save bar (config tabs only) -->
        <div
          v-if="
            ['instructions', 'attendance', 'steps', 'followup'].includes(
              activeTab
            )
          "
          class="flex justify-end gap-2 border-t border-n-weak pt-4 max-w-3xl"
        >
          <button
            type="button"
            class="text-sm px-3 py-2 rounded-lg bg-n-alpha-2 text-n-slate-12"
            @click="goBack"
          >
            {{ $t('AI_DEPARTMENTS.FORM.CANCEL') }}
          </button>
          <button
            type="button"
            class="text-sm font-medium px-4 py-2 rounded-lg bg-n-brand text-white disabled:opacity-50"
            :disabled="isSaving"
            @click="save"
          >
            {{ $t('AI_DEPARTMENTS.FORM.SAVE') }}
          </button>
        </div>
      </div>
    </div>
  </div>
</template>
