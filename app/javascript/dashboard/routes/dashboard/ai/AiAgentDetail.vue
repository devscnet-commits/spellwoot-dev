<script setup>
/* global axios */
import { ref, reactive, computed, onMounted } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';

const route = useRoute();
const router = useRouter();
const { t } = useI18n();

const isNew = computed(() => route.params.agentId === 'new');
const agentId = ref(isNew.value ? null : route.params.agentId);
const activeTab = ref(route.query.tab === 'test' ? 'test' : 'about');

const profiles = ref([]);
const departments = ref([]);
const isSaving = ref(false);

const STAGES = ['production', 'staging', 'sandbox', 'experimental'];

const form = reactive({
  name: '',
  stage: 'sandbox',
  status: 'active',
  identify_as: 'human',
  assistant_name: '',
  company_name: '',
  site: '',
  version: '',
  assistant_language: '',
  assistant_voice: '',
  assistant_avatar: '',
  assistant_description: '',
  assistant_personality: '',
  base_prompt: '',
  guardrails: '',
  ai_operation_profile_id: '',
});

const accountUrl = () => `/api/v1/accounts/${route.params.accountId}`;
const agentUrl = () => `${accountUrl()}/ai_agents`;

const assignForm = data => {
  Object.keys(form).forEach(key => {
    if (data[key] !== undefined && data[key] !== null) form[key] = data[key];
  });
};

const fetchProfiles = async () => {
  const { data } = await axios.get(`${accountUrl()}/ai_operation_profiles`);
  profiles.value = Array.isArray(data) ? data : [];
};

const fetchAgent = async () => {
  if (isNew.value) return;
  const { data } = await axios.get(`${agentUrl()}/${agentId.value}`);
  assignForm(data);
};

