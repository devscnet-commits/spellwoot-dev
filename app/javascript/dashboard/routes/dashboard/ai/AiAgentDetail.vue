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
import Button from 'dashboard/components-next/button/Button.vue';
import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';
import Logo from 'next/icon/Logo.vue';
import { useFormDirty } from 'dashboard/composables/useFormDirty';

const route = useRoute();
const router = useRouter();
const { t } = useI18n();

const isNew = computed(() => route.params.agentId === 'new');
const agentId = ref(isNew.value ? null : route.params.agentId);

// The agent holds identity, the inboxes it serves, and its departments. Knowledge / tools /
// steps / follow-up live INSIDE each department (Comercial uses different tools than Financeiro).
const TAB_KEYS = ['about', 'inboxes', 'departments', 'test'];
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
const departments = ref([]);
const isSaving = ref(false);

const STAGE_BADGE = {
  production: { dot: 'bg-n-teal-9', text: 'text-n-teal-11', bg: 'bg-n-teal-3' },
  staging: { dot: 'bg-n-amber-9', text: 'text-n-amber-11', bg: 'bg-n-amber-3' },
  sandbox: { dot: 'bg-n-blue-9', text: 'text-n-blue-11', bg: 'bg-n-blue-3' },
  experimental: {
    dot: 'bg-n-slate-9',
    text: 'text-n-slate-11',
    bg: 'bg-n-alpha-2',
  },
};

const accountUrl = () => `/api/v1/accounts/${route.params.accountId}`;
const agentUrl = () => `${accountUrl()}/ai_agents`;

const agentForm = reactive({
  name: '',
  assistant_name: '',
  category: '',
  company_name: '',
  site: '',
  version: '',
  identify_as: 'human',
  assistant_avatar: '',
  ai_operation_profile_id: '',
  assistant_description: '',
  assistant_personality: '',
  assistant_voice: '',
  assistant_language: '',
  base_prompt: '',
  guardrails: '',
  stage: 'sandbox',
  status: 'active',
});
const {
  isDirty: agentDirty,
  capture: captureAgent,
  reset: resetAgent,
} = useFormDirty(() => ({ ...agentForm }));

const stageBadge = computed(
  () => STAGE_BADGE[agentForm.stage] || STAGE_BADGE.experimental
);

const profileOptions = computed(() => [
  { value: '', label: t('AI_AGENTS.FORM.NONE') },
  ...profiles.value.map(p => ({ value: p.id, label: p.name })),
]);

// Controlled organizational categories (decoupled from departments / behaviour).
const CATEGORY_KEYS = ['cliente', 'parceiro', 'interno', 'outro'];
const categoryOptions = computed(() => [
  { value: '', label: t('AI_AGENTS.FORM.NONE') },
  ...CATEGORY_KEYS.map(k => ({
    value: k,
    label: t(`AI_AGENTS.CATEGORIES.${k}`),
  })),
]);
const stageOptions = computed(() =>
  ['production', 'staging', 'sandbox', 'experimental'].map(s => ({
    value: s,
    label: t(`AI_AGENTS.STAGES.${s.toUpperCase()}`),
  }))
);

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

const fetchDepartments = async () => {
  if (isNew.value) return;
  const { data } = await axios.get(
    `${agentUrl()}/${agentId.value}/ai_departments`
  );
  departments.value = Array.isArray(data) ? data : [];
};

const deptSearch = ref('');
const deptSort = ref('name');
const deptSortOptions = computed(() => [
  { value: 'name', label: t('AI_DEPARTMENTS.SORT_NAME') },
  { value: 'recent', label: t('AI_DEPARTMENTS.SORT_RECENT') },
]);
const filteredDepartments = computed(() => {
  const q = deptSearch.value.trim().toLowerCase();
  const list = q
    ? departments.value.filter(d =>
        `${d.name || ''} ${d.objetivo || ''}`.toLowerCase().includes(q)
      )
    : [...departments.value];
  if (deptSort.value === 'recent') {
    return list.sort(
      (a, b) => new Date(b.created_at || 0) - new Date(a.created_at || 0)
    );
  }
  return list.sort((a, b) => (a.name || '').localeCompare(b.name || ''));
});

