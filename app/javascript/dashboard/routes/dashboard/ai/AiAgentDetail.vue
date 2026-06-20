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

const stageBadge = computed(
  () => STAGE_BADGE[agentForm.stage] || STAGE_BADGE.experimental
);

const profileOptions = computed(() => [
  { value: '', label: t('AI_AGENTS.FORM.NONE') },
  ...profiles.value.map(p => ({ value: p.id, label: p.name })),
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
      fetchDepartments();
      // eslint-disable-next-line no-use-before-define
      fetchInboxes();
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

// --- Caixas (live/shadow binding) + "atende" summary at the top ---
const inboxes = ref([]);
const inboxesUrl = () => `${agentUrl()}/${agentId.value}/ai_agent_inboxes`;
const fetchInboxes = async () => {
  if (isNew.value) return;
  const { data } = await axios.get(inboxesUrl());
  inboxes.value = Array.isArray(data) ? data : [];
};
const boundInboxes = computed(() =>
  inboxes.value.filter(i => i.mode && i.mode !== 'none')
);
const inboxSearch = ref('');
const filteredInboxes = computed(() => {
  const q = inboxSearch.value.trim().toLowerCase();
  if (!q) return inboxes.value;
  return inboxes.value.filter(i => (i.name || '').toLowerCase().includes(q));
});
const modeLabel = mode =>
  mode === 'live' ? t('AI_AGENTS.INBOXES.LIVE') : t('AI_AGENTS.INBOXES.SHADOW');
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

onMounted(async () => {
  await fetchProfiles();
  await fetchAgent();
  await Promise.all([fetchDepartments(), fetchInboxes()]);
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

    <!-- Hero: avatar + identity + ambiente + a quem atende -->
    <div class="flex flex-col gap-3 px-6 pt-4 pb-5">
      <div class="flex items-center gap-4">
        <Avatar
          :src="agentForm.assistant_avatar"
          :name="agentForm.assistant_name || agentForm.name || 'IA'"
          :size="72"
          rounded-full
          allow-upload
          @upload="onAvatarUpload"
          @delete="onAvatarDelete"
        />
        <div class="flex flex-col gap-1 min-w-0">
          <div class="flex items-center gap-2 flex-wrap">
            <h1 class="text-xl font-semibold text-n-slate-12">
              {{
                agentForm.assistant_name ||
                agentForm.name ||
                $t('AI_AGENTS.NEW')
              }}
            </h1>
            <span
              class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium"
              :class="[stageBadge.bg, stageBadge.text]"
            >
              <span class="size-1.5 rounded-full" :class="stageBadge.dot" />
              {{ $t(`AI_AGENTS.STAGES.${agentForm.stage.toUpperCase()}`) }}
            </span>
          </div>
          <p class="text-sm text-n-slate-11 mb-0 truncate">
            {{ agentForm.company_name || $t('AI_AGENTS.DESCRIPTION') }}
          </p>
          <button
            type="button"
            class="text-xs text-n-brand hover:underline text-left"
            @click="generateAvatar"
          >
            {{ $t('AI_AGENTS.SOBRE.GENERATE') }}
          </button>
        </div>
      </div>

      <!-- Most critical config: what this agent serves -->
      <div
        v-if="!isNew"
        class="flex flex-col gap-1.5 rounded-xl border border-n-weak bg-n-solid-2 px-4 py-3"
      >
        <span class="text-xs font-medium text-n-slate-11">{{
          $t('AI_AGENTS.ATTENDS.TITLE')
        }}</span>
        <p v-if="!boundInboxes.length" class="text-sm text-n-slate-11 mb-0">
          {{ $t('AI_AGENTS.ATTENDS.NONE') }}
        </p>
        <div v-else class="flex flex-wrap gap-2">
          <span
            v-for="i in boundInboxes"
            :key="i.inbox_id"
            class="inline-flex items-center gap-1.5 px-2 py-1 rounded-lg bg-n-alpha-2 text-xs text-n-slate-12"
          >
            {{ i.name }}
            <span
              class="i-lucide-arrow-right size-3 inline-block text-n-slate-11"
            />
            <span
              class="font-medium"
              :class="i.mode === 'live' ? 'text-n-teal-11' : 'text-n-amber-11'"
            >
              {{ modeLabel(i.mode) }}
            </span>
          </span>
        </div>
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
            v-model="agentForm.category"
            :label="$t('AI_AGENTS.SOBRE.CATEGORY')"
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
          <Input
            v-model="agentForm.assistant_voice"
            :label="$t('AI_AGENTS.SOBRE.VOICE')"
          />
          <Input
            v-model="agentForm.assistant_language"
            :label="$t('AI_AGENTS.SOBRE.LANGUAGE')"
          />
        </div>

        <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div class="flex flex-col gap-1.5">
            <span class="text-sm font-medium text-n-slate-12">{{
              $t('AI_AGENTS.SOBRE.MODEL')
            }}</span>
            <Select
              v-model="agentForm.ai_operation_profile_id"
              :options="profileOptions"
            />
          </div>
          <div class="flex flex-col gap-1.5">
            <span class="text-sm font-medium text-n-slate-12">{{
              $t('AI_AGENTS.FORM.STAGE')
            }}</span>
            <Select v-model="agentForm.stage" :options="stageOptions" />
          </div>
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

        <div class="flex justify-end">
          <Button
            :label="$t('AI_AGENTS.FORM.SAVE')"
            :is-loading="isSaving"
            @click="saveAgent"
          />
        </div>
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
          <input
            v-model="inboxSearch"
            type="search"
            :placeholder="$t('AI_AGENTS.INBOXES.SEARCH')"
            class="w-full sm:w-64 px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12"
          />
          <div
            class="border border-n-weak rounded-xl divide-y divide-n-weak max-h-96 overflow-auto"
          >
            <div
              v-for="inbox in filteredInboxes"
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

      <!-- DEPARTAMENTOS -->
      <template v-else-if="activeKey === 'departments'">
        <div class="flex items-center justify-between">
          <p class="text-sm text-n-slate-11 mb-0">
            {{ $t('AI_DEPARTMENTS.DESCRIPTION') }}
          </p>
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
        <div
          v-else
          class="border border-n-weak rounded-xl divide-y divide-n-weak"
        >
          <button
            v-for="dept in departments"
            :key="dept.id"
            type="button"
            class="flex items-center justify-between gap-3 px-4 py-3 w-full text-left hover:bg-n-alpha-1"
            @click="editDepartment(dept)"
          >
            <div class="min-w-0">
              <p class="text-sm font-medium text-n-slate-12">{{ dept.name }}</p>
              <p class="text-xs text-n-slate-11 truncate">
                {{ dept.objetivo }}
              </p>
            </div>
            <span
              class="i-lucide-chevron-right size-4 text-n-slate-11 shrink-0"
            />
          </button>
        </div>
      </template>

      <!-- TESTE -->
      <template v-else-if="activeKey === 'test'">
        <p v-if="isNew" class="text-sm text-n-slate-11">
          {{ $t('AI_AGENTS.SAVE_FIRST') }}
        </p>
        <template v-else>
          <TextArea
            v-model="testMessage"
            :label="$t('AI_AGENTS.TEST.QUESTION')"
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
                    $t('AI_AGENTS.TEST.TOOL')
                  }}</span>
                  <span class="text-n-slate-12">{{
                    testResult.tool || $t('AI_AGENTS.TEST.NONE')
                  }}</span>
                </div>
                <div>
                  <span class="block text-xs text-n-slate-11">{{
                    $t('AI_AGENTS.TEST.KNOWLEDGE')
                  }}</span>
                  <span class="text-n-slate-12">{{
                    testResult.knowledge_used ?? 0
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
                    $t('AI_AGENTS.TEST.MODEL')
                  }}</span>
                  <span class="text-n-slate-12">{{
                    testResult.model || $t('AI_AGENTS.TEST.NONE')
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
                <div>
                  <span class="block text-xs text-n-slate-11">{{
                    $t('AI_AGENTS.TEST.TIME')
                  }}</span>
                  <span class="text-n-slate-12">{{
                    testResult.latency_ms ?? $t('AI_AGENTS.TEST.NONE')
                  }}</span>
                </div>
              </div>
              <div
                v-if="testResult.knowledge_preview?.length"
                class="flex flex-col gap-1"
              >
                <span class="text-xs text-n-slate-11">{{
                  $t('AI_AGENTS.TEST.KNOWLEDGE_PREVIEW')
                }}</span>
                <ul class="text-xs text-n-slate-11 list-disc pl-4">
                  <li v-for="(k, i) in testResult.knowledge_preview" :key="i">
                    {{ k }}
                  </li>
                </ul>
              </div>
            </template>
          </div>
        </template>
      </template>
    </div>
  </div>
</template>
