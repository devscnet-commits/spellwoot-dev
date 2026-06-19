<script setup>
/* global axios */
import { ref, reactive, computed, onMounted } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';
import AiKnowledge from './AiKnowledge.vue';
import AiTools from './AiTools.vue';

const route = useRoute();
const router = useRouter();
const { t } = useI18n();

const isNew = computed(() => route.params.agentId === 'new');
const agentId = ref(isNew.value ? null : route.params.agentId);

// The agent opens directly on the mockup's configuration tabs. Caixas and Teste are kept as
// operational tabs after the creation flow. Department config is edited on a default department.
const TAB_KEYS = [
  'about',
  'instructions',
  'behavior',
  'knowledge',
  'steps',
  'tools',
  'followup',
  'inboxes',
  'test',
];
const activeKey = ref(route.query.tab === 'test' ? 'test' : 'about');
const tabs = computed(() =>
  TAB_KEYS.map(key => ({
    key,
    label: t(`AI_AGENTS.TABS.${key.toUpperCase()}`),
  }))
);
const activeIndex = computed(() => TAB_KEYS.indexOf(activeKey.value));
const onTabChanged = tab => {
  const found = tabs.value.find(x => x.label === tab.label);
  if (found) activeKey.value = found.key;
};

const profiles = ref([]);
const isSaving = ref(false);
const defaultDeptId = ref(null);

const accountUrl = () => `/api/v1/accounts/${route.params.accountId}`;
const agentUrl = () => `${accountUrl()}/ai_agents`;
const deptUrl = () => `${agentUrl()}/${agentId.value}/ai_departments`;

const linesToArray = v =>
  (v || '')
    .split('\n')
    .map(l => l.trim())
    .filter(Boolean);
const arrayToLines = v => (Array.isArray(v) ? v.join('\n') : '');

// --- Agent identity (Sobre) ---
const agentForm = reactive({
  name: '',
  assistant_name: '',
  company_name: '',
  site: '',
  version: '',
  identify_as: 'human',
  assistant_avatar: '',
  ai_operation_profile_id: '',
  assistant_description: '',
  assistant_personality: '',
  base_prompt: '',
  guardrails: '',
  stage: 'sandbox',
  status: 'active',
});

const profileOptions = computed(() => [
  { value: '', label: t('AI_AGENTS.FORM.NONE') },
  ...profiles.value.map(p => ({ value: p.id, label: p.name })),
]);

const fetchProfiles = async () => {
  const { data } = await axios.get(`${accountUrl()}/ai_operation_profiles`);
  profiles.value = Array.isArray(data) ? data : [];
};

const fetchAgent = async () => {
  if (isNew.value) return;
  const { data } = await axios.get(`${agentUrl()}/${agentId.value}`);
  Object.keys(agentForm).forEach(k => {
    if (data[k] !== undefined && data[k] !== null) agentForm[k] = data[k];
  });
};

const onAvatarUpload = ({ file }) => {
  const reader = new FileReader();
  reader.onload = e => {
    agentForm.assistant_avatar = e.target.result;
  };
  reader.readAsDataURL(file);
};
const onAvatarDelete = () => {
  agentForm.assistant_avatar = '';
};
const generateAvatar = () => useAlert(t('AI_AGENTS.SOBRE.GENERATE_SOON'));

const saveAgent = async () => {
  isSaving.value = true;
  const payload = {
    ...agentForm,
    name: agentForm.name || agentForm.assistant_name,
  };
  try {
    if (isNew.value) {
      const { data } = await axios.post(agentUrl(), { ai_agent: payload });
      agentId.value = data.id;
      router.replace({ name: 'ai_agent_detail', params: { agentId: data.id } });
      // eslint-disable-next-line no-use-before-define
      await ensureDefaultDepartment();
    } else {
      await axios.patch(`${agentUrl()}/${agentId.value}`, {
        ai_agent: payload,
      });
    }
    useAlert(t('AI_AGENTS.SAVED'));
  } catch (error) {
    useAlert(t('AI_AGENTS.ERROR'));
  } finally {
    isSaving.value = false;
  }
};

// --- Default department (backs Instruções / Comportamento / Etapas / Follow-up / Conhecimento / Ferramentas) ---
const deptForm = reactive({
  objetivo: '',
  greeting: '',
  steps: [],
  transfer_when_steps: '',
  close_when_steps: '',
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
  reply_scope: 'off',
  canary_label: '',
  followup_enabled: false,
  followup_delay: '',
  followup_message: '',
});