const onAvatarUpload = ({ file }) => {
  const reader = new FileReader();
  reader.onload = e => {
    agentForm.assistant_avatar = e.target.result;
  };
  reader.readAsDataURL(file);
};
const fileInput = ref(null);
const triggerUpload = () => {
  if (fileInput.value) fileInput.value.click();
};
const onFilePick = e => {
  const file = e.target.files && e.target.files[0];
  if (file) onAvatarUpload({ file });
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
      fetchDepartments();
      // eslint-disable-next-line no-use-before-define
      fetchInboxes();
    } else {
      await axios.patch(`${agentUrl()}/${agentId.value}`, {
        ai_agent: payload,
      });
    }
    useAlert(t('AI_AGENTS.SAVED'));
    resetAgent();
  } catch (error) {
    useAlert(t('AI_AGENTS.ERROR'));
  } finally {
    isSaving.value = false;
  }
};

// --- Histórico de versões ---
const versions = ref([]);
const showVersions = ref(false);
const showAdvanced = ref(false);
const versionsUrl = () => `${agentUrl()}/${agentId.value}/ai_agent_versions`;
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
    await fetchAgent();
    await fetchVersions();
  } catch (error) {
    useAlert(t('AI_AGENTS.ERROR'));
  }
};
const formatVersionDate = iso => {
  if (!iso) return '';
  return new Date(iso).toLocaleString();
};

const goBack = () => router.push({ name: 'ai_agents_index' });
const newDepartment = () =>
  router.push({
    name: 'ai_department_detail',
    params: { agentId: agentId.value, departmentId: 'new' },
  });
const editDepartment = dept =>
  router.push({
    name: 'ai_department_detail',
    params: { agentId: agentId.value, departmentId: dept.id },
  });

// --- Caixas (live/shadow binding) ---
const inboxes = ref([]);
const INBOX_MODES = [
  {
    value: 'none',
    i18n: 'NONE_SHORT',
    active: 'bg-n-solid-1 text-n-slate-12 shadow-sm',
  },
  {
    value: 'shadow',
    i18n: 'SHADOW_SHORT',
    active: 'bg-n-amber-3 text-n-amber-11 shadow-sm',
    icon: 'i-lucide-eye',
  },
  {
    value: 'live',
    i18n: 'LIVE_SHORT',
    active: 'bg-n-teal-3 text-n-teal-11 shadow-sm',
  },
];
const inboxesUrl = () => `${agentUrl()}/${agentId.value}/ai_agent_inboxes`;
const {
  isDirty: inboxesDirty,
  capture: captureInboxes,
  reset: resetInboxes,
} = useFormDirty(() =>
  inboxes.value.map(i => ({ inbox_id: i.inbox_id, mode: i.mode }))
);
const fetchInboxes = async () => {
  if (isNew.value) return;
  const { data } = await axios.get(inboxesUrl());
  inboxes.value = Array.isArray(data) ? data : [];
  captureInboxes();
};
const inboxSearch = ref('');
const filteredInboxes = computed(() => {
  const q = inboxSearch.value.trim().toLowerCase();
  if (!q) return inboxes.value;
  return inboxes.value.filter(i => (i.name || '').toLowerCase().includes(q));
});
const saveInboxes = async () => {
  try {
    await axios.put(inboxesUrl(), {
      bindings: inboxes.value.map(i => ({
        inbox_id: i.inbox_id,
        mode: i.mode,
      })),
    });
    useAlert(t('AI_AGENTS.SAVED'));
    resetInboxes();
  } catch (error) {
    useAlert(t('AI_AGENTS.ERROR'));
  }
};

// --- Teste ---
const testMessage = ref('');
const testResult = ref(null);
const isTesting = ref(false);

// Governance read-out for the Lab: how the engine decided (all from the Tester response).
const testMethodLabel = m => (m ? t(`AI_AGENTS.TEST.METHODS.${m}`, m) : '');
const testResolvedBy = computed(() => {
  const r = testResult.value;
  if (!r || r.error) return null;
  if (r.decision === 'handoff') return 'transfer';
  if (r.tool) return 'tool';
  if (r.reply && (r.knowledge_used ?? 0) > 0) return 'knowledge';
  if (r.reply) return 'instruction';
  return 'unanswered';
});
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

