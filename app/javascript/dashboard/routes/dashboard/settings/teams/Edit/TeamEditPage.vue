<script setup>
import { ref, computed, watch, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import SettingsLayout from 'dashboard/routes/dashboard/settings/SettingsLayout.vue';
import BaseSettingsHeader from 'dashboard/routes/dashboard/settings/components/BaseSettingsHeader.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import TeamsAPI from 'dashboard/api/teams';

const { t } = useI18n();
const route = useRoute();
const store = useStore();

// Integrantes is the most frequent action, so it is the default tab.
const activeTab = ref('members');

const teamId = computed(() => Number(route.params.teamId));
const getTeam = useMapGetter('teams/getTeam');
const team = computed(() => getTeam.value(teamId.value));
// Team names are stored lowercase; display them title-cased to match the teams list.
const teamTitle = computed(() =>
  (team.value?.name || '').replace(/(^|\s)(\p{L})/gu, (_, sep, ch) => sep + ch.toUpperCase())
);
const getTeamMembers = useMapGetter('teamMembers/getTeamMembers');
const members = computed(() => getTeamMembers.value(teamId.value) || []);
const agentList = useMapGetter('agents/getAgents');
const allInboxes = useMapGetter('inboxes/getInboxes');
const membersUiFlags = useMapGetter('teamMembers/getUIFlags');
const teamsUiFlags = useMapGetter('teams/getUIFlags');

const isFetchingMembers = computed(() => membersUiFlags.value?.isFetching);
const isSavingMembers = computed(
  () => membersUiFlags.value?.isUpdating || membersUiFlags.value?.isCreating
);
const isFetchingTeam = computed(() => teamsUiFlags.value?.isFetching);

// Details form
const formName = ref('');
const formDescription = ref('');
const formAllowAutoAssign = ref(true);
const isSavingDetails = ref(false);

// Members tab state
const memberFilter = ref('all');
const memberSearch = ref('');
const showAddPanel = ref(false);
const agentSearch = ref('');

// Linked inboxes state
const linkedInboxIds = ref([]);
const isLoadingInboxes = ref(false);

const AVAILABILITY_KEYS = ['online', 'busy', 'offline'];

const tabs = computed(() => [
  { key: 'members', label: t('TEAMS_SETTINGS.EDIT_FLOW.TABS.MEMBERS') },
  { key: 'details', label: t('TEAMS_SETTINGS.EDIT_FLOW.TABS.DETAILS') },
  { key: 'inboxes', label: t('TEAMS_SETTINGS.EDIT_FLOW.TABS.INBOXES') },
]);

// Função is read-only and derived from the agent's account role.
const roleKey = member =>
  member.role === 'administrator' ? 'administrator' : 'agent';
const roleLabel = member =>
  t(`TEAMS_SETTINGS.EDIT_FLOW.ACCOUNT_ROLES.${roleKey(member)}`);

const roleCounts = computed(() => {
  const counts = { all: members.value.length, agent: 0, administrator: 0 };
  members.value.forEach(member => {
    const key = roleKey(member);
    counts[key] = (counts[key] || 0) + 1;
  });
  return counts;
});

const roleFilters = computed(() =>
  ['all', 'agent', 'administrator'].map(key => ({
    key,
    label: t(`TEAMS_SETTINGS.EDIT_FLOW.FILTERS.${key}`),
    count: roleCounts.value[key] || 0,
  }))
);

const filteredMembers = computed(() => {
  const query = memberSearch.value.trim().toLowerCase();
  return members.value.filter(member => {
    if (
      memberFilter.value !== 'all' &&
      roleKey(member) !== memberFilter.value
    ) {
      return false;
    }
    if (!query) return true;
    return (
      (member.name || '').toLowerCase().includes(query) ||
      (member.email || '').toLowerCase().includes(query)
    );
  });
});

// Agents not yet in the team, filtered by the add-panel search.
const availableAgents = computed(() => {
  const memberIds = new Set(members.value.map(m => m.id));
  const query = agentSearch.value.trim().toLowerCase();
  return (agentList.value || []).filter(agent => {
    if (memberIds.has(agent.id)) return false;
    if (!query) return true;
    return (
      agent.name.toLowerCase().includes(query) ||
      agent.email.toLowerCase().includes(query)
    );
  });
});

const availabilityLabel = status => {
  const key = AVAILABILITY_KEYS.includes(status) ? status : 'offline';
  return t(`TEAMS_SETTINGS.EDIT_FLOW.AVAILABILITY.${key}`);
};

const isOnline = status => status === 'online';

function syncFromTeam(teamData) {
  if (!teamData) return;
  formName.value = teamData.name || '';
  formDescription.value = teamData.description || '';
  formAllowAutoAssign.value = teamData.allow_auto_assign ?? true;
}

async function loadInboxes() {
  isLoadingInboxes.value = true;
  try {
    if (!allInboxes.value?.length) store.dispatch('inboxes/get');
    const { data } = await TeamsAPI.getInboxes({ teamId: teamId.value });
    linkedInboxIds.value = data.map(i => i.id);
  } catch {
    linkedInboxIds.value = [];
  } finally {
    isLoadingInboxes.value = false;
  }
}

onMounted(() => {
  store.dispatch('agents/get');
  if (!team.value) store.dispatch('teams/get');
  store.dispatch('teamMembers/get', { teamId: teamId.value });
  loadInboxes();
});

watch(team, syncFromTeam, { immediate: true });

// Adding or removing an integrante saves immediately.
async function persistMembers(userIds, successKey) {
  try {
    await store.dispatch('teamMembers/update', {
      teamId: teamId.value,
      agentsList: userIds,
    });
    store.dispatch('teams/get');
    useAlert(t(`TEAMS_SETTINGS.EDIT_FLOW.${successKey}`));
  } catch {
    useAlert(t('TEAMS_SETTINGS.TEAM_FORM.ERROR_MESSAGE'));
  }
}

function addAgent(agent) {
  const ids = [...members.value.map(m => m.id), agent.id];
  agentSearch.value = '';
  showAddPanel.value = false;
  persistMembers(ids, 'MEMBER_ADDED');
}

function removeMember(agentId) {
  const ids = members.value.map(m => m.id).filter(id => id !== agentId);
  persistMembers(ids, 'MEMBER_REMOVED');
}

async function toggleInbox(inboxId) {
  const next = linkedInboxIds.value.includes(inboxId)
    ? linkedInboxIds.value.filter(id => id !== inboxId)
    : [...linkedInboxIds.value, inboxId];
  linkedInboxIds.value = next;
  try {
    await TeamsAPI.updateInboxes({ teamId: teamId.value, inboxIds: next });
    useAlert(t('TEAMS_SETTINGS.EDIT_FLOW.INBOXES.SAVED'));
  } catch {
    useAlert(t('TEAMS_SETTINGS.TEAM_FORM.ERROR_MESSAGE'));
    loadInboxes();
  }
}

async function saveDetails() {
  if (!formName.value.trim()) return;
  isSavingDetails.value = true;
  try {
    await store.dispatch('teams/update', {
      id: teamId.value,
      name: formName.value,
      description: formDescription.value,
      allow_auto_assign: formAllowAutoAssign.value,
    });
    useAlert(t('TEAMS_SETTINGS.EDIT_FLOW.UPDATE_SUCCESS'));
  } catch {
    useAlert(t('TEAMS_SETTINGS.TEAM_FORM.ERROR_MESSAGE'));
  } finally {
    isSavingDetails.value = false;
  }
}
</script>

<template>
  <SettingsLayout class="w-full">
    <template #header>
      <BaseSettingsHeader
        :title="teamTitle"
        :description="team?.description || ''"
        :back-button-label="t('TEAMS_SETTINGS.HEADER')"
      />
    </template>

    <template #body>
      <div class="flex flex-col w-full gap-4">
        <!-- Tabs -->
        <div class="flex gap-1 border-b border-n-weak">
          <button
            v-for="tab in tabs"
            :key="tab.key"
            type="button"
            class="px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors"
            :class="[
              activeTab === tab.key
                ? 'border-n-brand text-n-brand'
                : 'border-transparent text-n-slate-11 hover:text-n-slate-12',
            ]"
            @click="activeTab = tab.key"
          >
            {{ tab.label }}
          </button>
        </div>

        <!-- Members tab -->
        <div v-if="activeTab === 'members'" class="flex flex-col gap-4">
          <p class="text-sm text-n-slate-11">
            {{ t('TEAMS_SETTINGS.EDIT_FLOW.MEMBERS_SUBTITLE') }}
          </p>

          <!-- Filters + search + add -->
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div class="flex items-center gap-1">
              <button
                v-for="filter in roleFilters"
                :key="filter.key"
                type="button"
                class="px-2.5 py-1 rounded-lg text-sm font-medium transition-colors"
                :class="[
                  memberFilter === filter.key
                    ? 'bg-n-brand/10 text-n-brand'
                    : 'text-n-slate-11 hover:bg-n-alpha-2',
                ]"
                @click="memberFilter = filter.key"
              >
                {{ filter.label }}
                <span class="text-n-slate-10">{{ filter.count }}</span>
              </button>
            </div>
            <div class="flex items-center gap-2">
              <input
                v-model="memberSearch"
                type="search"
                :placeholder="t('TEAMS_SETTINGS.EDIT_FLOW.SEARCH_PLACEHOLDER')"
                class="w-48 px-3 py-1.5 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
              />
              <Button
                size="sm"
                :label="t('TEAMS_SETTINGS.EDIT_FLOW.ADD_MEMBER')"
                icon="i-lucide-user-plus"
                @click="showAddPanel = !showAddPanel"
              />
            </div>
          </div>

          <!-- Add member panel -->
          <div
            v-if="showAddPanel"
            class="flex flex-col gap-2 border border-n-weak rounded-xl p-3"
          >
            <input
              v-model="agentSearch"
              type="text"
              :placeholder="t('TEAMS_SETTINGS.EDIT_FLOW.SEARCH_PLACEHOLDER')"
              class="w-full px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
            />
            <div class="max-h-48 overflow-y-auto divide-y divide-n-weak">
              <button
                v-for="agent in availableAgents"
                :key="agent.id"
                type="button"
                class="w-full flex items-center gap-3 px-2 py-2 hover:bg-n-alpha-2 rounded-lg text-left transition-colors"
                @click="addAgent(agent)"
              >
                <Avatar :src="agent.thumbnail" :name="agent.name" :size="28" />
                <div class="min-w-0">
                  <p class="text-sm font-medium text-n-slate-12 truncate">
                    {{ agent.name }}
                  </p>
                  <p class="text-xs text-n-slate-11 truncate">
                    {{ agent.email }}
                  </p>
                </div>
              </button>
              <p
                v-if="!availableAgents.length"
                class="text-sm text-n-slate-11 text-center py-3"
              >
                {{ t('TEAMS_SETTINGS.EDIT_FLOW.NO_AVAILABLE_AGENTS') }}
              </p>
            </div>
          </div>

          <!-- Members list -->
          <div v-if="isFetchingMembers" class="flex justify-center py-8">
            <Spinner class="text-n-brand" />
          </div>
          <template v-else>
            <div
              v-if="filteredMembers.length"
              class="border border-n-weak rounded-xl divide-y divide-n-weak overflow-hidden"
            >
              <div
                v-for="member in filteredMembers"
                :key="member.id"
                class="flex items-center gap-3 px-4 py-3"
              >
                <Avatar
                  :src="member.thumbnail"
                  :name="member.name"
                  :size="32"
                />
                <div class="min-w-0 flex-1">
                  <p class="font-medium text-sm text-n-slate-12 truncate">
                    {{ member.name }}
                  </p>
                  <p class="text-xs text-n-slate-11 truncate">
                    {{ member.email }}
                  </p>
                </div>
                <span
                  class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium"
                  :class="[
                    roleKey(member) === 'administrator'
                      ? 'bg-n-teal-3 text-n-teal-11'
                      : 'bg-n-alpha-2 text-n-slate-11',
                  ]"
                >
                  {{ roleLabel(member) }}
                </span>
                <span
                  class="hidden sm:inline-flex items-center gap-1.5 text-xs text-n-slate-11 w-24"
                >
                  <span
                    class="size-2 rounded-full flex-shrink-0"
                    :class="[
                      isOnline(member.availability_status)
                        ? 'bg-n-teal-9'
                        : 'bg-n-slate-8',
                    ]"
                  />
                  {{ availabilityLabel(member.availability_status) }}
                </span>
                <button
                  type="button"
                  class="text-xs text-n-slate-11 hover:text-n-ruby-11 transition-colors"
                  :disabled="isSavingMembers"
                  @click="removeMember(member.id)"
                >
                  {{ t('TEAMS_SETTINGS.EDIT_FLOW.REMOVE_MEMBER') }}
                </button>
              </div>
            </div>
            <p v-else class="text-sm text-n-slate-11 text-center py-8">
              {{ t('TEAMS_SETTINGS.EDIT_FLOW.NO_MEMBERS') }}
            </p>
          </template>
        </div>

        <!-- Details tab -->
        <div v-else-if="activeTab === 'details'" class="flex flex-col gap-4">
          <div v-if="isFetchingTeam" class="flex justify-center py-8">
            <Spinner class="text-n-brand" />
          </div>
          <template v-else>
            <div class="flex flex-col gap-1">
              <label class="text-sm font-medium text-n-slate-12">
                {{ t('TEAMS_SETTINGS.FORM.NAME.LABEL') }}
              </label>
              <input
                v-model="formName"
                type="text"
                :placeholder="t('TEAMS_SETTINGS.FORM.NAME.PLACEHOLDER')"
                class="w-full px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
              />
            </div>
            <div class="flex flex-col gap-1">
              <label class="text-sm font-medium text-n-slate-12">
                {{ t('TEAMS_SETTINGS.FORM.DESCRIPTION.LABEL') }}
              </label>
              <textarea
                v-model="formDescription"
                rows="3"
                :placeholder="t('TEAMS_SETTINGS.FORM.DESCRIPTION.PLACEHOLDER')"
                class="w-full px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand resize-none"
              />
            </div>
            <div
              class="flex items-center justify-between py-2 px-3 rounded-lg bg-n-alpha-2"
            >
              <span class="text-sm font-medium text-n-slate-12">
                {{ t('TEAMS_SETTINGS.FORM.AUTO_ASSIGN.LABEL') }}
              </span>
              <Switch v-model="formAllowAutoAssign" />
            </div>
            <div class="flex justify-end">
              <Button
                :label="t('TEAMS_SETTINGS.EDIT_FLOW.CREATE.BUTTON_TEXT')"
                :disabled="!formName.trim() || isSavingDetails"
                :is-loading="isSavingDetails"
                @click="saveDetails"
              />
            </div>
          </template>
        </div>

        <!-- Inboxes tab -->
        <div v-else-if="activeTab === 'inboxes'" class="flex flex-col gap-4">
          <p class="text-sm text-n-slate-11">
            {{ t('TEAMS_SETTINGS.EDIT_FLOW.INBOXES.HINT') }}
          </p>
          <div v-if="isLoadingInboxes" class="flex justify-center py-8">
            <Spinner class="text-n-brand" />
          </div>
          <template v-else>
            <div
              v-if="(allInboxes || []).length"
              class="border border-n-weak rounded-xl divide-y divide-n-weak overflow-hidden"
            >
              <label
                v-for="ibx in allInboxes"
                :key="ibx.id"
                class="flex items-center gap-3 px-4 py-3 cursor-pointer hover:bg-n-alpha-2"
              >
                <input
                  type="checkbox"
                  :checked="linkedInboxIds.includes(ibx.id)"
                  class="m-0"
                  @change="toggleInbox(ibx.id)"
                />
                <span class="text-sm text-n-slate-12">{{ ibx.name }}</span>
              </label>
            </div>
            <p v-else class="text-sm text-n-slate-11 text-center py-4">
              {{ t('TEAMS_SETTINGS.EDIT_FLOW.INBOXES.EMPTY') }}
            </p>
          </template>
        </div>
      </div>
    </template>
  </SettingsLayout>
</template>
