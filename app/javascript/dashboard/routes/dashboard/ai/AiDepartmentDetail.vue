<script setup>
/* global axios */
import { ref, reactive, computed, onMounted } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import Logo from 'next/icon/Logo.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import TagInput from 'dashboard/components-next/taginput/TagInput.vue';
import Draggable from 'vuedraggable';
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
  behavior: ['instructions', 'attendance'],
  followup: ['followup'],
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

const form = reactive({
  name: '',
  objetivo: '',
  instructions: '',
  status: 'active',
  steps: [],
  transfer_when_steps: '',
  close_when_steps: '',
  // Atendimento
  group_delay_seconds: '',
  max_replies: '',
  max_input_chars: '',
  // Follow-up: várias tentativas de envio (não há mais "Ativar" — vazio = desligado).
  followup_instructions: '',
  followup_attempts: [],
  followup_schedule: 'inbox_hours',
  followup_custom_windows: [],
  followup_grace: 30,
  followup_when_online: false,
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

// --- Variáveis do lead: dados que a IA coleta na conversa e salva no banco ---
// Vão para o prompt como system prompt (PromptCompiler já injeta). Endpoint próprio.
const LEAD_VAR_TYPES = ['texto', 'numero', 'booleano', 'lista'];
const leadVars = ref([]);
const leadVarUrl = () =>
  `${deptCollectionUrl()}/${departmentId.value}/ai_lead_variables`;
const fetchLeadVars = async () => {
  if (isNew.value) return;
  try {
    const { data } = await axios.get(leadVarUrl());
    leadVars.value = Array.isArray(data) ? data : [];
  } catch (error) {
    leadVars.value = [];
  }
};
const blankLeadVar = () => ({
  id: null,
  name: '',
  var_type: 'texto',
  description: '',
  visible_in_first_chat: false,
  options: [],
});
const leadVarForm = reactive(blankLeadVar());
const showLeadVarForm = ref(false);
const leadVarTypeLabel = type =>
  t(`AI_DEPARTMENTS.LEAD_VARS.TYPE_${(type || 'texto').toUpperCase()}`);
const leadVarTypeOptions = computed(() =>
  LEAD_VAR_TYPES.map(v => ({ value: v, label: leadVarTypeLabel(v) }))
);
const openNewLeadVar = () => {
  Object.assign(leadVarForm, blankLeadVar());
  showLeadVarForm.value = true;
};
const openEditLeadVar = v => {
  Object.assign(leadVarForm, blankLeadVar(), {
    id: v.id,
    name: v.name || '',
    var_type: v.var_type || 'texto',
    description: v.description || '',
    visible_in_first_chat: !!v.visible_in_first_chat,
    options: Array.isArray(v.values) ? [...v.values] : [],
  });
  showLeadVarForm.value = true;
};
const saveLeadVar = async () => {
  if (!leadVarForm.name.trim()) return;
  const payload = {
    ai_lead_variable: {
      name: leadVarForm.name.trim(),
      var_type: leadVarForm.var_type,
      description: (leadVarForm.description || '').trim(),
      visible_in_first_chat: leadVarForm.visible_in_first_chat,
      values: leadVarForm.var_type === 'lista' ? leadVarForm.options : [],
    },
  };
  try {
    if (leadVarForm.id) {
      await axios.patch(`${leadVarUrl()}/${leadVarForm.id}`, payload);
    } else {
      await axios.post(leadVarUrl(), payload);
    }
    useAlert(t('AI_DEPARTMENTS.SAVED'));
    showLeadVarForm.value = false;
    fetchLeadVars();
  } catch (error) {
    useAlert(t('AI_DEPARTMENTS.ERROR'));
  }
};
const removeLeadVar = async v => {
  try {
    await axios.delete(`${leadVarUrl()}/${v.id}`);
    fetchLeadVars();
  } catch (error) {
    useAlert(t('AI_DEPARTMENTS.ERROR'));
  }
};

const linesToArray = value =>
  (value || '')
    .split('\n')
    .map(l => l.trim())
    .filter(Boolean);
const arrayToLines = value => (Array.isArray(value) ? value.join('\n') : '');

// Etapas viram cards arrastáveis: cada etapa é um objeto {name, objective, automation_on_complete}.
// _uid é uma chave transitória só para o draggable/keys (removida no buildPayload).
let stepUid = 0;
const nextStepUid = () => {
  stepUid += 1;
  return stepUid;
};
const blankStep = () => ({
  uid: nextStepUid(),
  name: '',
  instructions: '',
  automation_on_complete: false,
});
// Aceita o formato legado (array de strings) e o novo (array de objetos).
const parseSteps = arr =>
  (Array.isArray(arr) ? arr : []).map(s =>
    typeof s === 'string'
      ? {
          uid: nextStepUid(),
          name: s,
          instructions: '',
          automation_on_complete: false,
        }
      : {
          uid: nextStepUid(),
          name: s.name || '',
          instructions: s.instructions || s.objective || '',
          automation_on_complete: !!s.automation_on_complete,
        }
  );

// --- Follow-up: tentativas como lista (valor + unidade) ---
let fuUid = 0;
const nextFuUid = () => {
  fuUid += 1;
  return fuUid;
};
// delay em minutos <-> {value, unit} para uma UI amigável (10 min, 2 horas...).
const minutesToVU = dm => {
  const m = Number(dm) || 0;
  return m > 0 && m % 60 === 0
    ? { value: m / 60, unit: 'horas' }
    : { value: m, unit: 'minutos' };
};
const vuToMinutes = a =>
  (a.unit === 'horas' ? Number(a.value) * 60 : Number(a.value)) || 0;
const blankAttempt = () => ({
  uid: nextFuUid(),
  value: '',
  unit: 'minutos',
  message: '',
});
const blankWindow = () => ({ uid: nextFuUid(), start: '', end: '' });

// Hidrata as tentativas: novo formato (`attempts`) ou shim do antigo
// (delay_minutes + max_followups + message).
const hydrateAttempts = fu => {
  if (Array.isArray(fu.attempts)) {
    return fu.attempts.map(a => ({
      uid: nextFuUid(),
      ...minutesToVU(a.delay_minutes),
      message: a.message || '',
    }));
  }
  if (Number(fu.delay_minutes) > 0) {
    const count = Number(fu.max_followups) > 0 ? Number(fu.max_followups) : 1;
    return Array.from({ length: count }, () => ({
      uid: nextFuUid(),
      ...minutesToVU(fu.delay_minutes),
      message: fu.message || '',
    }));
  }
  return [];
};
// Modo de horário + janelas (shim: window_start/end antigos viram uma janela custom).
const hydrateSchedule = fu => {
  if (fu.schedule) {
    return {
      schedule: fu.schedule,
      windows: (Array.isArray(fu.custom_windows) ? fu.custom_windows : []).map(
        w => ({ uid: nextFuUid(), start: w.start || '', end: w.end || '' })
      ),
    };
  }
  if (fu.window_start || fu.window_end) {
    return {
      schedule: 'custom',
      windows: [
        {
          uid: nextFuUid(),
          start: fu.window_start || '',
          end: fu.window_end || '',
        },
      ],
    };
  }
  return { schedule: 'inbox_hours', windows: [] };
};

const hydrate = dept => {
  const playbook = dept.playbook || {};
  const behavior = dept.behavior || {};
  const followUp = dept.follow_up || {};
  const sched = hydrateSchedule(followUp);
  Object.assign(form, {
    name: dept.name || '',
    objetivo: dept.objetivo || '',
    instructions: dept.instructions || behavior.instructions || '',
    status: dept.status || 'active',
    steps: parseSteps(playbook.steps),
    transfer_when_steps: arrayToLines(playbook.transfer_when),
    close_when_steps: arrayToLines(playbook.close_when),
    group_delay_seconds: behavior.grouping?.delay_seconds ?? '',
    max_replies: behavior.max_replies ?? '',
    max_input_chars: behavior.max_input_chars ?? '',
    followup_instructions: followUp.instructions || '',
    followup_attempts: hydrateAttempts(followUp),
    followup_schedule: sched.schedule,
    followup_custom_windows: sched.windows,
    followup_grace: followUp.handoff_grace_minutes ?? 30,
    followup_when_online: followUp.when_agents_online || false,
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

const buildFollowUp = () => {
  const attempts = form.followup_attempts
    .filter(a => vuToMinutes(a) > 0)
    .map(a => ({
      delay_minutes: vuToMinutes(a),
      message: (a.message || '').trim(),
    }));
  return {
    enabled: attempts.length > 0,
    instructions: (form.followup_instructions || '').trim(),
    attempts,
    schedule: form.followup_schedule,
    custom_windows:
      form.followup_schedule === 'custom'
        ? form.followup_custom_windows
            .filter(w => w.start && w.end)
            .map(w => ({ start: w.start, end: w.end }))
        : [],
    handoff_grace_minutes: Number(form.followup_grace) || 30,
    when_agents_online: form.followup_when_online,
  };
};

const buildPayload = () => ({
  ai_department: {
    name: form.name,
    objetivo: form.objetivo,
    instructions: form.instructions,
    status: form.status,
    is_default: true,
    position: form.position,
    behavior: {
      auto_attendance: true,
      grouping: { delay_seconds: Number(form.group_delay_seconds) || 0 },
      max_replies: Number(form.max_replies) || 0,
      max_input_chars: Number(form.max_input_chars) || 0,
      reply_scope: 'all',
      disabled_custom_attributes: form.disabled_custom_attributes,
    },
    follow_up: buildFollowUp(),
    playbook: {
      objetivo: form.objetivo,
      steps: form.steps
        .filter(s => (s.name || '').trim())
        .map(s => ({
          name: s.name.trim(),
          instructions: (s.instructions || '').trim(),
          automation_on_complete: !!s.automation_on_complete,
        })),
      transfer_when: linesToArray(form.transfer_when_steps),
      close_when: linesToArray(form.close_when_steps),
    },
  },
});

const save = async () => {
  // Obrigatório: pelo menos uma etapa (com nome) quando a aba Etapas está em foco.
  if (
    visibleSections.value.has('steps') &&
    !form.steps.some(s => (s.name || '').trim())
  ) {
    useAlert(t('AI_DEPARTMENTS.FORM.STEP_REQUIRED'));
    return;
  }
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

// --- Histórico de versões da configuração do agente (Comportamento + follow-up + etapas) ---
const versions = ref([]);
const showVersions = ref(false);
const versionsUrl = () =>
  `${deptCollectionUrl()}/${departmentId.value}/ai_department_versions`;
const fetchVersions = async () => {
  if (isNew.value) return;
  try {
    const { data } = await axios.get(versionsUrl());
    versions.value = Array.isArray(data) ? data : [];
  } catch (error) {
    // Endpoint ai_department_versions ainda não existe (fase backend): mantém a lista vazia.
    versions.value = [];
  }
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

// --- Etapas (cards arrastáveis) ---
const MAX_STEPS = 10;
const remainingSteps = computed(() =>
  Math.max(0, MAX_STEPS - form.steps.length)
);
const showStepForm = ref(false);
const editingStepIndex = ref(null);
const stepDraft = reactive(blankStep());

const openNewStep = () => {
  if (form.steps.length >= MAX_STEPS) return;
  Object.assign(stepDraft, blankStep());
  editingStepIndex.value = null;
  showStepForm.value = true;
};
const openEditStep = index => {
  Object.assign(stepDraft, form.steps[index]);
  editingStepIndex.value = index;
  showStepForm.value = true;
};
const saveStep = () => {
  if (!stepDraft.name.trim()) return;
  const payload = {
    uid: stepDraft.uid,
    name: stepDraft.name.trim(),
    instructions: (stepDraft.instructions || '').trim(),
    automation_on_complete: !!stepDraft.automation_on_complete,
  };
  if (editingStepIndex.value === null) form.steps.push(payload);
  else form.steps.splice(editingStepIndex.value, 1, payload);
  showStepForm.value = false;
};
const cancelStep = () => {
  showStepForm.value = false;
};
const removeStep = index => {
  form.steps.splice(index, 1);
};

// --- Follow-up: tentativas e janelas ---
const FU_MAX_ATTEMPTS = 10;
// O número de tentativas dirige quantas caixas de horário aparecem (0–10):
// aumentar adiciona caixas no fim; diminuir remove as últimas.
const attemptCount = computed({
  get: () => form.followup_attempts.length,
  set: value => {
    const target = Math.max(0, Math.min(FU_MAX_ATTEMPTS, Number(value) || 0));
    while (form.followup_attempts.length < target)
      form.followup_attempts.push(blankAttempt());
    while (form.followup_attempts.length > target) form.followup_attempts.pop();
  },
});
const removeAttempt = index => form.followup_attempts.splice(index, 1);
const fuUnitOptions = computed(() => [
  { value: 'minutos', label: t('AI_DEPARTMENTS.FOLLOWUP.UNIT_MINUTES') },
  { value: 'horas', label: t('AI_DEPARTMENTS.FOLLOWUP.UNIT_HOURS') },
]);
const fuScheduleOptions = computed(() => [
  { value: 'inbox_hours', label: t('AI_DEPARTMENTS.FOLLOWUP.SCHEDULE_INBOX') },
  {
    value: 'outside_inbox_hours',
    label: t('AI_DEPARTMENTS.FOLLOWUP.SCHEDULE_OUTSIDE'),
  },
  { value: 'custom', label: t('AI_DEPARTMENTS.FOLLOWUP.SCHEDULE_CUSTOM') },
]);
const addWindow = () => form.followup_custom_windows.push(blankWindow());
const removeWindow = index => form.followup_custom_windows.splice(index, 1);

onMounted(async () => {
  await fetchDepartment();
  captureDept();
  await Promise.all([
    fetchVersions(),
    fetchCustomAttributes(),
    fetchLeadVars(),
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
            v-for="tab in ['attendance', 'followup']"
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
            <!-- O nome do agente vem da tela anterior; não repetimos a entrada aqui.
                 form.name segue hidratado do departamento e é preservado no save. -->
            <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.OBJETIVO_LABEL') }}
              <input
                v-model="form.objetivo"
                type="text"
                :placeholder="$t('AI_DEPARTMENTS.OBJETIVO_PLACEHOLDER')"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
              />
              <span class="text-xs font-normal text-n-slate-11">
                {{ $t('AI_DEPARTMENTS.OBJETIVO_HINT') }}
              </span>
            </label>
            <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.INSTRUCTIONS_LABEL') }}
              <textarea
                v-model="form.instructions"
                rows="6"
                :placeholder="$t('AI_DEPARTMENTS.INSTRUCTIONS_PLACEHOLDER')"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none"
              />
              <span class="text-xs font-normal text-n-slate-11">
                {{ $t('AI_DEPARTMENTS.INSTRUCTIONS_HINT') }}
              </span>
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
            <!-- Lista pode crescer conforme novos atributos da conta; limita a ~7 linhas e rola. -->
            <div
              v-else
              class="border border-n-weak rounded-xl divide-y divide-n-weak max-h-[25rem] overflow-y-auto"
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
                <div class="shrink-0 flex items-center gap-2.5">
                  <span class="text-xs text-n-slate-11">
                    {{
                      attrEnabled(attr.attribute_key)
                        ? $t('AI_DEPARTMENTS.CUSTOM_ATTRS.USING')
                        : $t('AI_DEPARTMENTS.CUSTOM_ATTRS.EXCLUDED')
                    }}
                  </span>
                  <Switch
                    :model-value="attrEnabled(attr.attribute_key)"
                    @change="toggleAttr(attr.attribute_key)"
                  />
                </div>
              </div>
            </div>
          </section>

          <!-- Variáveis do lead: dados que a IA coleta na conversa -->
          <section
            class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-3"
          >
            <div class="flex flex-col gap-0.5">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('AI_DEPARTMENTS.LEAD_VARS.TITLE') }}
              </span>
              <p class="text-xs text-n-slate-11 mb-0">
                {{ $t('AI_DEPARTMENTS.LEAD_VARS.HINT') }}
              </p>
            </div>

            <p
              v-if="!leadVars.length && !showLeadVarForm"
              class="text-sm text-n-slate-11 mb-0"
            >
              {{ $t('AI_DEPARTMENTS.LEAD_VARS.EMPTY') }}
            </p>

            <div
              v-for="v in leadVars"
              :key="v.id"
              class="flex items-center justify-between gap-3 rounded-xl border border-n-weak bg-n-solid-1 px-3 py-2.5"
            >
              <div class="min-w-0">
                <p class="text-sm font-medium text-n-slate-12 mb-0 truncate">
                  {{ v.name }}
                  <span class="text-xs font-normal text-n-slate-11">
                    · {{ leadVarTypeLabel(v.var_type) }}
                  </span>
                </p>
                <p
                  v-if="v.description"
                  class="text-xs text-n-slate-11 mb-0 truncate"
                >
                  {{ v.description }}
                </p>
              </div>
              <div class="shrink-0 flex items-center gap-2 text-n-slate-11">
                <button
                  type="button"
                  class="hover:text-n-slate-12"
                  :aria-label="$t('AI_DEPARTMENTS.LEAD_VARS.EDIT')"
                  @click="openEditLeadVar(v)"
                >
                  <span class="i-lucide-pencil size-4 inline-block" />
                </button>
                <button
                  type="button"
                  class="hover:text-n-ruby-11"
                  :aria-label="$t('AI_DEPARTMENTS.LEAD_VARS.REMOVE')"
                  @click="removeLeadVar(v)"
                >
                  <span class="i-lucide-trash-2 size-4 inline-block" />
                </button>
              </div>
            </div>

            <!-- Form criar/editar variável -->
            <div
              v-if="showLeadVarForm"
              class="rounded-xl border border-n-weak bg-n-solid-1 p-4 flex flex-col gap-3"
            >
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
                  {{ $t('AI_DEPARTMENTS.LEAD_VARS.NAME') }}
                  <input
                    v-model="leadVarForm.name"
                    type="text"
                    :placeholder="
                      $t('AI_DEPARTMENTS.LEAD_VARS.NAME_PLACEHOLDER')
                    "
                    class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-2"
                  />
                </label>
                <div class="flex flex-col gap-1.5 text-sm text-n-slate-12">
                  <span>{{ $t('AI_DEPARTMENTS.LEAD_VARS.TYPE') }}</span>
                  <Select
                    v-model="leadVarForm.var_type"
                    :options="leadVarTypeOptions"
                  />
                </div>
              </div>
              <div
                v-if="leadVarForm.var_type === 'lista'"
                class="flex flex-col gap-1.5 text-sm text-n-slate-12"
              >
                <span>{{ $t('AI_DEPARTMENTS.LEAD_VARS.OPTIONS') }}</span>
                <div
                  class="rounded-lg border border-n-weak bg-n-solid-2 px-3 py-2"
                >
                  <TagInput
                    v-model="leadVarForm.options"
                    :placeholder="
                      $t('AI_DEPARTMENTS.LEAD_VARS.OPTIONS_PLACEHOLDER')
                    "
                    allow-create
                  />
                </div>
              </div>
              <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
                {{ $t('AI_DEPARTMENTS.LEAD_VARS.DESCRIPTION') }}
                <input
                  v-model="leadVarForm.description"
                  type="text"
                  :placeholder="
                    $t('AI_DEPARTMENTS.LEAD_VARS.DESCRIPTION_PLACEHOLDER')
                  "
                  class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-2"
                />
              </label>
              <label class="flex items-center gap-2 text-sm text-n-slate-12">
                <input
                  v-model="leadVarForm.visible_in_first_chat"
                  type="checkbox"
                />
                {{ $t('AI_DEPARTMENTS.LEAD_VARS.FIRST_CHAT') }}
              </label>
              <div class="flex justify-end gap-2">
                <button
                  type="button"
                  class="text-sm px-3 py-2 rounded-lg bg-n-alpha-2 text-n-slate-12"
                  @click="showLeadVarForm = false"
                >
                  {{ $t('AI_DEPARTMENTS.FORM.CANCEL') }}
                </button>
                <button
                  type="button"
                  :disabled="!leadVarForm.name.trim()"
                  class="text-sm font-medium px-3 py-2 rounded-lg bg-n-brand text-white disabled:opacity-50 disabled:cursor-not-allowed"
                  @click="saveLeadVar"
                >
                  {{ $t('AI_DEPARTMENTS.FORM.SAVE') }}
                </button>
              </div>
            </div>

            <button
              v-if="!showLeadVarForm"
              type="button"
              class="self-start text-sm font-medium text-n-brand hover:underline"
              @click="openNewLeadVar"
            >
              + {{ $t('AI_DEPARTMENTS.LEAD_VARS.ADD') }}
            </button>
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
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.MAX_REPLIES_TITLE') }}
            </h2>
            <p class="text-sm text-n-slate-11 mb-0">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.MAX_REPLIES_HINT') }}
            </p>
            <label class="flex flex-col gap-1 text-sm text-n-slate-12 max-w-xs">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.MAX_REPLIES_FIELD') }}
              <input
                v-model="form.max_replies"
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

          <!-- Histórico de versões da configuração (Comportamento + follow-up + etapas) -->
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

        <!-- FOLLOW-UP -->
        <div v-if="visibleSections.has('followup')" class="flex flex-col gap-5">
          <section
            class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-4"
          >
            <div class="flex flex-col gap-0.5">
              <h2 class="text-base font-semibold text-n-slate-12 mb-0">
                {{ $t('AI_DEPARTMENTS.FOLLOWUP.TITLE') }}
              </h2>
              <p class="text-xs text-n-slate-11 mb-0">
                {{ $t('AI_DEPARTMENTS.FOLLOWUP.HINT') }}
              </p>
            </div>

            <label class="flex flex-col gap-1 text-sm text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.FOLLOWUP.INSTRUCTIONS') }}
              <textarea
                v-model="form.followup_instructions"
                rows="3"
                :placeholder="
                  $t('AI_DEPARTMENTS.FOLLOWUP.INSTRUCTIONS_PLACEHOLDER')
                "
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none"
              />
            </label>

            <!-- Tentativas de envio (várias opções de tempo) -->
            <div class="flex flex-col gap-2">
              <div class="flex flex-col gap-0.5">
                <span class="text-sm font-medium text-n-slate-12">
                  {{ $t('AI_DEPARTMENTS.FOLLOWUP.ATTEMPTS_TITLE') }}
                </span>
                <p class="text-xs text-n-slate-11 mb-0">
                  {{ $t('AI_DEPARTMENTS.FOLLOWUP.ATTEMPTS_HINT') }}
                </p>
              </div>

              <label
                class="flex flex-col gap-1 text-sm text-n-slate-12 max-w-xs"
              >
                {{ $t('AI_DEPARTMENTS.FOLLOWUP.COUNT_LABEL') }}
                <input
                  v-model.number="attemptCount"
                  type="number"
                  min="0"
                  :max="FU_MAX_ATTEMPTS"
                  class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
                />
                <span class="text-xs text-n-slate-11">
                  {{ $t('AI_DEPARTMENTS.FOLLOWUP.COUNT_HINT') }}
                </span>
              </label>

              <p
                v-if="!form.followup_attempts.length"
                class="text-sm text-n-slate-11 mb-0"
              >
                {{ $t('AI_DEPARTMENTS.FOLLOWUP.ATTEMPTS_EMPTY') }}
              </p>

              <div
                v-for="(attempt, index) in form.followup_attempts"
                :key="attempt.uid"
                class="rounded-xl border border-n-weak bg-n-solid-1 p-3 flex flex-col gap-2"
              >
                <div class="flex items-center justify-between gap-2">
                  <span class="text-sm font-medium text-n-slate-12">
                    {{
                      $t('AI_DEPARTMENTS.FOLLOWUP.ATTEMPT_LABEL', {
                        n: index + 1,
                      })
                    }}
                  </span>
                  <button
                    type="button"
                    class="shrink-0 text-n-slate-11 hover:text-n-ruby-11"
                    :aria-label="$t('AI_DEPARTMENTS.FOLLOWUP.ATTEMPT_REMOVE')"
                    @click="removeAttempt(index)"
                  >
                    <span class="i-lucide-trash-2 size-4 inline-block" />
                  </button>
                </div>
                <div class="flex flex-wrap items-end gap-3">
                  <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                    {{ $t('AI_DEPARTMENTS.FOLLOWUP.ATTEMPT_INTERVAL') }}
                    <div class="flex items-center gap-2">
                      <input
                        v-model="attempt.value"
                        type="number"
                        min="0"
                        class="w-24 px-3 py-2 rounded-lg border border-n-weak bg-n-solid-2"
                      />
                      <div class="w-36">
                        <Select
                          v-model="attempt.unit"
                          :options="fuUnitOptions"
                        />
                      </div>
                    </div>
                  </label>
                </div>
                <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                  {{ $t('AI_DEPARTMENTS.FOLLOWUP.ATTEMPT_MESSAGE') }}
                  <textarea
                    v-model="attempt.message"
                    rows="2"
                    :placeholder="
                      $t('AI_DEPARTMENTS.FOLLOWUP.ATTEMPT_MESSAGE_PLACEHOLDER')
                    "
                    class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-2 resize-none"
                  />
                </label>
              </div>
            </div>

            <!-- Quando enviar (relativo ao horário da caixa) -->
            <div class="flex flex-col gap-1.5">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('AI_DEPARTMENTS.FOLLOWUP.SCHEDULE_TITLE') }}
              </span>
              <div class="max-w-xs">
                <Select
                  v-model="form.followup_schedule"
                  :options="fuScheduleOptions"
                />
              </div>

              <div
                v-if="form.followup_schedule === 'custom'"
                class="flex flex-col gap-2 mt-1"
              >
                <div
                  v-for="(win, index) in form.followup_custom_windows"
                  :key="win.uid"
                  class="flex items-center gap-2"
                >
                  <input
                    v-model="win.start"
                    type="time"
                    class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm"
                  />
                  <span class="text-sm text-n-slate-11">
                    {{ $t('AI_DEPARTMENTS.FOLLOWUP.WINDOW_TO') }}
                  </span>
                  <input
                    v-model="win.end"
                    type="time"
                    class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm"
                  />
                  <button
                    type="button"
                    class="shrink-0 text-n-slate-11 hover:text-n-ruby-11"
                    :aria-label="$t('AI_DEPARTMENTS.FOLLOWUP.WINDOW_REMOVE')"
                    @click="removeWindow(index)"
                  >
                    <span class="i-lucide-x size-4 inline-block" />
                  </button>
                </div>
                <button
                  type="button"
                  class="self-start text-sm font-medium text-n-brand hover:underline"
                  @click="addWindow"
                >
                  + {{ $t('AI_DEPARTMENTS.FOLLOWUP.WINDOW_ADD') }}
                </button>
                <span class="text-xs text-n-slate-11">
                  {{ $t('AI_DEPARTMENTS.FOLLOWUP.WINDOW_HINT') }}
                </span>
              </div>
            </div>

            <!-- Carência após a última tentativa (fixo/obrigatório) -->
            <label class="flex flex-col gap-1 text-sm text-n-slate-12 max-w-xs">
              {{ $t('AI_DEPARTMENTS.FOLLOWUP.GRACE_LABEL') }}
              <input
                v-model="form.followup_grace"
                type="number"
                min="0"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
              />
              <span class="text-xs text-n-slate-11">
                {{ $t('AI_DEPARTMENTS.FOLLOWUP.GRACE_HINT') }}
              </span>
            </label>

            <label class="flex items-center gap-2 text-sm text-n-slate-12">
              <input v-model="form.followup_when_online" type="checkbox" />
              {{ $t('AI_DEPARTMENTS.FOLLOWUP.WHEN_ONLINE') }}
            </label>
          </section>
        </div>

        <!-- ETAPAS -->
        <div v-if="visibleSections.has('steps')" class="flex flex-col gap-5">
          <section
            class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-4"
          >
            <div class="flex flex-col gap-0.5">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('AI_DEPARTMENTS.STEPS_TITLE') }}
              </span>
              <p class="text-xs text-n-slate-11 mb-0">
                {{ $t('AI_DEPARTMENTS.STEPS_DESC') }}
              </p>
            </div>

            <p
              v-if="!form.steps.length && !showStepForm"
              class="text-sm text-n-slate-11 mb-0"
            >
              {{ $t('AI_DEPARTMENTS.FORM.STEP_EMPTY') }}
            </p>

            <!-- Cards arrastáveis (reordenar pelo handle) -->
            <Draggable
              v-if="form.steps.length"
              v-model="form.steps"
              item-key="uid"
              handle=".step-drag"
              tag="div"
              class="flex flex-col gap-2"
            >
              <template #item="{ element, index }">
                <div
                  class="flex items-center gap-3 rounded-xl border border-n-weak bg-n-solid-1 px-3 py-2.5"
                >
                  <span
                    class="step-drag i-lucide-grip-vertical size-4 shrink-0 text-n-slate-10 cursor-grab"
                    :aria-label="$t('AI_DEPARTMENTS.FORM.STEP_DRAG')"
                  />
                  <span
                    class="shrink-0 w-5 text-xs font-medium text-n-slate-11"
                  >
                    {{ index + 1 }}
                  </span>
                  <div class="min-w-0 flex-1">
                    <p
                      class="text-sm font-medium text-n-slate-12 mb-0 truncate"
                    >
                      {{ element.name }}
                    </p>
                    <p
                      v-if="element.instructions"
                      class="text-xs text-n-slate-11 mb-0 truncate"
                    >
                      {{ element.instructions }}
                    </p>
                  </div>
                  <span
                    v-if="element.automation_on_complete"
                    class="shrink-0 i-lucide-zap size-3.5 text-n-amber-11"
                    :title="$t('AI_DEPARTMENTS.FORM.STEP_AUTOMATION')"
                  />
                  <button
                    type="button"
                    class="shrink-0 text-n-slate-11 hover:text-n-slate-12"
                    :aria-label="$t('AI_DEPARTMENTS.FORM.STEP_EDIT')"
                    @click="openEditStep(index)"
                  >
                    <span class="i-lucide-pencil size-4 inline-block" />
                  </button>
                  <button
                    type="button"
                    class="shrink-0 text-n-slate-11 hover:text-n-ruby-11"
                    :aria-label="$t('AI_DEPARTMENTS.FORM.STEP_REMOVE')"
                    @click="removeStep(index)"
                  >
                    <span class="i-lucide-trash-2 size-4 inline-block" />
                  </button>
                </div>
              </template>
            </Draggable>

            <!-- Form criar/editar etapa -->
            <div
              v-if="showStepForm"
              class="rounded-xl border border-n-weak bg-n-solid-1 p-4 flex flex-col gap-3"
            >
              <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
                {{ $t('AI_DEPARTMENTS.FORM.STEP_NAME') }}
                <input
                  v-model="stepDraft.name"
                  type="text"
                  :placeholder="$t('AI_DEPARTMENTS.FORM.STEP_NAME_PLACEHOLDER')"
                  class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-2"
                />
              </label>
              <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
                {{ $t('AI_DEPARTMENTS.FORM.STEP_INSTRUCTIONS') }}
                <textarea
                  v-model="stepDraft.instructions"
                  rows="3"
                  :placeholder="
                    $t('AI_DEPARTMENTS.FORM.STEP_INSTRUCTIONS_PLACEHOLDER')
                  "
                  class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-2 resize-none"
                />
              </label>
              <div class="flex items-center justify-between gap-3 flex-wrap">
                <label class="flex items-center gap-2 text-sm text-n-slate-12">
                  <input
                    v-model="stepDraft.automation_on_complete"
                    type="checkbox"
                  />
                  {{ $t('AI_DEPARTMENTS.FORM.STEP_AUTOMATION') }}
                </label>
                <div class="flex items-center gap-2">
                  <button
                    type="button"
                    class="text-sm px-3 py-2 rounded-lg bg-n-alpha-2 text-n-slate-12"
                    @click="cancelStep"
                  >
                    {{ $t('AI_DEPARTMENTS.FORM.CANCEL') }}
                  </button>
                  <button
                    type="button"
                    :disabled="!stepDraft.name.trim()"
                    class="text-sm font-medium px-3 py-2 rounded-lg bg-n-brand text-white disabled:opacity-50 disabled:cursor-not-allowed"
                    @click="saveStep"
                  >
                    {{
                      editingStepIndex === null
                        ? $t('AI_DEPARTMENTS.FORM.STEP_CREATE')
                        : $t('AI_DEPARTMENTS.FORM.SAVE')
                    }}
                  </button>
                </div>
              </div>
            </div>

            <!-- Adicionar etapa + contador (máx. 10) -->
            <div
              v-if="!showStepForm"
              class="flex items-center justify-between gap-3"
            >
              <span class="text-xs text-n-slate-11">
                {{
                  $t('AI_DEPARTMENTS.FORM.STEP_REMAINING', {
                    count: remainingSteps,
                  })
                }}
              </span>
              <button
                type="button"
                :disabled="form.steps.length >= MAX_STEPS"
                class="shrink-0 text-sm font-medium px-4 py-1.5 rounded-full bg-n-brand text-white disabled:opacity-50 disabled:cursor-not-allowed"
                @click="openNewStep"
              >
                + {{ $t('AI_DEPARTMENTS.FORM.STEP_ADD') }}
              </button>
            </div>
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
        </div>

        <!-- FERRAMENTAS -->
        <AiTools
          v-if="visibleSections.has('tools') && !isNew"
          :agent-id="route.params.agentId"
          :department-id="departmentId"
        />

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