const hydrateDept = dept => {
  defaultDeptId.value = dept.id;
  const pb = dept.playbook || {};
  const b = dept.behavior || {};
  const transfer = dept.transfer_rules || {};
  const sla = dept.sla || {};
  const close = dept.close_rules || {};
  const fu = dept.follow_up || {};
  Object.assign(deptForm, {
    objetivo: dept.objetivo || '',
    greeting: pb.default_messages?.greeting || '',
    steps: Array.isArray(pb.steps) ? [...pb.steps] : [],
    transfer_when_steps: arrayToLines(pb.transfer_when),
    close_when_steps: arrayToLines(pb.close_when),
    auto_attendance: b.auto_attendance !== false,
    transfer_when: arrayToLines(transfer.when),
    transfer_message: transfer.message || '',
    sla_timeout: sla.response_timeout_minutes ?? '',
    on_timeout: sla.on_timeout || 'resolve',
    hours_enabled: b.business_hours?.enabled || false,
    hours_message: b.business_hours?.message || '',
    close_when: arrayToLines(close.when),
    close_inactivity: close.inactivity_minutes ?? '',
    copilot_enabled: b.copilot?.enabled || false,
    escalation_when: arrayToLines(b.escalation?.when),
    reply_scope: b.reply_scope || 'off',
    canary_label: b.canary_label || '',
    followup_enabled: fu.enabled || false,
    followup_delay: fu.delay_minutes ?? '',
    followup_message: fu.message || '',
  });
};

const ensureDefaultDepartment = async () => {
  if (isNew.value || !agentId.value) return;
  const { data } = await axios.get(deptUrl());
  const list = Array.isArray(data) ? data : [];
  if (list.length) {
    hydrateDept(list[0]);
  } else {
    const { data: created } = await axios.post(deptUrl(), {
      ai_department: {
        name: agentForm.assistant_name || 'Atendimento',
        status: 'active',
      },
    });
    hydrateDept(created);
  }
  // eslint-disable-next-line no-use-before-define
  fetchLeadVars();
};

const deptPayload = () => ({
  ai_department: {
    objetivo: deptForm.objetivo,
    sla: {
      response_timeout_minutes: Number(deptForm.sla_timeout) || 0,
      on_timeout: deptForm.on_timeout,
    },
    transfer_rules: {
      when: linesToArray(deptForm.transfer_when),
      message: deptForm.transfer_message,
    },
    close_rules: {
      when: linesToArray(deptForm.close_when),
      inactivity_minutes: Number(deptForm.close_inactivity) || 0,
    },
    behavior: {
      auto_attendance: deptForm.auto_attendance,
      business_hours: {
        enabled: deptForm.hours_enabled,
        message: deptForm.hours_message,
      },
      copilot: { enabled: deptForm.copilot_enabled },
      escalation: { when: linesToArray(deptForm.escalation_when) },
      reply_scope: deptForm.reply_scope,
      canary_label: deptForm.canary_label,
    },
    follow_up: {
      enabled: deptForm.followup_enabled,
      delay_minutes: Number(deptForm.followup_delay) || 0,
      message: deptForm.followup_message,
    },
    playbook: {
      objetivo: deptForm.objetivo,
      steps: deptForm.steps.map(s => s.trim()).filter(Boolean),
      transfer_when: linesToArray(deptForm.transfer_when_steps),
      close_when: linesToArray(deptForm.close_when_steps),
      default_messages: { greeting: deptForm.greeting },
    },
  },
});

const saveDept = async () => {
  if (!defaultDeptId.value) return;
  isSaving.value = true;
  try {
    await axios.patch(`${deptUrl()}/${defaultDeptId.value}`, deptPayload());
    useAlert(t('AI_AGENTS.SAVED'));
  } catch (error) {
    useAlert(t('AI_AGENTS.ERROR'));
  } finally {
    isSaving.value = false;
  }
};

// Etapas — process builder (add / remove / reorder).
const addStep = () => deptForm.steps.push('');
const removeStep = i => deptForm.steps.splice(i, 1);
const moveStep = (i, dir) => {
  const j = i + dir;
  if (j < 0 || j >= deptForm.steps.length) return;
  const arr = deptForm.steps;
  [arr[i], arr[j]] = [arr[j], arr[i]];
};

