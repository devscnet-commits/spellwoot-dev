<script setup>
import { ref, reactive, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import axios from 'axios';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';

const route = useRoute();
const { t } = useI18n();

const PROVIDERS = ['anthropic', 'openai', 'google', 'openrouter'];

const profiles = ref([]);
const isLoading = ref(false);
const showForm = ref(false);

const blank = () => ({
  id: null,
  name: '',
  supervisor_provider: 'anthropic',
  supervisor_model: '',
  budget_usd: '',
});
const form = reactive(blank());

const baseUrl = () => `/api/v1/accounts/${route.params.accountId}/ai_operation_profiles`;

const fetchProfiles = async () => {
  isLoading.value = true;
  try {
    const { data } = await axios.get(baseUrl());
    profiles.value = Array.isArray(data) ? data : [];
  } finally {
    isLoading.value = false;
  }
};

const openNew = () => {
  Object.assign(form, blank());
  showForm.value = true;
};

const openEdit = profile => {
  Object.assign(form, blank(), {
    id: profile.id,
    name: profile.name,
    supervisor_provider: profile.supervisor_provider,
    supervisor_model: profile.supervisor_model,
    budget_usd: profile.budget?.monthly_usd ?? '',
  });
  showForm.value = true;
};

const save = async () => {
  const payload = {
    ai_operation_profile: {
      name: form.name,
      supervisor_provider: form.supervisor_provider,
      supervisor_model: form.supervisor_model,
      budget: { monthly_usd: Number(form.budget_usd) || 0 },
    },
  };
  try {
    if (form.id) {
      await axios.patch(`${baseUrl()}/${form.id}`, payload);
    } else {
      await axios.post(baseUrl(), payload);
    }
    useAlert(t('AI_PROFILES.SAVED'));
    showForm.value = false;
    fetchProfiles();
  } catch (error) {
    useAlert(t('AI_PROFILES.ERROR'));
  }
};

const remove = async profile => {
  // eslint-disable-next-line no-alert
  if (!window.confirm(t('AI_PROFILES.CONFIRM_DELETE'))) return;
  try {
    await axios.delete(`${baseUrl()}/${profile.id}`);
    useAlert(t('AI_PROFILES.DELETED'));
    fetchProfiles();
  } catch (error) {
    useAlert(t('AI_PROFILES.ERROR'));
  }
};

onMounted(fetchProfiles);
</script>

<template>
  <div class="flex flex-col w-full h-full overflow-auto p-6 gap-4">
    <div class="flex items-start justify-between gap-4">
      <div class="flex flex-col gap-1">
        <h1 class="text-xl font-semibold text-n-slate-12">{{ $t('AI_PROFILES.TITLE') }}</h1>
        <p class="text-sm text-n-slate-11 mb-0">{{ $t('AI_PROFILES.DESCRIPTION') }}</p>
      </div>
      <button type="button" class="shrink-0 text-sm font-medium px-3 py-2 rounded-lg bg-n-brand text-white" @click="openNew">
        {{ $t('AI_PROFILES.NEW') }}
      </button>
    </div>

    <p v-if="!isLoading && !profiles.length" class="text-sm text-n-slate-11 py-8 text-center">
      {{ $t('AI_PROFILES.EMPTY') }}
    </p>
    <div v-else class="border border-n-weak rounded-xl divide-y divide-n-weak">
      <div v-for="profile in profiles" :key="profile.id" class="flex items-center justify-between px-4 py-3">
        <div class="min-w-0">
          <p class="text-sm font-medium text-n-slate-12">{{ profile.name }}</p>
          <p class="text-xs text-n-slate-11 truncate">{{ profile.supervisor_provider }} / {{ profile.supervisor_model }}</p>
        </div>
        <div class="shrink-0 whitespace-nowrap">
          <button class="text-n-brand hover:underline mx-2" @click="openEdit(profile)">{{ $t('AI_PROFILES.FORM.EDIT') }}</button>
          <button class="text-n-ruby-11 hover:underline" @click="remove(profile)">{{ $t('AI_PROFILES.FORM.DELETE') }}</button>
        </div>
      </div>
    </div>

    <div v-if="showForm" class="border border-n-weak rounded-xl p-5 flex flex-col gap-3 bg-n-solid-2">
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_PROFILES.FORM.NAME') }}
          <input v-model="form.name" type="text" class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1" />
        </label>
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_PROFILES.FORM.PROVIDER') }}
          <select v-model="form.supervisor_provider" class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1">
            <option v-for="p in PROVIDERS" :key="p" :value="p">{{ p }}</option>
          </select>
        </label>
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_PROFILES.FORM.MODEL') }}
          <input v-model="form.supervisor_model" type="text" class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1" />
        </label>
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_PROFILES.FORM.BUDGET') }}
          <input v-model="form.budget_usd" type="number" min="0" class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1" />
        </label>
      </div>
      <div class="flex justify-end gap-2">
        <button type="button" class="text-sm px-3 py-2 rounded-lg bg-n-alpha-2 text-n-slate-12" @click="showForm = false">
          {{ $t('AI_PROFILES.FORM.CANCEL') }}
        </button>
        <button type="button" class="text-sm font-medium px-3 py-2 rounded-lg bg-n-brand text-white" @click="save">
          {{ $t('AI_PROFILES.FORM.SAVE') }}
        </button>
      </div>
    </div>
  </div>
</template>