const fetchDepartments = async () => {
  if (isNew.value) return;
  const { data } = await axios.get(
    `${agentUrl()}/${agentId.value}/ai_departments`
  );
  departments.value = Array.isArray(data) ? data : [];
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

const save = async () => {
  isSaving.value = true;
  try {
    if (isNew.value) {
      const { data } = await axios.post(agentUrl(), { ai_agent: { ...form } });
      agentId.value = data.id;
      useAlert(t('AI_AGENTS.SAVED'));
      router.replace({ name: 'ai_agent_detail', params: { agentId: data.id } });
      fetchDepartments();
      fetchInboxes();
    } else {
      await axios.patch(`${agentUrl()}/${agentId.value}`, {
        ai_agent: { ...form },
      });
      useAlert(t('AI_AGENTS.SAVED'));
    }
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

// --- Teste tab ---
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
  await Promise.all([
    fetchProfiles(),
    fetchAgent(),
    fetchDepartments(),
    fetchInboxes(),
  ]);
});
</script>

<template>
  <div class="flex flex-col w-full h-full overflow-auto p-6 gap-4">
    <div class="flex items-center gap-3">
      <button
        type="button"
        class="text-sm text-n-slate-11 hover:text-n-slate-12"
        @click="goBack"
      >
        {{ $t('AI_AGENTS.BACK') }}
      </button>
      <span class="text-n-slate-9">/</span>
      <h1 class="text-xl font-semibold text-n-slate-12">
        {{ form.assistant_name || form.name || $t('AI_AGENTS.NEW') }}
      </h1>
    </div>

    <div class="flex gap-1 border-b border-n-weak">
      <button
        type="button"
        class="px-4 py-2 text-sm font-medium border-b-2 -mb-px"
        :class="
          activeTab === 'about'
            ? 'border-n-brand text-n-brand'
            : 'border-transparent text-n-slate-11'
        "
        @click="activeTab = 'about'"
      >
        {{ $t('AI_AGENTS.TABS.ABOUT') }}
      </button>
      <button
        type="button"
        class="px-4 py-2 text-sm font-medium border-b-2 -mb-px"
        :class="
          activeTab === 'inboxes'
            ? 'border-n-brand text-n-brand'
            : 'border-transparent text-n-slate-11'
        "
        @click="activeTab = 'inboxes'"
      >
        {{ $t('AI_AGENTS.TABS.INBOXES') }}
      </button>
      <button
        type="button"
        class="px-4 py-2 text-sm font-medium border-b-2 -mb-px"
        :class="
          activeTab === 'departments'
            ? 'border-n-brand text-n-brand'
            : 'border-transparent text-n-slate-11'
        "
        @click="activeTab = 'departments'"
      >
        {{ $t('AI_AGENTS.TABS.DEPARTMENTS') }}
      </button>
      <button
        type="button"
        class="px-4 py-2 text-sm font-medium border-b-2 -mb-px"
        :class="
          activeTab === 'test'
            ? 'border-n-brand text-n-brand'
            : 'border-transparent text-n-slate-11'
        "
        @click="activeTab = 'test'"
      >
        {{ $t('AI_AGENTS.TABS.TEST') }}
      </button>
    </div>

    <!-- SOBRE -->
    <div v-if="activeTab === 'about'" class="flex flex-col gap-4 max-w-3xl">
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_AGENTS.FORM.NAME') }}
          <input
            v-model="form.name"
            type="text"
            class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
          />
        </label>
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_AGENTS.FORM.ASSISTANT_NAME') }}
          <input
            v-model="form.assistant_name"
            type="text"
            class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
          />
        </label>
      </div>

      <div class="flex flex-col gap-2">
        <span class="text-sm text-n-slate-12">{{
          $t('AI_AGENTS.IDENTIFY_AS.LABEL')
        }}</span>
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <button
            type="button"
            class="text-left px-4 py-3 rounded-lg border text-sm"
            :class="
              form.identify_as === 'human'
                ? 'border-n-brand bg-n-brand/5 text-n-slate-12'
                : 'border-n-weak text-n-slate-11'
            "
            @click="form.identify_as = 'human'"
          >
            {{ $t('AI_AGENTS.IDENTIFY_AS.HUMAN') }}
          </button>
          <button
            type="button"
            class="text-left px-4 py-3 rounded-lg border text-sm"
            :class="
              form.identify_as === 'ai'
                ? 'border-n-brand bg-n-brand/5 text-n-slate-12'
                : 'border-n-weak text-n-slate-11'
            "
            @click="form.identify_as = 'ai'"
          >
            {{ $t('AI_AGENTS.IDENTIFY_AS.AI') }}
          </button>
        </div>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_AGENTS.SOBRE.COMPANY') }}
          <input
            v-model="form.company_name"
            type="text"
            class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
          />
        </label>
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_AGENTS.SOBRE.SITE') }}
          <input
            v-model="form.site"
            type="text"
            class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
          />
        </label>
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_AGENTS.SOBRE.VERSION') }}
          <input
            v-model="form.version"
            type="text"
            class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
          />
        </label>
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_AGENTS.SOBRE.MODEL') }}
          <select
            v-model="form.ai_operation_profile_id"
            class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
          >
            <option value="">{{ $t('AI_AGENTS.FORM.NONE') }}</option>
            <option v-for="p in profiles" :key="p.id" :value="p.id">
              {{ p.name }}
            </option>
          </select>
        </label>
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_AGENTS.FORM.ASSISTANT_LANGUAGE') }}
          <input
            v-model="form.assistant_language"
            type="text"
            class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
          />
        </label>
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_AGENTS.FORM.STAGE') }}
          <select
            v-model="form.stage"
            class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
          >
            <option v-for="s in STAGES" :key="s" :value="s">{{ s }}</option>
          </select>
        </label>
      </div>

      <label class="flex flex-col gap-1 text-sm text-n-slate-12">
        {{ $t('AI_AGENTS.FORM.ASSISTANT_DESCRIPTION') }}
        <textarea
          v-model="form.assistant_description"
          rows="2"
          class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none"
        />
      </label>
      <label class="flex flex-col gap-1 text-sm text-n-slate-12">
        {{ $t('AI_AGENTS.FORM.ASSISTANT_PERSONALITY') }}
        <textarea
          v-model="form.assistant_personality"
          rows="2"
          class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none"
        />
      </label>
      <label class="flex flex-col gap-1 text-sm text-n-slate-12">
        {{ $t('AI_AGENTS.FORM.BASE_PROMPT') }}
        <textarea
          v-model="form.base_prompt"
          rows="4"
          class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none"
        />
      </label>
      <label class="flex flex-col gap-1 text-sm text-n-slate-12">
        {{ $t('AI_AGENTS.FORM.GUARDRAILS') }}
        <textarea
          v-model="form.guardrails"
          rows="3"
          class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none"
        />
      </label>

      <div class="flex justify-end gap-2">
        <button
          type="button"
          class="text-sm px-3 py-2 rounded-lg bg-n-alpha-2 text-n-slate-12"
          @click="goBack"
        >
          {{ $t('AI_AGENTS.FORM.CANCEL') }}
        </button>
        <button
          type="button"
          class="text-sm font-medium px-4 py-2 rounded-lg bg-n-brand text-white disabled:opacity-50"
          :disabled="isSaving"
          @click="save"
        >
          {{ $t('AI_AGENTS.FORM.SAVE') }}
        </button>
      </div>
    </div>

    <!-- CAIXAS -->
    <div
      v-else-if="activeTab === 'inboxes'"
      class="flex flex-col gap-4 max-w-3xl"
    >
      <div class="flex flex-col gap-1">
        <h2 class="text-base font-semibold text-n-slate-12">
          {{ $t('AI_AGENTS.INBOXES.TITLE') }}
        </h2>
        <p class="text-sm text-n-slate-11 mb-0">
          {{ $t('AI_AGENTS.INBOXES.DESCRIPTION') }}
        </p>
      </div>
      <p v-if="isNew" class="text-sm text-n-slate-11 py-8 text-center">
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
          <button
            type="button"
            class="text-sm font-medium px-3 py-2 rounded-lg bg-n-brand text-white"
            @click="saveInboxes"
          >
            {{ $t('AI_AGENTS.INBOXES.SAVE') }}
          </button>
        </div>
      </template>
    </div>

    <!-- DEPARTAMENTOS -->
    <div v-else-if="activeTab === 'departments'" class="flex flex-col gap-4">
      <p v-if="isNew" class="text-sm text-n-slate-11 py-8 text-center">
        {{ $t('AI_AGENTS.SAVE_FIRST') }}
      </p>
      <template v-else>
        <div class="flex items-center justify-between">
          <p class="text-sm text-n-slate-11 mb-0">
            {{ $t('AI_DEPARTMENTS.DESCRIPTION') }}
          </p>
          <button
            type="button"
            class="text-sm font-medium px-3 py-2 rounded-lg bg-n-brand text-white"
            @click="newDepartment"
          >
            {{ $t('AI_DEPARTMENTS.NEW') }}
          </button>
        </div>
        <p
          v-if="!departments.length"
          class="text-sm text-n-slate-11 py-8 text-center"
        >
          {{ $t('AI_DEPARTMENTS.EMPTY') }}
        </p>
        <div
          v-else
          class="border border-n-weak rounded-xl divide-y divide-n-weak"
        >
          <div
            v-for="dept in departments"
            :key="dept.id"
            class="flex items-center justify-between px-4 py-3"
          >
            <div class="min-w-0">
              <p class="text-sm font-medium text-n-slate-12">{{ dept.name }}</p>
              <p class="text-xs text-n-slate-11 truncate">
                {{ dept.objetivo }}
              </p>
            </div>
            <button
              class="shrink-0 text-n-brand hover:underline text-sm"
              @click="editDepartment(dept)"
            >
              {{ $t('AI_DEPARTMENTS.FORM.EDIT') }}
            </button>
          </div>
        </div>
      </template>
    </div>

    <!-- TESTE -->
    <div v-else-if="activeTab === 'test'" class="flex flex-col gap-4 max-w-3xl">
      <p v-if="isNew" class="text-sm text-n-slate-11 py-8 text-center">
        {{ $t('AI_AGENTS.SAVE_FIRST') }}
      </p>
      <template v-else>
        <h2 class="text-base font-semibold text-n-slate-12">
          {{ $t('AI_AGENTS.TEST.TITLE') }}
        </h2>
        <div class="flex flex-col gap-2">
          <textarea
            v-model="testMessage"
            rows="3"
            :placeholder="$t('AI_AGENTS.TEST.PLACEHOLDER')"
            class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none text-sm text-n-slate-12"
          />
          <div class="flex justify-end">
            <button
              type="button"
              class="text-sm font-medium px-4 py-2 rounded-lg bg-n-brand text-white disabled:opacity-50"
              :disabled="isTesting || !testMessage.trim()"
              @click="runTest"
            >
              {{ $t('AI_AGENTS.TEST.SEND') }}
            </button>
          </div>
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
                  testResult.knowledge_used
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
    </div>
  </div>
</template>