// --- Lead variables (Instruções) ---
const leadVars = ref([]);
const leadVarsUrl = () =>
  `${deptUrl()}/${defaultDeptId.value}/ai_lead_variables`;
const fetchLeadVars = async () => {
  if (!defaultDeptId.value) return;
  const { data } = await axios.get(leadVarsUrl());
  leadVars.value = Array.isArray(data) ? data : [];
};
const newVarName = ref('');
const addLeadVar = async () => {
  if (!newVarName.value.trim() || !defaultDeptId.value) return;
  await axios.post(leadVarsUrl(), {
    ai_lead_variable: {
      name: newVarName.value.trim(),
      var_type: 'texto',
      visible_in_first_chat: true,
    },
  });
  newVarName.value = '';
  fetchLeadVars();
};
const removeLeadVar = async v => {
  await axios.delete(`${leadVarsUrl()}/${v.id}`);
  fetchLeadVars();
};

// --- Caixas (live/shadow binding) ---
const inboxes = ref([]);
const inboxesUrl = () => `${agentUrl()}/${agentId.value}/ai_agent_inboxes`;
const fetchInboxes = async () => {
  if (isNew.value) return;
  const { data } = await axios.get(inboxesUrl());
  inboxes.value = Array.isArray(data) ? data : [];
};
const saveInboxes = async () => {
  try {
    await axios.put(inboxesUrl(), {
      bindings: inboxes.value.map(i => ({
        inbox_id: i.inbox_id,
        mode: i.mode,
      })),
    });
    useAlert(t('AI_AGENTS.SAVED'));
  } catch (error) {
    useAlert(t('AI_AGENTS.ERROR'));
  }
};

// --- Teste ---
const testMessage = ref('');
const testResult = ref(null);
const isTesting = ref(false);
const runTest = async () => {
  if (!testMessage.value.trim() || isNew.value) return;
  isTesting.value = true;
  testResult.value = null;
  try {
    const { data } = await axios.post(`${agentUrl()}/${agentId.value}/test`, {
      message: testMessage.value,
    });
    testResult.value = data;
  } catch (error) {
    useAlert(t('AI_AGENTS.ERROR'));
  } finally {
    isTesting.value = false;
  }
};

const goBack = () => router.push({ name: 'ai_agents_index' });

onMounted(async () => {
  await fetchProfiles();
  await fetchAgent();
  await Promise.all([ensureDefaultDepartment(), fetchInboxes()]);
});
</script>

