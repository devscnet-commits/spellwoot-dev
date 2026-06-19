<script setup>
/* global axios */
import { ref, computed, onMounted } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';

const route = useRoute();
const router = useRouter();
const { t } = useI18n();

const agents = ref([]);
const isLoading = ref(false);
const search = ref('');
const openMenuId = ref(null);

const baseUrl = () => `/api/v1/accounts/${route.params.accountId}/ai_agents`;

const filtered = computed(() => {
  const q = search.value.trim().toLowerCase();
  if (!q) return agents.value;
  return agents.value.filter(a =>
    `${a.assistant_name || ''} ${a.name || ''}`.toLowerCase().includes(q)
  );
});

const fetchAgents = async () => {
  isLoading.value = true;
  try {
    const { data } = await axios.get(baseUrl());
    agents.value = Array.isArray(data) ? data : [];
  } finally {
    isLoading.value = false;
  }
};

const goNew = () => router.push({ name: 'ai_agent_detail', params: { agentId: 'new' } });
const goEdit = agent => router.push({ name: 'ai_agent_detail', params: { agentId: agent.id } });
const goTest = agent =>
  router.push({ name: 'ai_agent_detail', params: { agentId: agent.id }, query: { tab: 'test' } });

const toggleMenu = id => {
  openMenuId.value = openMenuId.value === id ? null : id;
};

const duplicate = async agent => {
  openMenuId.value = null;
  try {
    const { data: full } = await axios.get(`${baseUrl()}/${agent.id}`);
    const copy = { ...full, id: undefined, name: `${full.name} (cópia)` };
    await axios.post(baseUrl(), { ai_agent: copy });
    useAlert(t('AI_AGENTS.SAVED'));
    fetchAgents();
  } catch (error) {
    useAlert(t('AI_AGENTS.ERROR'));
  }
};

const toggleActive = async agent => {
  openMenuId.value = null;
  const status = agent.status === 'active' ? 'inactive' : 'active';
  try {
    await axios.patch(`${baseUrl()}/${agent.id}`, { ai_agent: { status } });
    fetchAgents();
  } catch (error) {
    useAlert(t('AI_AGENTS.ERROR'));
  }
};

const remove = async agent => {
  openMenuId.value = null;
  // eslint-disable-next-line no-alert
  if (!window.confirm(t('AI_AGENTS.CONFIRM_DELETE'))) return;
  try {
    await axios.delete(`${baseUrl()}/${agent.id}`);
    useAlert(t('AI_AGENTS.DELETED'));
    fetchAgents();
  } catch (error) {
    useAlert(t('AI_AGENTS.ERROR'));
  }
};

onMounted(fetchAgents);
</script>

<template>
  <div class="flex flex-col w-full h-full overflow-auto p-6 gap-4">
    <div class="flex flex-col gap-1">
      <h1 class="text-xl font-semibold text-n-slate-12">{{ $t('AI_AGENTS.TITLE') }}</h1>
      <p class="text-sm text-n-slate-11 mb-0">{{ $t('AI_AGENTS.DESCRIPTION') }}</p>
    </div>

    <div class="flex items-center justify-between gap-3">
      <input
        v-model="search"
        type="search"
        :placeholder="$t('AI_AGENTS.SEARCH')"
        class="w-64 px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12"
      />
      <button
        type="button"
        class="text-sm font-medium px-3 py-2 rounded-lg bg-n-brand text-white"
        @click="goNew"
      >
        + {{ $t('AI_AGENTS.NEW') }}
      </button>
    </div>

    <p v-if="!isLoading && !filtered.length" class="text-sm text-n-slate-11 py-8 text-center">
      {{ $t('AI_AGENTS.EMPTY') }}
    </p>
    <div v-else class="border border-n-weak rounded-xl overflow-visible">
      <table class="w-full text-sm">
        <thead class="bg-n-alpha-2 text-n-slate-11">
          <tr>
            <th class="text-left font-medium px-3 py-2">{{ $t('AI_AGENTS.LIST.NAME') }}</th>
            <th class="text-left font-medium px-3 py-2">{{ $t('AI_AGENTS.LIST.TYPE') }}</th>
            <th class="text-left font-medium px-3 py-2">{{ $t('AI_AGENTS.LIST.STATUS') }}</th>
            <th class="text-right font-medium px-3 py-2">{{ $t('AI_AGENTS.LIST.ACTIONS') }}</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-n-weak text-n-slate-12">
          <tr v-for="agent in filtered" :key="agent.id">
            <td class="px-3 py-3">{{ agent.assistant_name || agent.name }}</td>
            <td class="px-3 py-3">{{ agent.stage }}</td>
            <td class="px-3 py-3">
              <span
                class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium"
                :class="agent.status === 'active' ? 'bg-n-teal-3 text-n-teal-11' : 'bg-n-alpha-2 text-n-slate-11'"
              >
                {{ agent.status === 'active' ? $t('AI_AGENTS.LIST.ACTIVE') : $t('AI_AGENTS.LIST.INACTIVE') }}
              </span>
            </td>
            <td class="px-3 py-3 text-right whitespace-nowrap relative">
              <button class="text-n-brand hover:underline mx-2" @click="goEdit(agent)">{{ $t('AI_AGENTS.LIST.EDIT') }}</button>
              <button class="text-n-brand hover:underline mx-2" @click="goTest(agent)">{{ $t('AI_AGENTS.LIST.TEST') }}</button>
              <button class="text-n-slate-11 hover:text-n-slate-12 px-1" @click="toggleMenu(agent.id)">⋮</button>
              <div
                v-if="openMenuId === agent.id"
                class="absolute right-2 top-full z-10 mt-1 w-40 bg-n-solid-1 border border-n-weak rounded-lg shadow text-left"
              >
                <button class="block w-full text-left px-3 py-2 hover:bg-n-alpha-2" @click="duplicate(agent)">{{ $t('AI_AGENTS.LIST.DUPLICATE') }}</button>
                <button class="block w-full text-left px-3 py-2 hover:bg-n-alpha-2" @click="toggleActive(agent)">
                  {{ agent.status === 'active' ? $t('AI_AGENTS.LIST.DEACTIVATE') : $t('AI_AGENTS.LIST.ACTIVATE') }}
                </button>
                <button class="block w-full text-left px-3 py-2 text-n-ruby-11 hover:bg-n-alpha-2" @click="remove(agent)">{{ $t('AI_AGENTS.LIST.DELETE') }}</button>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