onMounted(async () => {
  await fetchProfiles();
  await fetchAgent();
  captureAgent();
  await Promise.all([fetchDepartments(), fetchInboxes(), fetchVersions()]);
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
        {{ $t('AI_AGENTS.BACK') }}
      </button>

      <!-- Main card -->
      <div
        class="rounded-2xl border border-n-weak bg-n-solid-1 px-4 sm:px-8 py-6 flex flex-col gap-5"
      >
        <!-- Header: name (left) + brand logo (right) -->
        <div class="flex items-start justify-between gap-4">
          <div class="flex items-center gap-3 min-w-0">
            <h1 class="text-2xl font-semibold text-n-slate-12 truncate">
              {{
                agentForm.assistant_name ||
                agentForm.name ||
                $t('AI_AGENTS.NEW')
              }}
            </h1>
            <span
              class="shrink-0 inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium"
              :class="[stageBadge.bg, stageBadge.text]"
            >
              <span class="size-1.5 rounded-full" :class="stageBadge.dot" />
              {{ $t(`AI_AGENTS.STAGES.${agentForm.stage.toUpperCase()}`) }}
            </span>
          </div>
          <Logo class="h-7 w-auto shrink-0" />
        </div>

        <TabBar
          :tabs="tabs"
          :initial-active-tab="activeIndex"
          @tab-changed="onTabChanged"
        />

        <!-- SOBRE -->
        <div v-if="activeKey === 'about'" class="flex flex-col gap-5">
          <!-- Row 1: avatar + image actions | identify cards -->
          <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
            <div class="flex items-start gap-3">
              <Avatar
                :src="agentForm.assistant_avatar"
                :name="agentForm.assistant_name || agentForm.name || 'IA'"
                :size="80"
              />
              <div class="flex flex-col gap-2">
                <input
                  ref="fileInput"
                  type="file"
                  accept="image/*"
                  class="hidden"
                  @change="onFilePick"
                />
                <Button
                  variant="outline"
                  color="slate"
                  size="sm"
                  icon="i-lucide-upload"
                  :label="$t('AI_AGENTS.SOBRE.UPLOAD')"
                  @click="triggerUpload"
                />
                <Button
                  variant="outline"
                  color="slate"
                  size="sm"
                  icon="i-lucide-sparkles"
                  :label="$t('AI_AGENTS.SOBRE.GENERATE')"
                  @click="generateAvatar"
                />
              </div>
            </div>

            <div class="lg:col-span-2 flex flex-col gap-2">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('AI_AGENTS.IDENTIFY_AS.LABEL') }}
              </span>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                <button
                  type="button"
                  class="relative flex items-start gap-3 text-left p-5 rounded-2xl border-2 transition-all"
                  :class="
                    agentForm.identify_as === 'human'
                      ? 'border-n-brand bg-n-brand/10 shadow-sm'
                      : 'border-n-weak bg-n-solid-2 hover:border-n-slate-7'
                  "
                  @click="agentForm.identify_as = 'human'"
                >
                  <span
                    class="shrink-0 size-10 rounded-full flex items-center justify-center"
                    :class="
                      agentForm.identify_as === 'human'
                        ? 'bg-n-brand text-white'
                        : 'bg-n-alpha-2 text-n-slate-11'
                    "
                  >
                    <span class="i-lucide-user-round size-5" />
                  </span>
                  <span class="flex flex-col gap-0.5 min-w-0">
                    <span class="text-base font-semibold text-n-slate-12">
                      {{ $t('AI_AGENTS.IDENTIFY_AS.HUMAN') }}
                    </span>
                    <span class="text-xs text-n-slate-11">
                      {{ $t('AI_AGENTS.IDENTIFY_AS.HUMAN_HINT') }}
                    </span>
                  </span>
                  <span
                    v-if="agentForm.identify_as === 'human'"
                    class="i-lucide-check-circle-2 size-5 text-n-brand absolute top-3 right-3"
                  />
                </button>
                <button
                  type="button"
                  class="relative flex items-start gap-3 text-left p-5 rounded-2xl border-2 transition-all"
                  :class="
                    agentForm.identify_as === 'ai'
                      ? 'border-n-brand bg-n-brand/10 shadow-sm'
                      : 'border-n-weak bg-n-solid-2 hover:border-n-slate-7'
                  "
                  @click="agentForm.identify_as = 'ai'"
                >
                  <span
                    class="shrink-0 size-10 rounded-full flex items-center justify-center"
                    :class="
                      agentForm.identify_as === 'ai'
                        ? 'bg-n-brand text-white'
                        : 'bg-n-alpha-2 text-n-slate-11'
                    "
                  >
                    <span class="i-lucide-bot size-5" />
                  </span>
                  <span class="flex flex-col gap-0.5 min-w-0">
                    <span class="text-base font-semibold text-n-slate-12">
                      {{ $t('AI_AGENTS.IDENTIFY_AS.AI') }}
                    </span>
                    <span class="text-xs text-n-slate-11">
                      {{ $t('AI_AGENTS.IDENTIFY_AS.AI_HINT') }}
                    </span>
                  </span>
                  <span
                    v-if="agentForm.identify_as === 'ai'"
                    class="i-lucide-check-circle-2 size-5 text-n-brand absolute top-3 right-3"
                  />
                </button>
              </div>
            </div>
          </div>

          <!-- Row 2: nome | empresa | site -->
          <div class="grid grid-cols-1 sm:grid-cols-3 gap-x-6 gap-y-5">
            <Input
              v-model="agentForm.assistant_name"
              :label="$t('AI_AGENTS.SOBRE.AGENT_NAME')"
            />
            <Input
              v-model="agentForm.company_name"
              :label="$t('AI_AGENTS.SOBRE.COMPANY')"
            />
            <Input
              v-model="agentForm.site"
              :label="$t('AI_AGENTS.SOBRE.SITE')"
            />

            <Input
              v-model="agentForm.version"
              :label="$t('AI_AGENTS.SOBRE.VERSION')"
            />
            <div class="flex flex-col gap-1.5">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('AI_AGENTS.SOBRE.MODEL') }}
              </span>
              <Select
                v-model="agentForm.ai_operation_profile_id"
                :options="profileOptions"
              />
            </div>
            <div class="flex flex-col gap-1.5">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('AI_AGENTS.FORM.STAGE') }}
              </span>
              <Select v-model="agentForm.stage" :options="stageOptions" />
            </div>

            <div class="flex flex-col gap-1.5">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('AI_AGENTS.SOBRE.CATEGORY') }}
              </span>
              <Select v-model="agentForm.category" :options="categoryOptions" />
              <span class="text-xs text-n-slate-11">
                {{ $t('AI_AGENTS.SOBRE.CATEGORY_HINT') }}
              </span>
            </div>
            <Input
              v-model="agentForm.assistant_voice"
              :label="$t('AI_AGENTS.SOBRE.VOICE')"
            />
            <Input
              v-model="agentForm.assistant_language"
              :label="$t('AI_AGENTS.SOBRE.LANGUAGE')"
            />
          </div>

          <TextArea
            v-model="agentForm.assistant_description"
            :label="$t('AI_AGENTS.SOBRE.DESCRIPTION_FIELD')"
            :max-length="500"
          />
          <TextArea
            v-model="agentForm.assistant_personality"
            :label="$t('AI_AGENTS.SOBRE.PERSONALITY')"
            :max-length="1000"
          />
          <div class="border border-n-weak rounded-xl">
            <button
              type="button"
              class="w-full flex items-center gap-2 px-4 py-3 text-sm font-medium text-n-slate-12"
              @click="showAdvanced = !showAdvanced"
            >
              <span
                class="size-4 inline-block text-n-slate-11"
                :class="
                  showAdvanced
                    ? 'i-lucide-chevron-down'
                    : 'i-lucide-chevron-right'
                "
              />
              {{ $t('AI_AGENTS.SOBRE.ADVANCED') }}
              <span class="text-xs text-n-slate-11 font-normal">
                {{ $t('AI_AGENTS.SOBRE.ADVANCED_HINT') }}
              </span>
            </button>
            <div
              v-if="showAdvanced"
              class="border-t border-n-weak p-4 flex flex-col gap-5"
            >
              <TextArea
                v-model="agentForm.base_prompt"
                :label="$t('AI_AGENTS.FORM.BASE_PROMPT')"
                :max-length="4000"
              />
              <TextArea
                v-model="agentForm.guardrails"
                :label="$t('AI_AGENTS.FORM.GUARDRAILS')"
                :max-length="2000"
              />
            </div>
          </div>

          <div class="flex justify-end">
            <Button
              :label="$t('AI_AGENTS.FORM.SAVE')"
              :is-loading="isSaving"
              :disabled="!agentDirty"
              @click="saveAgent"
            />
          </div>

          <!-- Histórico de versões -->
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
                <Button
                  variant="ghost"
                  color="slate"
                  size="sm"
                  :label="$t('AI_AGENTS.VERSIONS.RESTORE')"
                  @click="restoreVersion(v)"
                />
              </div>
            </div>
          </div>
        </div>

        <!-- CAIXAS -->
        <div v-else-if="activeKey === 'inboxes'" class="flex flex-col gap-4">
          <div class="flex flex-col gap-1">
            <span class="text-sm font-medium text-n-slate-12">
              {{ $t('AI_AGENTS.INBOXES.TITLE') }}
            </span>
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
            <input
              v-model="inboxSearch"
              type="search"
              :placeholder="$t('AI_AGENTS.INBOXES.SEARCH')"
              class="w-full sm:w-64 px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12"
            />
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <div
                v-for="inbox in filteredInboxes"
                :key="inbox.inbox_id"
                class="rounded-xl border border-n-weak bg-n-solid-2 p-4 flex flex-col gap-3"
              >
                <div class="flex items-center gap-2 min-w-0">
                  <span
                    class="shrink-0 size-8 rounded-lg bg-n-alpha-2 flex items-center justify-center"
                  >
                    <span class="i-lucide-inbox size-4 text-n-slate-11" />
                  </span>
                  <span class="text-sm font-medium text-n-slate-12 truncate">
                    {{ inbox.name }}
                  </span>
                </div>
                <div class="grid grid-cols-3 gap-1 rounded-lg bg-n-alpha-1 p-1">
                  <button
                    v-for="m in INBOX_MODES"
                    :key="m.value"
                    type="button"
                    class="px-2 py-1.5 rounded-md text-xs font-medium transition-colors inline-flex items-center justify-center gap-1"
                    :class="
                      inbox.mode === m.value
                        ? m.active
                        : 'text-n-slate-11 hover:text-n-slate-12'
                    "
                    @click="inbox.mode = m.value"
                  >
                    <span
                      v-if="m.icon && inbox.mode === m.value"
                      class="size-3 inline-block"
                      :class="m.icon"
                    />
                    {{ $t(`AI_AGENTS.INBOXES.${m.i18n}`) }}
                  </button>
                </div>
              </div>
            </div>
            <div class="flex justify-end">
              <Button
                :label="$t('AI_AGENTS.INBOXES.SAVE')"
                :disabled="!inboxesDirty"
                @click="saveInboxes"
              />
            </div>
          </template>
        </div>

        <!-- DEPARTAMENTOS -->
        <div
          v-else-if="activeKey === 'departments'"
          class="flex flex-col gap-4"
        >
          <div class="flex items-start justify-between gap-4">
            <div class="flex items-start gap-3 min-w-0">
              <span
                class="shrink-0 size-10 rounded-xl bg-n-brand/10 text-n-brand flex items-center justify-center"
              >
                <span class="i-lucide-layers size-5" />
              </span>
              <div class="flex flex-col gap-0.5 min-w-0">
                <h2 class="text-base font-semibold text-n-slate-12 mb-0">
                  {{ $t('AI_DEPARTMENTS.CORE_TITLE') }}
                </h2>
                <p class="text-sm text-n-slate-11 mb-0">
                  {{ $t('AI_DEPARTMENTS.CORE_HINT') }}
                </p>
              </div>
            </div>
            <Button
              v-if="!isNew"
              icon="i-lucide-plus"
              :label="$t('AI_DEPARTMENTS.NEW')"
              @click="newDepartment"
            />
          </div>
          <p v-if="isNew" class="text-sm text-n-slate-11">
            {{ $t('AI_AGENTS.SAVE_FIRST') }}
          </p>
          <p
            v-else-if="!departments.length"
            class="text-sm text-n-slate-11 py-8 text-center"
          >
            {{ $t('AI_DEPARTMENTS.EMPTY') }}
          </p>
          <template v-else>
            <div
              v-if="departments.length > 2"
              class="flex flex-wrap items-center gap-2"
            >
              <input
                v-model="deptSearch"
                type="search"
                :placeholder="$t('AI_DEPARTMENTS.SEARCH')"
                class="flex-1 min-w-48 px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12"
              />
              <Select v-model="deptSort" :options="deptSortOptions" />
            </div>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <button
                v-for="dept in filteredDepartments"
                :key="dept.id"
                type="button"
                class="group rounded-2xl border border-n-weak bg-n-solid-1 p-5 flex flex-col gap-3 text-left hover:border-n-brand hover:shadow-sm transition-all"
                @click="editDepartment(dept)"
              >
                <div class="flex items-start justify-between gap-2">
                  <span
                    class="size-10 rounded-xl bg-n-brand/10 text-n-brand flex items-center justify-center shrink-0"
                  >
                    <span class="i-lucide-layers size-5" />
                  </span>
                  <div class="flex items-center gap-1.5 shrink-0">
                    <span
                      v-if="dept.is_default"
                      class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium bg-n-brand/10 text-n-brand"
                    >
                      <span class="i-lucide-star size-3" />
                      {{ $t('AI_DEPARTMENTS.DEFAULT_BADGE') }}
                    </span>
                    <span
                      class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium"
                      :class="
                        dept.status === 'active'
                          ? 'bg-n-teal-3 text-n-teal-11'
                          : 'bg-n-alpha-2 text-n-slate-11'
                      "
                    >
                      <span
                        class="size-1.5 rounded-full"
                        :class="
                          dept.status === 'active'
                            ? 'bg-n-teal-9'
                            : 'bg-n-slate-7'
                        "
                      />
                      {{
                        dept.status === 'active'
                          ? $t('AI_DEPARTMENTS.STATUS_ACTIVE')
                          : $t('AI_DEPARTMENTS.STATUS_INACTIVE')
                      }}
                    </span>
                  </div>
                </div>
                <div class="min-w-0">
                  <p
                    class="text-lg font-semibold text-n-slate-12 mb-0 truncate"
                  >
                    {{ dept.name }}
                  </p>
                  <p class="text-xs text-n-slate-11 line-clamp-2 mb-0">
                    {{ dept.objetivo || $t('AI_DEPARTMENTS.NO_OBJETIVO') }}
                  </p>
                </div>
                <div
                  class="flex flex-wrap items-center gap-x-4 gap-y-1 border-t border-n-weak pt-3 text-xs text-n-slate-11"
                >
                  <span class="inline-flex items-center gap-1">
                    <span class="i-lucide-list-checks size-3.5" />
                    {{
                      $t('AI_DEPARTMENTS.STATS_STEPS', {
                        count: dept.steps_count ?? 0,
                      })
                    }}
                  </span>
                  <span class="inline-flex items-center gap-1">
                    <span class="i-lucide-wrench size-3.5" />
                    {{
                      $t('AI_DEPARTMENTS.STATS_TOOLS', {
                        count: dept.tools_count ?? 0,
                      })
                    }}
                  </span>
                  <span class="inline-flex items-center gap-1">
                    <span class="i-lucide-book-open size-3.5" />
                    {{
                      $t('AI_DEPARTMENTS.STATS_KNOWLEDGE', {
                        count: dept.knowledge_sources_count ?? 0,
                      })
                    }}
                  </span>
                  <span
                    class="ml-auto inline-flex items-center gap-1 text-n-slate-10 group-hover:text-n-brand"
                  >
                    {{ $t('AI_DEPARTMENTS.CONFIGURE') }}
                    <span class="i-lucide-arrow-right size-3.5" />
                  </span>
                </div>
              </button>
            </div>
          </template>
        </div>

        <!-- TESTE -->
        <div v-else-if="activeKey === 'test'" class="flex flex-col gap-5">
          <div class="flex items-center gap-3">
            <span
              class="size-10 rounded-xl bg-n-brand/10 text-n-brand flex items-center justify-center shrink-0"
            >
              <span class="i-lucide-flask-conical size-5" />
            </span>
            <div class="flex flex-col">
              <h2 class="text-base font-semibold text-n-slate-12 mb-0">
                {{ $t('AI_AGENTS.TEST.LAB_TITLE') }}
              </h2>
              <p class="text-sm text-n-slate-11 mb-0">
                {{ $t('AI_AGENTS.TEST.LAB_SUBTITLE') }}
              </p>
            </div>
          </div>

          <p v-if="isNew" class="text-sm text-n-slate-11">
            {{ $t('AI_AGENTS.SAVE_FIRST') }}
          </p>

          <template v-else>
            <div
              class="rounded-2xl border border-n-weak bg-n-solid-2 p-4 flex flex-col gap-3"
            >
              <TextArea
                v-model="testMessage"
                :placeholder="$t('AI_AGENTS.TEST.PLACEHOLDER')"
                :max-length="1000"
              />
              <div class="flex justify-end">
                <Button
                  icon="i-lucide-play"
                  :label="$t('AI_AGENTS.TEST.SEND')"
                  :is-loading="isTesting"
                  @click="runTest"
                />
              </div>
            </div>

            <div v-if="testResult" class="flex flex-col gap-4">
              <p
                v-if="testResult.error"
                class="text-sm text-n-ruby-11 rounded-xl border border-n-ruby-6 bg-n-ruby-2 px-4 py-3"
              >
                {{ testResult.error }}
              </p>
              <template v-else>
                <!-- Simulação do diálogo -->
                <div class="flex flex-col gap-2">
                  <div
                    class="self-end max-w-[80%] rounded-2xl rounded-br-sm bg-n-brand text-white px-4 py-2.5 text-sm whitespace-pre-wrap"
                  >
                    {{ testMessage }}
                  </div>
                  <div
                    class="self-start max-w-[80%] rounded-2xl rounded-bl-sm bg-n-solid-1 border border-n-weak px-4 py-2.5 text-sm text-n-slate-12 whitespace-pre-wrap"
                  >
                    {{ testResult.reply || $t('AI_AGENTS.TEST.NONE') }}
                  </div>
                </div>

                <!-- Decisão de roteamento -->
                <div
                  v-if="testResult.routing_band"
                  class="flex items-center gap-2"
                >
                  <span class="text-xs text-n-slate-11">
                    {{ $t('AI_AGENTS.TEST.ROUTING') }}:
                  </span>
                  <span
                    class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium bg-n-alpha-2 text-n-slate-12"
                  >
                    {{ $t(`AI_AGENTS.TEST.BANDS.${testResult.routing_band}`) }}
                  </span>
                </div>

                <!-- Métricas do motor -->
                <div class="grid grid-cols-2 sm:grid-cols-3 gap-3">
                  <div
                    v-for="stat in [
                      {
                        icon: 'i-lucide-layers',
                        label: $t('AI_AGENTS.TEST.DEPARTMENT'),
                        value:
                          testResult.department || $t('AI_AGENTS.TEST.NONE'),
                      },
                      {
                        icon: 'i-lucide-wrench',
                        label: $t('AI_AGENTS.TEST.TOOL'),
                        value: testResult.tool || $t('AI_AGENTS.TEST.NONE'),
                      },
                      {
                        icon: 'i-lucide-book-open',
                        label: $t('AI_AGENTS.TEST.KNOWLEDGE'),
                        value: testResult.knowledge_used ?? 0,
                      },
                      {
                        icon: 'i-lucide-gauge',
                        label: $t('AI_AGENTS.TEST.SCORE'),
                        value:
                          testResult.vector_score ?? $t('AI_AGENTS.TEST.NONE'),
                      },
                      {
                        icon: 'i-lucide-cpu',
                        label: $t('AI_AGENTS.TEST.MODEL'),
                        value: testResult.model || $t('AI_AGENTS.TEST.NONE'),
                      },
                      {
                        icon: 'i-lucide-coins',
                        label: $t('AI_AGENTS.TEST.COST'),
                        value: testResult.cost ?? $t('AI_AGENTS.TEST.NONE'),
                      },
                      {
                        icon: 'i-lucide-timer',
                        label: $t('AI_AGENTS.TEST.TIME'),
                        value:
                          testResult.latency_ms ?? $t('AI_AGENTS.TEST.NONE'),
                      },
                      {
                        icon: 'i-lucide-hash',
                        label: $t('AI_AGENTS.TEST.TOKENS'),
                        value: `${testResult.tokens_in ?? 0} / ${testResult.tokens_out ?? 0}`,
                      },
                      {
                        icon: 'i-lucide-bot',
                        label: $t('AI_AGENTS.TEST.WORKER'),
                        value: testResult.worker
                          ? $t(`AI_AGENTS.TEST.WORKERS.${testResult.worker}`)
                          : $t('AI_AGENTS.TEST.NONE'),
                      },
                      {
                        icon: 'i-lucide-target',
                        label: $t('AI_AGENTS.TEST.CONFIDENCE'),
                        value:
                          testResult.confidence != null
                            ? `${Math.round(testResult.confidence * 100)}%`
                            : $t('AI_AGENTS.TEST.NONE'),
                      },
                    ]"
                    :key="stat.label"
                    class="rounded-xl border border-n-weak bg-n-solid-2 p-3 flex flex-col gap-1"
                  >
                    <span
                      class="flex items-center gap-1.5 text-xs text-n-slate-11"
                    >
                      <span :class="stat.icon" class="size-3.5 inline-block" />
                      {{ stat.label }}
                    </span>
                    <span class="text-sm font-medium text-n-slate-12 truncate">
                      {{ stat.value }}
                    </span>
                  </div>
                </div>

                <!-- Governança da decisão: por que a IA decidiu assim -->
                <div
                  class="rounded-xl border border-n-weak bg-n-solid-2 p-4 flex flex-col gap-2"
                >
                  <span class="text-xs font-semibold text-n-slate-12">
                    {{ $t('AI_AGENTS.TEST.GOVERNANCE_TITLE') }}
                  </span>
                  <div class="flex flex-col gap-1.5 text-xs text-n-slate-11">
                    <p class="mb-0">
                      <span
                        class="i-lucide-layers size-3.5 inline-block align-text-bottom"
                      />
                      {{ $t('AI_AGENTS.TEST.CHOSEN_BY') }}:
                      <span class="text-n-slate-12 font-medium">
                        {{ testResult.department || $t('AI_AGENTS.TEST.NONE') }}
                        <template v-if="testResult.department_method">
                          {{
                            `(${testMethodLabel(testResult.department_method)})`
                          }}
                        </template>
                      </span>
                    </p>
                    <p v-if="testResolvedBy" class="mb-0">
                      <span
                        class="i-lucide-sparkles size-3.5 inline-block align-text-bottom"
                      />
                      {{ $t('AI_AGENTS.TEST.RESOLVED_BY') }}:
                      <span class="text-n-slate-12 font-medium">
                        {{ $t(`AI_AGENTS.TEST.RESOLVED.${testResolvedBy}`) }}
                      </span>
                    </p>
                    <p class="mb-0">
                      <span
                        class="i-lucide-wrench size-3.5 inline-block align-text-bottom"
                      />
                      {{ $t('AI_AGENTS.TEST.TOOLS_CONSIDERED') }}:
                      <span class="text-n-slate-12">
                        {{
                          testResult.tools_considered?.length
                            ? testResult.tools_considered.join(', ')
                            : $t('AI_AGENTS.TEST.NONE')
                        }}
                      </span>
                      <template v-if="testResult.tool">
                        {{ ' · ' }}
                        <span class="text-n-slate-12 font-medium">
                          {{
                            `${$t('AI_AGENTS.TEST.TOOL_EXECUTED')}: ${testResult.tool}`
                          }}
                        </span>
                      </template>
                    </p>
                    <p v-if="testResult.handoff_reason" class="mb-0">
                      <span
                        class="i-lucide-user-round size-3.5 inline-block align-text-bottom"
                      />
                      {{ $t('AI_AGENTS.TEST.HANDOFF_BY') }}:
                      <span class="text-n-slate-12 font-medium">{{
                        testResult.handoff_reason
                      }}</span>
                    </p>
                  </div>
                </div>

                <div
                  v-if="testResult.knowledge_preview?.length"
                  class="rounded-xl border border-n-weak bg-n-solid-2 p-4 flex flex-col gap-1"
                >
                  <span class="text-xs font-medium text-n-slate-11">
                    {{ $t('AI_AGENTS.TEST.KNOWLEDGE_PREVIEW') }}
                  </span>
                  <ul class="text-xs text-n-slate-11 list-disc pl-4">
                    <li v-for="(k, i) in testResult.knowledge_preview" :key="i">
                      {{ k }}
                    </li>
                  </ul>
                </div>
              </template>
            </div>
          </template>
        </div>
      </div>
    </div>
  </div>
</template>
