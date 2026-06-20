<script setup>
/* global axios */
import { ref, computed, onMounted } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const route = useRoute();
const router = useRouter();
const { t } = useI18n();

const agents = ref([]);
const isLoading = ref(false);
const search = ref('');
const typeFilter = ref('all');
const statusFilter = ref('all');
const stageFilter = ref('all');
const openMenuId = ref(null);

const STAGE_ORDER = ['experimental', 'sandbox', 'staging', 'production'];
const STAGES = ['all', ...STAGE_ORDER];
const STATUSES = ['all', 'live', 'shadow', 'idle', 'inactive'];

const stageBadge = {
  production: 'bg-n-teal-3 text-n-teal-11',
  staging: 'bg-n-amber-3 text-n-amber-11',
  sandbox: 'bg-n-blue-3 text-n-blue-11',
  experimental: 'bg-n-alpha-2 text-n-slate-11',
};
const statusBadge = {
  live: { dot: 'bg-n-teal-9', cls: 'bg-n-teal-3 text-n-teal-11' },
  shadow: { dot: 'bg-n-amber-9', cls: 'bg-n-amber-3 text-n-amber-11' },
  idle: { dot: 'bg-n-slate-7', cls: 'bg-n-alpha-2 text-n-slate-11' },
  inactive: { dot: 'bg-n-slate-9', cls: 'bg-n-alpha-2 text-n-slate-11' },
};

const statusOf = a => {
  if (a.status === 'inactive') return 'inactive';
  if (a.has_live) return 'live';
  if (a.has_shadow) return 'shadow';
  return 'idle';
};

const nextStage = stage => {
  const i = STAGE_ORDER.indexOf(stage);
  return i >= 0 && i < STAGE_ORDER.length - 1 ? STAGE_ORDER[i + 1] : null;
};

const baseUrl = () => `/api/v1/accounts/${route.params.accountId}/ai_agents`;

const categories = computed(() => [
  'all',
  ...new Set(agents.value.map(a => a.category).filter(Boolean)),
]);

