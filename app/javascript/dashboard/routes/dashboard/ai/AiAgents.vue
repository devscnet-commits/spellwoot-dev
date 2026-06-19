<script setup>
/* global axios */
import { ref, reactive, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';

const route = useRoute();
const { t } = useI18n();

const STAGES = ['production', 'staging', 'sandbox', 'experimental'];

const agents = ref([]);
const profiles = ref([]);
const isLoading = ref(false);
const showForm = ref(false);

const blank = () => ({
  id: null,
  name: '',
  stage: 'sandbox',
  status: 'active',
  assistant_name: '',
  assistant_description: '',
  assistant_personality: '',
  assistant_language: 'pt-BR',
  assistant_voice: '',
  assistant_avatar: '',
  base_prompt: '',
  guardrails: '',
  ai_operation_profile_id: '',
});
const form = reactive(blank());

const baseUrl = () => `/api/v1/accounts/${route.params.accountId}`;

const fetchAgents = async () => {
  isLoading.value = true;
  try {
    const { data } = await axios.get(`${baseUrl()}/ai_agents`);
    agents.value = Array.isArray(data) ? data : [];
  } finally {
    isLoading.value = false;
  }
};

const fetchProfiles = async () => {
  try {
    const { data } = await axios.get(`${baseUrl()}/ai_operation_profiles`);
    profiles.value = Array.isArray(data) ? data : [];
  } catch (error) {
    profiles.value = [];
  }
};

const openNew = () => {
  Object.assign(form, blank());
  showForm.value = true;
};

const openEdit = agent => {
  Object.assign(form, blank(), agent);
  showForm.value = true;
};

const save = async () => {
  try {
    const payload = { ai_agent: { ...form } };
    if (form.id) {
      await axios.patch(`${baseUrl()}/ai_agents/${form.id}`, payload);
    } else {
      await axios.post(`${baseUrl()}/ai_agents`, payload);
    }
    useAlert(t('AI_AGENTS.SAVED'));
    showForm.value = false;
    fetchAgents();
  } catch (error) {
    useAlert(t('AI_AGENTS.ERROR'));
  }
};

const remove = async agent => {
  // eslint-disable-next-line no-alert
  if (!window.confirm(t('AI_AGENTS.CONFIRM_DELETE'))) return;
  try {
    await axios.delete(`${baseUrl()}/ai_agents/${agent.id}`);
    useAlert(t('AI_AGENTS.DELETED'));
    fetchAgents();
  } catch (error) {
    useAlert(t('AI_AGENTS.ERROR'));
  }
};

onMounted(() => {
  fetchAgents();
  fetchProfiles();
});
</script>

<template>
  <div class="flex flex-col w-full h-full overflow-auto p-6 gap-4">
    <div class="flex items-start justify-between gap-4">
      <div class="flex flex-col gap-1">
        <h1 class="text-xl font-semibold text-n-slate-12">
          {{ $t('AI_AGENTS.TITLE') }}
        </h1>
        <p class="text-sm text-n-slate-11 mb-0">{{ $t('AI_AGENTS.DESCRIPTION') }}</p>
      </div>
      <button
        type="button"
        class="shrink-0 text-sm font-medium px-3 py-2 rounded-lg bg-n-brand text-white"
        @click="openNew"
      >
        {{ $t('AI_AGENTS.NEW') }}
      </button>
    </div>

    <!-- List -->
    <p v-if="!isLoading && !agents.length" class="text-sm text-n-slate-11 py-8 text-center">
      {{ $t('AI_AGENTS.EMPTY') }}
    </p>
    <div v-else class="border border-n-weak rounded-xl overflow-hidden">
      <table class="w-full text-sm">
        <thead class="bg-n-alpha-2 text-n-slate-11">
          <tr>
            <th class="text-left font-medium px-3 py-2">{{ $t('AI_AGENTS.LIST.NAME') }}</th>
            <th class="text-left font-medium px-3 py-2">{{ $t('AI_AGENTS.LIST.STAGE') }}</th>
            <th class="text-left font-medium px-3 py-2">{{ $t('AI_AGENTS.LIST.STATUS') }}</th>
            <th class="text-right font-medium px-3 py-2">{{ $t('AI_AGENTS.LIST.ACTIONS') }}</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-n-weak text-n-slate-12">
          <tr v-for="agent in agents" :key="agent.id">
            <td class="px-3 py-2">{{ agent.assistant_name || agent.name }}</td>
            <td class="px-3 py-2">{{ agent.stage }}</td>
            <td class="px-3 py-2">{{ agent.status }}</td>
            <td class="px-3 py-2 text-right whitespace-nowrap">
              <router-link
                class="text-n-brand hover:underline mx-2"
                :to="{ name: 'ai_departments_index', params: { accountId: route.params.accountId, agentId: agent.id } }"
              >
                {{ $t('AI_AGENTS.LIST.DEPARTMENTS') }}
              </router-link>
              <button class="text-n-brand hover:underline mx-2" @click="openEdit(agent)">
                {{ $t('AI_AGENTS.LIST.EDIT') }}
              </button>
              <button class="text-n-ruby-11 hover:underline" @click="remove(agent)">
                {{ $t('AI_AGENTS.LIST.DELETE') }}
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>

    <!-- Identity form -->
    <div v-if="showForm" class="border border-n-weak rounded-xl p-5 flex flex-col gap-3 bg-n-solid-2">
      <h2 class="text-base font-semibold text-n-slate-12">{{ $t('AI_AGENTS.FORM.IDENTITY') }}</h2>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_AGENTS.FORM.NAME') }}
          <input v-model="form.name" type="text" class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1" />
        </label>
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_AGENTS.FORM.ASSISTANT_NAME') }}
          <input v-model="form.assistant_name" type="text" class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1" />
        </label>
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_AGENTS.FORM.STAGE') }}
          <select v-model="form.stage" class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1">
            <option v-for="s in STAGES" :key="s" :value="s">{{ s }}</option>
          </select>
        </label>
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_AGENTS.FORM.PROFILE') }}
          <select v-model="form.ai_operation_profile_id" class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1">
            <option value="">{{ $t('AI_AGENTS.FORM.NONE') }}</option>
            <option v-for="p in profiles" :key="p.id" :value="p.id">{{ p.name }}</option>
          </select>
        </label>
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_AGENTS.FORM.ASSISTANT_LANGUAGE') }}
          <input v-model="form.assistant_language" type="text" class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1" />
        </label>
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_AGENTS.FORM.ASSISTANT_VOICE') }}
          <input v-model="form.assistant_voice" type="text" class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1" />
        </label>
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_AGENTS.FORM.ASSISTANT_AVATAR') }}
          <input v-model="form.assistant_avatar" type="text" class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1" />
        </label>
      </div>
      <label class="flex flex-col gap-1 text-sm text-n-slate-12">
        {{ $t('AI_AGENTS.FORM.ASSISTANT_DESCRIPTION') }}
        <textarea v-model="form.assistant_description" rows="2" class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none" />
      </label>
      <label class="flex flex-col gap-1 text-sm text-n-slate-12">
        {{ $t('AI_AGENTS.FORM.ASSISTANT_PERSONALITY') }}
        <textarea v-model="form.assistant_personality" rows="2" class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none" />
      </label>
      <label class="flex flex-col gap-1 text-sm text-n-slate-12">
        {{ $t('AI_AGENTS.FORM.BASE_PROMPT') }}
        <textarea v-model="form.base_prompt" rows="3" class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none" />
      </label>
      <label class="flex flex-col gap-1 text-sm text-n-slate-12">
        {{ $t('AI_AGENTS.FORM.GUARDRAILS') }}
        <textarea v-model="form.guardrails" rows="2" class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none" />
      </label>
      <div class="flex justify-end gap-2">
        <button type="button" class="text-sm px-3 py-2 rounded-lg bg-n-alpha-2 text-n-slate-12" @click="showForm = false">
          {{ $t('AI_AGENTS.FORM.CANCEL') }}
        </button>
        <button type="button" class="text-sm font-medium px-3 py-2 rounded-lg bg-n-brand text-white" @click="save">
          {{ $t('AI_AGENTS.FORM.SAVE') }}
        </button>
      </div>
    </div>
  </div>
</template>