<template>
  <div class="flex flex-col w-full h-full overflow-auto">
    <div class="flex items-center gap-3 px-6 pt-6">
      <button
        type="button"
        class="text-sm text-n-slate-11 hover:text-n-slate-12"
        @click="goBack"
      >
        {{ $t('AI_AGENTS.BACK') }}
      </button>
    </div>

    <!-- Hero / assistant identity header -->
    <div class="flex items-center gap-4 px-6 pt-4 pb-5">
      <Avatar
        :src="agentForm.assistant_avatar"
        :name="agentForm.assistant_name || agentForm.name || 'IA'"
        :size="72"
        rounded-full
        allow-upload
        @upload="onAvatarUpload"
        @delete="onAvatarDelete"
      />
      <div class="flex flex-col gap-1">
        <h1 class="text-xl font-semibold text-n-slate-12">
          {{
            agentForm.assistant_name || agentForm.name || $t('AI_AGENTS.NEW')
          }}
        </h1>
        <p class="text-sm text-n-slate-11 mb-0">
          {{ agentForm.company_name || $t('AI_AGENTS.DESCRIPTION') }}
        </p>
        <button
          type="button"
          class="text-xs text-n-brand hover:underline text-left mt-0.5"
          @click="generateAvatar"
        >
          {{ $t('AI_AGENTS.SOBRE.GENERATE') }}
        </button>
      </div>
    </div>

    <div class="px-6">
      <TabBar
        :tabs="tabs"
        :initial-active-tab="activeIndex"
        @tab-changed="onTabChanged"
      />
    </div>

    <div class="px-6 py-6 flex flex-col gap-6 max-w-3xl">
      <!-- SOBRE -->
      <template v-if="activeKey === 'about'">
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <Input
            v-model="agentForm.assistant_name"
            :label="$t('AI_AGENTS.SOBRE.AGENT_NAME')"
          />
          <Input
            v-model="agentForm.company_name"
            :label="$t('AI_AGENTS.SOBRE.COMPANY')"
          />
          <Input v-model="agentForm.site" :label="$t('AI_AGENTS.SOBRE.SITE')" />
          <Input
            v-model="agentForm.version"
            :label="$t('AI_AGENTS.SOBRE.VERSION')"
          />
        </div>

        <div class="flex flex-col gap-1.5">
          <span class="text-sm font-medium text-n-slate-12">{{
            $t('AI_AGENTS.SOBRE.MODEL')
          }}</span>
          <Select
            v-model="agentForm.ai_operation_profile_id"
            :options="profileOptions"
          />
        </div>

        <div class="flex flex-col gap-2">
          <span class="text-sm font-medium text-n-slate-12">{{
            $t('AI_AGENTS.IDENTIFY_AS.LABEL')
          }}</span>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <button
              type="button"
              class="flex flex-col items-start gap-1 text-left px-4 py-3 rounded-xl border transition-colors"
              :class="
                agentForm.identify_as === 'human'
                  ? 'border-n-brand bg-n-brand/5'
                  : 'border-n-weak hover:border-n-slate-7'
              "
              @click="agentForm.identify_as = 'human'"
            >
              <span class="i-lucide-user-round size-5 text-n-slate-11" />
              <span class="text-sm font-medium text-n-slate-12">{{
                $t('AI_AGENTS.IDENTIFY_AS.HUMAN')
              }}</span>
              <span class="text-xs text-n-slate-11">{{
                $t('AI_AGENTS.IDENTIFY_AS.HUMAN_HINT')
              }}</span>
            </button>
            <button
              type="button"
              class="flex flex-col items-start gap-1 text-left px-4 py-3 rounded-xl border transition-colors"
              :class="
                agentForm.identify_as === 'ai'
                  ? 'border-n-brand bg-n-brand/5'
                  : 'border-n-weak hover:border-n-slate-7'
              "
              @click="agentForm.identify_as = 'ai'"
            >
              <span class="i-lucide-bot size-5 text-n-slate-11" />
              <span class="text-sm font-medium text-n-slate-12">{{
                $t('AI_AGENTS.IDENTIFY_AS.AI')
              }}</span>
              <span class="text-xs text-n-slate-11">{{
                $t('AI_AGENTS.IDENTIFY_AS.AI_HINT')
              }}</span>
            </button>
          </div>
        </div>

        <div class="flex justify-end">
          <Button
            :label="$t('AI_AGENTS.FORM.SAVE')"
            :is-loading="isSaving"
            @click="saveAgent"
          />
        </div>
      </template>

      <!-- INSTRUÇÕES -->
      <template v-else-if="activeKey === 'instructions'">
        <p v-if="isNew" class="text-sm text-n-slate-11">
          {{ $t('AI_AGENTS.SAVE_FIRST') }}
        </p>
        <template v-else>
          <TextArea
            v-model="agentForm.base_prompt"
            :label="$t('AI_AGENTS.FORM.BASE_PROMPT')"
            :max-length="4000"
          />
          <TextArea
            v-model="agentForm.assistant_personality"
            :label="$t('AI_AGENTS.FORM.ASSISTANT_PERSONALITY')"
            :max-length="1000"
          />
          <TextArea
            v-model="agentForm.guardrails"
            :label="$t('AI_AGENTS.FORM.GUARDRAILS')"
            :max-length="2000"
          />
          <Input
            v-model="deptForm.objetivo"
            :label="$t('AI_DEPARTMENTS.FORM.OBJETIVO')"
          />
          <Input
            v-model="deptForm.greeting"
            :label="$t('AI_DEPARTMENTS.FORM.GREETING')"
          />

          <div class="flex flex-col gap-2">
            <span class="text-sm font-medium text-n-slate-12">{{
              $t('AI_DEPARTMENTS.LEAD_VARS.TITLE')
            }}</span>
            <div class="flex flex-wrap gap-2">
              <span
                v-for="v in leadVars"
                :key="v.id"
                class="inline-flex items-center gap-1 px-2 py-1 rounded-lg bg-n-alpha-2 text-xs text-n-slate-12"
              >
                {{ v.name }}
                <button
                  type="button"
                  class="text-n-slate-11 hover:text-n-ruby-11"
                  :aria-label="$t('AI_DEPARTMENTS.LEAD_VARS.DELETE')"
                  @click="removeLeadVar(v)"
                >
                  <span class="i-lucide-x size-3 inline-block" />
                </button>
              </span>
            </div>
            <div class="flex gap-2">
              <Input
                v-model="newVarName"
                :placeholder="$t('AI_DEPARTMENTS.LEAD_VARS.NAME')"
                class="flex-1"
              />
              <Button
                variant="faded"
                :label="$t('AI_DEPARTMENTS.LEAD_VARS.NEW')"
                @click="addLeadVar"
              />
            </div>
          </div>

          <div class="flex justify-end">
            <Button
              :label="$t('AI_AGENTS.FORM.SAVE')"
              :is-loading="isSaving"
              @click="saveAgent().then(saveDept)"
            />
          </div>
        </template>
      </template>

      <!-- COMPORTAMENTO -->
      <template v-else-if="activeKey === 'behavior'">
        <p v-if="isNew" class="text-sm text-n-slate-11">
          {{ $t('AI_AGENTS.SAVE_FIRST') }}
        </p>
        <template v-else>
          <label
            class="flex items-center justify-between gap-3 text-sm text-n-slate-12"
          >
            {{ $t('AI_DEPARTMENTS.ATTENDANCE.AUTO_TOGGLE') }}
            <Switch v-model="deptForm.auto_attendance" />
          </label>
          <TextArea
            v-model="deptForm.transfer_when"
            :label="$t('AI_DEPARTMENTS.ATTENDANCE.TRANSFER_WHEN')"
            :max-length="1000"
          />
          <Input
            v-model="deptForm.transfer_message"
            :label="$t('AI_DEPARTMENTS.ATTENDANCE.TRANSFER_MESSAGE')"
          />
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <Input
              v-model="deptForm.sla_timeout"
              type="number"
              :label="$t('AI_DEPARTMENTS.ATTENDANCE.SLA_TIMEOUT')"
            />
            <div class="flex flex-col gap-1.5">
              <span class="text-sm font-medium text-n-slate-12">{{
                $t('AI_DEPARTMENTS.ATTENDANCE.ON_TIMEOUT')
              }}</span>
              <Select
                v-model="deptForm.on_timeout"
                :options="[
                  {
                    value: 'resolve',
                    label: $t('AI_DEPARTMENTS.ATTENDANCE.ON_TIMEOUT_RESOLVE'),
                  },
                  {
                    value: 'none',
                    label: $t('AI_DEPARTMENTS.ATTENDANCE.ON_TIMEOUT_NONE'),
                  },
                ]"
              />
            </div>
          </div>
          <label
            class="flex items-center justify-between gap-3 text-sm text-n-slate-12"
          >
            {{ $t('AI_DEPARTMENTS.ATTENDANCE.HOURS_TOGGLE') }}
            <Switch v-model="deptForm.hours_enabled" />
          </label>
          <label
            class="flex items-center justify-between gap-3 text-sm text-n-slate-12"
          >
            {{ $t('AI_DEPARTMENTS.ATTENDANCE.COPILOT_TOGGLE') }}
            <Switch v-model="deptForm.copilot_enabled" />
          </label>
          <TextArea
            v-model="deptForm.escalation_when"
            :label="$t('AI_DEPARTMENTS.ATTENDANCE.ESCALATION_WHEN')"
            :max-length="1000"
          />
          <div class="flex justify-end">
            <Button
              :label="$t('AI_AGENTS.FORM.SAVE')"
              :is-loading="isSaving"
              @click="saveDept"
            />
          </div>
        </template>
      </template>

      <!-- CONHECIMENTO -->
      <AiKnowledge
        v-else-if="activeKey === 'knowledge' && !isNew && defaultDeptId"
        :agent-id="agentId"
        :department-id="defaultDeptId"
      />
      <p v-else-if="activeKey === 'knowledge'" class="text-sm text-n-slate-11">
        {{ $t('AI_AGENTS.SAVE_FIRST') }}
      </p>

      <!-- ETAPAS (construtor de processo) -->
      <template v-else-if="activeKey === 'steps'">
        <p v-if="isNew" class="text-sm text-n-slate-11">
          {{ $t('AI_AGENTS.SAVE_FIRST') }}
        </p>
        <template v-else>
          <p class="text-sm text-n-slate-11 mb-0">
            {{ $t('AI_AGENTS.STEPS.HINT') }}
          </p>
          <div class="flex flex-col gap-2">
            <div
              v-for="(step, i) in deptForm.steps"
              :key="i"
              class="flex items-center gap-2"
            >
              <span class="text-xs text-n-slate-11 w-5 text-center">{{
                i + 1
              }}</span>
              <Input v-model="deptForm.steps[i]" class="flex-1" />
              <button
                type="button"
                class="text-n-slate-11 hover:text-n-slate-12 px-1"
                :disabled="i === 0"
                @click="moveStep(i, -1)"
              >
                <span class="i-lucide-arrow-up size-4 inline-block" />
              </button>
              <button
                type="button"
                class="text-n-slate-11 hover:text-n-slate-12 px-1"
                :disabled="i === deptForm.steps.length - 1"
                @click="moveStep(i, 1)"
              >
                <span class="i-lucide-arrow-down size-4 inline-block" />
              </button>
              <button
                type="button"
                class="text-n-ruby-11 px-1"
                @click="removeStep(i)"
              >
                <span class="i-lucide-trash-2 size-4 inline-block" />
              </button>
            </div>
          </div>
          <div>
            <Button
              variant="faded"
              icon="i-lucide-plus"
              :label="$t('AI_AGENTS.STEPS.ADD')"
              @click="addStep"
            />
          </div>
          <div class="flex justify-end">
            <Button
              :label="$t('AI_AGENTS.FORM.SAVE')"
              :is-loading="isSaving"
              @click="saveDept"
            />
          </div>
        </template>
      </template>

      <!-- FERRAMENTAS -->
      <AiTools
        v-else-if="activeKey === 'tools' && !isNew && defaultDeptId"
        :agent-id="agentId"
        :department-id="defaultDeptId"
      />
      <p v-else-if="activeKey === 'tools'" class="text-sm text-n-slate-11">
        {{ $t('AI_AGENTS.SAVE_FIRST') }}
      </p>

      <!-- FOLLOW-UP -->
      <template v-else-if="activeKey === 'followup'">
        <p v-if="isNew" class="text-sm text-n-slate-11">
          {{ $t('AI_AGENTS.SAVE_FIRST') }}
        </p>
        <template v-else>
          <label
            class="flex items-center justify-between gap-3 text-sm text-n-slate-12"
          >
            {{ $t('AI_DEPARTMENTS.ATTENDANCE.FOLLOWUP_TOGGLE') }}
            <Switch v-model="deptForm.followup_enabled" />
          </label>
          <Input
            v-model="deptForm.followup_delay"
            type="number"
            :label="$t('AI_DEPARTMENTS.ATTENDANCE.FOLLOWUP_DELAY')"
          />
          <TextArea
            v-model="deptForm.followup_message"
            :label="$t('AI_DEPARTMENTS.ATTENDANCE.FOLLOWUP_MESSAGE')"
            :max-length="500"
          />
          <div class="flex justify-end">
            <Button
              :label="$t('AI_AGENTS.FORM.SAVE')"
              :is-loading="isSaving"
              @click="saveDept"
            />
          </div>
        </template>
      </template>

      <!-- CAIXAS -->
      <template v-else-if="activeKey === 'inboxes'">
        <div class="flex flex-col gap-1">
          <span class="text-sm font-medium text-n-slate-12">{{
            $t('AI_AGENTS.INBOXES.TITLE')
          }}</span>
          <p class="text-sm text-n-slate-11 mb-0">
            {{ $t('AI_AGENTS.INBOXES.DESCRIPTION') }}
          </p>
        </div>
        <p v-if="isNew" class="text-sm text-n-slate-11">
          {{ $t('AI_AGENTS.SAVE_FIRST') }}
        </p>
        <p v-else-if="!inboxes.length" class="text-sm text-n-slate-11">
          {{ $t('AI_AGENTS.INBOXES.EMPTY') }}
        </p>
        <template v-else>
          <div class="border border-n-weak rounded-xl divide-y divide-n-weak">
            <div
              v-for="inbox in inboxes"
              :key="inbox.inbox_id"
              class="flex items-center justify-between gap-3 px-4 py-3"
            >
              <span class="text-sm text-n-slate-12 truncate">{{
                inbox.name
              }}</span>
              <select
                v-model="inbox.mode"
                class="shrink-0 px-3 py-1.5 rounded-lg border border-n-weak bg-n-solid-1 text-sm"
              >
                <option value="none">{{ $t('AI_AGENTS.INBOXES.NONE') }}</option>
                <option value="shadow">
                  {{ $t('AI_AGENTS.INBOXES.SHADOW') }}
                </option>
                <option value="live">{{ $t('AI_AGENTS.INBOXES.LIVE') }}</option>
              </select>
            </div>
          </div>
          <div class="flex justify-end">
            <Button
              variant="faded"
              :label="$t('AI_AGENTS.INBOXES.SAVE')"
              @click="saveInboxes"
            />
          </div>
        </template>
      </template>

      <!-- TESTE -->
      <template v-else-if="activeKey === 'test'">
        <p v-if="isNew" class="text-sm text-n-slate-11">
          {{ $t('AI_AGENTS.SAVE_FIRST') }}
        </p>
        <template v-else>
          <TextArea
            v-model="testMessage"
            :label="$t('AI_AGENTS.TEST.TITLE')"
            :placeholder="$t('AI_AGENTS.TEST.PLACEHOLDER')"
            :max-length="1000"
          />
          <div class="flex justify-end">
            <Button
              :label="$t('AI_AGENTS.TEST.SEND')"
              :is-loading="isTesting"
              @click="runTest"
            />
          </div>
          <div
            v-if="testResult"
            class="border border-n-weak rounded-xl p-4 flex flex-col gap-3 bg-n-solid-2"
          >
            <p v-if="testResult.error" class="text-sm text-n-ruby-11">
              {{ testResult.error }}
            </p>
            <template v-else>
              <div class="flex flex-col gap-1">
                <span class="text-xs text-n-slate-11">{{
                  $t('AI_AGENTS.TEST.REPLY')
                }}</span>
                <p class="text-sm text-n-slate-12 whitespace-pre-wrap">
                  {{ testResult.reply || $t('AI_AGENTS.TEST.NONE') }}
                </p>
              </div>
              <div class="grid grid-cols-2 sm:grid-cols-3 gap-3 text-sm">
                <div>
                  <span class="block text-xs text-n-slate-11">{{
                    $t('AI_AGENTS.TEST.DEPARTMENT')
                  }}</span>
                  <span class="text-n-slate-12">{{
                    testResult.department || $t('AI_AGENTS.TEST.NONE')
                  }}</span>
                </div>
                <div>
                  <span class="block text-xs text-n-slate-11">{{
                    $t('AI_AGENTS.TEST.SCORE')
                  }}</span>
                  <span class="text-n-slate-12">{{
                    testResult.vector_score ?? $t('AI_AGENTS.TEST.NONE')
                  }}</span>
                </div>
                <div>
                  <span class="block text-xs text-n-slate-11">{{
                    $t('AI_AGENTS.TEST.WORKER')
                  }}</span>
                  <span class="text-n-slate-12">{{
                    testResult.worker
                      ? $t(`AI_AGENTS.TEST.WORKERS.${testResult.worker}`)
                      : $t('AI_AGENTS.TEST.NONE')
                  }}</span>
                </div>
                <div>
                  <span class="block text-xs text-n-slate-11">{{
                    $t('AI_AGENTS.TEST.MODEL')
                  }}</span>
                  <span class="text-n-slate-12">{{
                    testResult.model || $t('AI_AGENTS.TEST.NONE')
                  }}</span>
                </div>
                <div>
                  <span class="block text-xs text-n-slate-11">{{
                    $t('AI_AGENTS.TEST.TOKENS')
                  }}</span>
                  <span class="text-n-slate-12">{{
                    (testResult.tokens_in ?? 0) +
                    ' / ' +
                    (testResult.tokens_out ?? 0)
                  }}</span>
                </div>
                <div>
                  <span class="block text-xs text-n-slate-11">{{
                    $t('AI_AGENTS.TEST.COST')
                  }}</span>
                  <span class="text-n-slate-12">{{
                    testResult.cost ?? $t('AI_AGENTS.TEST.NONE')
                  }}</span>
                </div>
              </div>
            </template>
          </div>
        </template>
      </template>
    </div>
  </div>
</template>