const filtered = computed(() => {
  const q = search.value.trim().toLowerCase();
  return agents.value.filter(a => {
    const okQuery =
      !q ||
      `${a.assistant_name || ''} ${a.name || ''} ${a.category || ''}`
        .toLowerCase()
        .includes(q);
    const okType =
      typeFilter.value === 'all' || a.category === typeFilter.value;
    const okStage =
      stageFilter.value === 'all' || a.stage === stageFilter.value;
    const okStatus =
      statusFilter.value === 'all' || statusOf(a) === statusFilter.value;
    return okQuery && okType && okStage && okStatus;
  });
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

const goNew = () =>
  router.push({ name: 'ai_agent_detail', params: { agentId: 'new' } });
const goEdit = agent =>
  router.push({ name: 'ai_agent_detail', params: { agentId: agent.id } });
const goTest = agent =>
  router.push({
    name: 'ai_agent_detail',
    params: { agentId: agent.id },
    query: { tab: 'test' },
  });

const toggleMenu = id => {
  openMenuId.value = openMenuId.value === id ? null : id;
};

const patchAgent = async (agent, payload, okMessage) => {
  openMenuId.value = null;
  try {
    await axios.patch(`${baseUrl()}/${agent.id}`, { ai_agent: payload });
    if (okMessage) useAlert(okMessage);
    fetchAgents();
  } catch (error) {
    useAlert(t('AI_AGENTS.ERROR'));
  }
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

const toggleActive = agent =>
  patchAgent(agent, {
    status: agent.status === 'active' ? 'inactive' : 'active',
  });

const promote = agent => {
  const next = nextStage(agent.stage);
  if (!next) return;
  patchAgent(agent, { stage: next }, t('AI_AGENTS.LIST.PROMOTED'));
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
  <div
    class="flex flex-col w-full h-full overflow-auto p-6 gap-4 max-w-5xl mx-auto"
  >
    <div class="flex items-start justify-between gap-4">
      <div class="flex flex-col gap-1">
        <h1 class="text-xl font-semibold text-n-slate-12">
          {{ $t('AI_AGENTS.TITLE') }}
        </h1>
        <p class="text-sm text-n-slate-11 mb-0">
          {{ $t('AI_AGENTS.DESCRIPTION') }}
        </p>
      </div>
      <Button
        icon="i-lucide-plus"
        :label="$t('AI_AGENTS.NEW')"
        @click="goNew"
      />
    </div>

    <div class="flex flex-wrap items-center gap-2">
      <input
        v-model="search"
        type="search"
        :placeholder="$t('AI_AGENTS.SEARCH')"
        class="w-56 px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12"
      />
      <select
        v-model="typeFilter"
        class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12"
      >
        <option value="all">{{ $t('AI_AGENTS.LIST.FILTER_TYPE') }}</option>
        <option v-for="c in categories.slice(1)" :key="c" :value="c">
          {{ c }}
        </option>
      </select>
      <select
        v-model="statusFilter"
        class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12"
      >
        <option v-for="s in STATUSES" :key="s" :value="s">
          {{
            s === 'all'
              ? $t('AI_AGENTS.LIST.FILTER_STATUS')
              : $t(`AI_AGENTS.LIST.STATUS_${s.toUpperCase()}`)
          }}
        </option>
      </select>
      <select
        v-model="stageFilter"
        class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12"
      >
        <option v-for="s in STAGES" :key="s" :value="s">
          {{ $t(`AI_AGENTS.STAGES.${s.toUpperCase()}`) }}
        </option>
      </select>
    </div>

    <p
      v-if="!isLoading && !filtered.length"
      class="text-sm text-n-slate-11 py-8 text-center"
    >
      {{ $t('AI_AGENTS.EMPTY') }}
    </p>
    <div v-else class="border border-n-weak rounded-xl overflow-visible">
      <table class="w-full text-sm">
        <thead class="bg-n-alpha-1 text-n-slate-11">
          <tr>
            <th class="text-left font-medium px-4 py-2.5">
              {{ $t('AI_AGENTS.LIST.NAME') }}
            </th>
            <th class="text-left font-medium px-3 py-2.5">
              {{ $t('AI_AGENTS.LIST.TYPE') }}
            </th>
            <th class="text-left font-medium px-3 py-2.5">
              {{ $t('AI_AGENTS.LIST.PROFILE') }}
            </th>
            <th class="text-left font-medium px-3 py-2.5">
              {{ $t('AI_AGENTS.LIST.DEPARTMENTS') }}
            </th>
            <th class="text-left font-medium px-3 py-2.5">
              {{ $t('AI_AGENTS.LIST.STATUS') }}
            </th>
            <th class="text-right font-medium px-4 py-2.5">
              {{ $t('AI_AGENTS.LIST.ACTIONS') }}
            </th>
          </tr>
        </thead>
        <tbody class="divide-y divide-n-weak text-n-slate-12">
          <tr
            v-for="agent in filtered"
            :key="agent.id"
            class="hover:bg-n-alpha-1"
          >
            <td class="px-4 py-3">
              <div class="flex items-center gap-2.5 min-w-0">
                <Avatar
                  :src="agent.assistant_avatar"
                  :name="agent.assistant_name || agent.name || 'IA'"
                  :size="32"
                  rounded-full
                />
                <div class="min-w-0">
                  <p class="text-sm font-medium text-n-slate-12 truncate">
                    {{ agent.assistant_name || agent.name }}
                  </p>
                  <span
                    class="inline-flex items-center gap-1 text-xs"
                    :class="
                      stageBadge[agent.stage]
                        ? 'text-n-slate-11'
                        : 'text-n-slate-11'
                    "
                  >
                    {{
                      $t(
                        `AI_AGENTS.STAGES.${(agent.stage || '').toUpperCase()}`
                      )
                    }}
                  </span>
                </div>
              </div>
            </td>
            <td class="px-3 py-3">
              {{ agent.category || $t('AI_AGENTS.LIST.NO_CATEGORY') }}
            </td>
            <td class="px-3 py-3 text-n-slate-11">
              {{
                agent.operation_profile_name || $t('AI_AGENTS.LIST.NO_PROFILE')
              }}
            </td>
            <td class="px-3 py-3 text-n-slate-11">
              {{
                $t('AI_AGENTS.LIST.DEPARTMENTS_COUNT', {
                  count: agent.departments_count ?? 0,
                })
              }}
            </td>
            <td class="px-3 py-3">
              <span
                class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium"
                :class="statusBadge[statusOf(agent)].cls"
              >
                <span
                  class="size-1.5 rounded-full"
                  :class="statusBadge[statusOf(agent)].dot"
                />
                {{
                  $t(`AI_AGENTS.LIST.STATUS_${statusOf(agent).toUpperCase()}`)
                }}
              </span>
            </td>
            <td class="px-4 py-3 text-right whitespace-nowrap relative">
              <div class="inline-flex items-center gap-0.5">
                <Button
                  variant="ghost"
                  color="slate"
                  size="sm"
                  icon="i-lucide-pencil"
                  :aria-label="$t('AI_AGENTS.LIST.EDIT')"
                  @click="goEdit(agent)"
                />
                <Button
                  variant="ghost"
                  color="slate"
                  size="sm"
                  icon="i-lucide-flask-conical"
                  :aria-label="$t('AI_AGENTS.LIST.TEST')"
                  @click="goTest(agent)"
                />
                <Button
                  variant="ghost"
                  color="slate"
                  size="sm"
                  icon="i-lucide-ellipsis-vertical"
                  :aria-label="$t('AI_AGENTS.LIST.ACTIONS')"
                  @click="toggleMenu(agent.id)"
                />
              </div>
              <div
                v-if="openMenuId === agent.id"
                class="absolute right-3 top-full z-10 mt-1 w-44 bg-n-solid-1 border border-n-weak rounded-lg shadow text-left py-1"
              >
                <button
                  class="block w-full text-left px-3 py-2 text-sm hover:bg-n-alpha-2"
                  @click="duplicate(agent)"
                >
                  {{ $t('AI_AGENTS.LIST.DUPLICATE') }}
                </button>
                <button
                  v-if="nextStage(agent.stage)"
                  class="block w-full text-left px-3 py-2 text-sm hover:bg-n-alpha-2"
                  @click="promote(agent)"
                >
                  {{
                    $t('AI_AGENTS.LIST.PROMOTE_TO', {
                      stage: $t(
                        `AI_AGENTS.STAGES.${nextStage(agent.stage).toUpperCase()}`
                      ),
                    })
                  }}
                </button>
                <button
                  class="block w-full text-left px-3 py-2 text-sm hover:bg-n-alpha-2"
                  @click="toggleActive(agent)"
                >
                  {{
                    agent.status === 'active'
                      ? $t('AI_AGENTS.LIST.DEACTIVATE')
                      : $t('AI_AGENTS.LIST.ACTIVATE')
                  }}
                </button>
                <button
                  class="block w-full text-left px-3 py-2 text-sm text-n-ruby-11 hover:bg-n-alpha-2"
                  @click="remove(agent)"
                >
                  {{ $t('AI_AGENTS.LIST.DELETE') }}
                </button>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
