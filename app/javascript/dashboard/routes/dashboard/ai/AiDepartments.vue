<script setup>
import { ref, reactive, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import axios from 'axios';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';

const route = useRoute();
const { t } = useI18n();

const departments = ref([]);
const isLoading = ref(false);
const showForm = ref(false);

const blank = () => ({
  id: null,
  name: '',
  objetivo: '',
  status: 'active',
  sla_timeout: '',
  on_timeout: 'resolve',
  steps: '',
  transfer_when: '',
  close_when: '',
  greeting: '',
});
const form = reactive(blank());

const baseUrl = () =>
  `/api/v1/accounts/${route.params.accountId}/ai_agents/${route.params.agentId}/ai_departments`;

const linesToArray = value =>
  (value || '')
    .split('\n')
    .map(line => line.trim())
    .filter(Boolean);

const arrayToLines = value => (Array.isArray(value) ? value.join('\n') : '');

const fetchDepartments = async () => {
  isLoading.value = true;
  try {
    const { data } = await axios.get(baseUrl());
    departments.value = Array.isArray(data) ? data : [];
  } finally {
    isLoading.value = false;
  }
};

const openNew = () => {
  Object.assign(form, blank());
  showForm.value = true;
};

const openEdit = dept => {
  const playbook = dept.playbook || {};
  Object.assign(form, blank(), {
    id: dept.id,
    name: dept.name,
    objetivo: dept.objetivo,
    status: dept.status,
    sla_timeout: dept.sla?.response_timeout_minutes ?? '',
    on_timeout: dept.sla?.on_timeout || 'resolve',
    steps: arrayToLines(playbook.steps),
    transfer_when: arrayToLines(playbook.transfer_when),
    close_when: arrayToLines(playbook.close_when),
    greeting: playbook.default_messages?.greeting || '',
  });
  showForm.value = true;
};

const save = async () => {
  const payload = {
    ai_department: {
      name: form.name,
      objetivo: form.objetivo,
      status: form.status,
      sla: { response_timeout_minutes: Number(form.sla_timeout) || 0, on_timeout: form.on_timeout },
      playbook: {
        objetivo: form.objetivo,
        steps: linesToArray(form.steps),
        transfer_when: linesToArray(form.transfer_when),
        close_when: linesToArray(form.close_when),
        default_messages: { greeting: form.greeting },
      },
    },
  };
  try {
    if (form.id) {
      await axios.patch(`${baseUrl()}/${form.id}`, payload);
    } else {
      await axios.post(baseUrl(), payload);
    }
    useAlert(t('AI_DEPARTMENTS.SAVED'));
    showForm.value = false;
    fetchDepartments();
  } catch (error) {
    useAlert(t('AI_DEPARTMENTS.ERROR'));
  }
};

const remove = async dept => {
  // eslint-disable-next-line no-alert
  if (!window.confirm(t('AI_DEPARTMENTS.CONFIRM_DELETE'))) return;
  try {
    await axios.delete(`${baseUrl()}/${dept.id}`);
    useAlert(t('AI_DEPARTMENTS.DELETED'));
    fetchDepartments();
  } catch (error) {
    useAlert(t('AI_DEPARTMENTS.ERROR'));
  }
};

onMounted(fetchDepartments);
</script>

<template>
  <div class="flex flex-col w-full h-full overflow-auto p-6 gap-4">
    <div class="flex items-start justify-between gap-4">
      <div class="flex flex-col gap-1">
        <h1 class="text-xl font-semibold text-n-slate-12">{{ $t('AI_DEPARTMENTS.TITLE') }}</h1>
        <p class="text-sm text-n-slate-11 mb-0">{{ $t('AI_DEPARTMENTS.DESCRIPTION') }}</p>
      </div>
      <button type="button" class="shrink-0 text-sm font-medium px-3 py-2 rounded-lg bg-n-brand text-white" @click="openNew">
        {{ $t('AI_DEPARTMENTS.NEW') }}
      </button>
    </div>

    <p v-if="!isLoading && !departments.length" class="text-sm text-n-slate-11 py-8 text-center">
      {{ $t('AI_DEPARTMENTS.EMPTY') }}
    </p>
    <div v-else class="border border-n-weak rounded-xl divide-y divide-n-weak">
      <div v-for="dept in departments" :key="dept.id" class="flex items-center justify-between px-4 py-3">
        <div class="min-w-0">
          <p class="text-sm font-medium text-n-slate-12">{{ dept.name }}</p>
          <p class="text-xs text-n-slate-11 truncate">{{ dept.objetivo }}</p>
        </div>
        <div class="shrink-0 whitespace-nowrap">
          <router-link
            class="text-n-brand hover:underline mx-2"
            :to="{ name: 'ai_tools_index', params: { accountId: route.params.accountId, agentId: route.params.agentId, departmentId: dept.id } }"
          >
            {{ $t('AI_DEPARTMENTS.TOOLS_LINK') }}
          </router-link>
          <router-link
            class="text-n-brand hover:underline mx-2"
            :to="{ name: 'ai_knowledge_index', params: { accountId: route.params.accountId, agentId: route.params.agentId, departmentId: dept.id } }"
          >
            {{ $t('AI_DEPARTMENTS.KNOWLEDGE_LINK') }}
          </router-link>
          <button class="text-n-brand hover:underline mx-2" @click="openEdit(dept)">{{ $t('AI_DEPARTMENTS.FORM.EDIT') }}</button>
          <button class="text-n-ruby-11 hover:underline" @click="remove(dept)">{{ $t('AI_DEPARTMENTS.FORM.DELETE') }}</button>
        </div>
      </div>
    </div>

    <div v-if="showForm" class="border border-n-weak rounded-xl p-5 flex flex-col gap-3 bg-n-solid-2">
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_DEPARTMENTS.FORM.NAME') }}
          <input v-model="form.name" type="text" class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1" />
        </label>
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_DEPARTMENTS.FORM.SLA_TIMEOUT') }}
          <input v-model="form.sla_timeout" type="number" min="0" class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1" />
        </label>
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_DEPARTMENTS.FORM.ON_TIMEOUT') }}
          <select v-model="form.on_timeout" class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1">
            <option value="resolve">{{ $t('AI_DEPARTMENTS.FORM.ON_TIMEOUT_RESOLVE') }}</option>
            <option value="none">{{ $t('AI_DEPARTMENTS.FORM.ON_TIMEOUT_NONE') }}</option>
          </select>
        </label>
      </div>
      <label class="flex flex-col gap-1 text-sm text-n-slate-12">
        {{ $t('AI_DEPARTMENTS.FORM.OBJETIVO') }}
        <input v-model="form.objetivo" type="text" class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1" />
      </label>
      <label class="flex flex-col gap-1 text-sm text-n-slate-12">
        {{ $t('AI_DEPARTMENTS.FORM.STEPS') }}
        <textarea v-model="form.steps" rows="4" class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none" />
      </label>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_DEPARTMENTS.FORM.TRANSFER_WHEN') }}
          <textarea v-model="form.transfer_when" rows="3" class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none" />
        </label>
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_DEPARTMENTS.FORM.CLOSE_WHEN') }}
          <textarea v-model="form.close_when" rows="3" class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none" />
        </label>
      </div>
      <label class="flex flex-col gap-1 text-sm text-n-slate-12">
        {{ $t('AI_DEPARTMENTS.FORM.GREETING') }}
        <input v-model="form.greeting" type="text" class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1" />
      </label>
      <div class="flex justify-end gap-2">
        <button type="button" class="text-sm px-3 py-2 rounded-lg bg-n-alpha-2 text-n-slate-12" @click="showForm = false">
          {{ $t('AI_DEPARTMENTS.FORM.CANCEL') }}
        </button>
        <button type="button" class="text-sm font-medium px-3 py-2 rounded-lg bg-n-brand text-white" @click="save">
          {{ $t('AI_DEPARTMENTS.FORM.SAVE') }}
        </button>
      </div>
    </div>
  </div>
</template>
