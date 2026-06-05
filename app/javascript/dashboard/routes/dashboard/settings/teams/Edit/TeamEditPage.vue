<script setup>
import { ref, computed, watch, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

const { t } = useI18n();
const route = useRoute();
const store = useStore();

const activeTab = ref('details');

const teamId = computed(() => Number(route.params.teamId));
const getTeam = useMapGetter('teams/getTeam');
const team = computed(() => getTeam.value(teamId.value));
const getTeamMembers = useMapGetter('teamMembers/getTeamMembers');
const teamMembers = computed(() => getTeamMembers.value(teamId.value) || []);
const agentList = useMapGetter('agents/getAgents');
const membersUiFlags = useMapGetter('teamMembers/getUIFlags');
const teamsUiFlags = useMapGetter('teams/getUIFlags');

// Details form
const formName = ref('');
const formDescription = ref('');
const formAllowAutoAssign = ref(true);
const isSavingDetails = ref(false);

// Members local state — [{id, name, email, thumbnail, team_role}]
const localMembers = ref([]);
const showAddPanel = ref(false);
const agentSearch = ref('');
const isSavingMembers = ref(false);

const ROLES = computed(() => [
  { value: 'member', label: t('TEAMS_SETTINGS.MEMBER_ROLES.member') },
  { value: 'coordinator', label: t('TEAMS_SETTINGS.MEMBER_ROLES.coordinator') },
  { value: 'manager', label: t('TEAMS_SETTINGS.MEMBER_ROLES.manager') },
]);

function syncFromTeam(teamData) {
  if (!teamData) return;
  formName.value = teamData.name || '';
  formDescription.value = teamData.description || '';
  formAllowAutoAssign.value = teamData.allow_auto_assign ?? true;
}

function syncFromMembers(members) {
  localMembers.value = members.map(m => ({ ...m, team_role: m.team_role || 'member' }));
}

onMounted(async () => {
  store.dispatch('agents/get');
  await store.dispatch('teamMembers/get', { teamId: teamId.value });
  syncFromMembers(teamMembers.value);
});

watch(team, syncFromTeam, { immediate: true });
watch(teamMembers, syncFromMembers, { immediate: false });

// Agents not yet in localMembers, filtered by search
const availableAgents = computed(() => {
  const memberIds = new Set(localMembers.value.map(m => m.id));
  const query = agentSearch.value.trim().toLowerCase();
  return (agentList.value || []).filter(a => {
    if (memberIds.has(a.id)) return false;
    if (!query) return true;
    return a.name.toLowerCase().includes(query) || a.email.toLowerCase().includes(query);
  });
});

function addAgent(agent) {
  localMembers.value = [...localMembers.value, { ...agent, team_role: 'member' }];
  agentSearch.value = '';
}

function removeMember(agentId) {
  localMembers.value = localMembers.value.filter(m => m.id !== agentId);
}

function setMemberRole(agentId, role) {
  const m = localMembers.value.find(x => x.id === agentId);
  if (m) m.team_role = role;
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

async function saveMembers() {
  isSavingMembers.value = true;
  try {
    const members = localMembers.value.map(m => ({ user_id: m.id, role: m.team_role || 'member' }));
    await store.dispatch('teamMembers/update', { teamId: teamId.value, members });
    await store.dispatch('teamMembers/get', { teamId: teamId.value });
    store.dispatch('teams/get');
    useAlert(t('TEAMS_SETTINGS.EDIT_FLOW.MEMBERS_UPDATED'));
  } catch {
    useAlert(t('TEAMS_SETTINGS.TEAM_FORM.ERROR_MESSAGE'));
  } finally {
    isSavingMembers.value = false;
    showAddPanel.value = false;
  }
}
</script>

<template>
  <div class="p-6 col-span-full w-full max-w-3xl flex flex-col gap-6">
    <div class="flex flex-col gap-0.5">
      <h2 class="text-heading-2 font-semibold text-n-slate-12 capitalize">
        {{ team?.name || '' }}
      </h2>
      <p v-if="team?.description" class="text-body-main text-n-slate-11">
        {{ team.description }}
      </p>
    </div>

    <!-- Tabs -->
    <div class="flex gap-1 border-b border-n-weak">
      <button
        v-for="tab in [
          { key: 'details', label: t('TEAMS_SETTINGS.EDIT_FLOW.TABS.DETAILS') },
          { key: 'members', label: t('TEAMS_SETTINGS.EDIT_FLOW.TABS.MEMBERS') },
        ]"
        :key="tab.key"
        type="button"
        :class="[
          'px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors',
          activeTab === tab.key
            ? 'border-n-brand text-n-brand'
            : 'border-transparent text-n-slate-11 hover:text-n-slate-12',
        ]"
        @click="activeTab = tab.key"
      >
        {{ tab.label }}
      </button>
    </div>

    <!-- Details tab -->
    <div v-if="activeTab === 'details'" class="flex flex-col gap-4">
      <div v-if="teamsUiFlags.value?.isFetching" class="flex justify-center py-8">
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
        <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-n-alpha-2">
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

    <!-- Members tab -->
    <div v-else-if="activeTab === 'members'" class="flex flex-col gap-4">
      <div v-if="membersUiFlags.value?.isFetching" class="flex justify-center py-8">
        <Spinner class="text-n-brand" />
      </div>
      <template v-else>
        <!-- Current member list -->
        <div
          v-if="localMembers.length"
          class="divide-y divide-n-weak border border-n-weak rounded-xl overflow-hidden"
        >
          <div
            v-for="member in localMembers"
            :key="member.id"
            class="flex items-center gap-3 px-4 py-3"
          >
            <Avatar :src="member.thumbnail" :name="member.name" :size="32" />
            <div class="flex-1 min-w-0">
              <p class="text-sm font-medium text-n-slate-12 truncate">{{ member.name }}</p>
              <p class="text-xs text-n-slate-11 truncate">{{ member.email }}</p>
            </div>
            <select
              :value="member.team_role || 'member'"
              class="text-sm border border-n-weak rounded-lg px-2 py-1 bg-n-solid-1 text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
              @change="setMemberRole(member.id, $event.target.value)"
            >
              <option v-for="role in ROLES" :key="role.value" :value="role.value">
                {{ role.label }}
              </option>
            </select>
            <button
              type="button"
              class="text-xs text-n-slate-11 hover:text-n-ruby-11 transition-colors flex-shrink-0"
              @click="removeMember(member.id)"
            >
              {{ t('TEAMS_SETTINGS.EDIT_FLOW.REMOVE_MEMBER') }}
            </button>
          </div>
        </div>
        <p v-else class="text-sm text-n-slate-11 text-center py-4">
          {{ t('TEAMS_SETTINGS.EDIT_FLOW.NO_MEMBERS') }}
        </p>

        <!-- Add member panel -->
        <div v-if="showAddPanel" class="flex flex-col gap-2 border border-n-weak rounded-xl p-3">
          <input
            v-model="agentSearch"
            type="text"
            :placeholder="$t('AGENT_MGMT.SEARCH_PLACEHOLDER')"
            class="w-full px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
            autofocus
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
                <p class="text-sm font-medium text-n-slate-12 truncate">{{ agent.name }}</p>
                <p class="text-xs text-n-slate-11 truncate">{{ agent.email }}</p>
              </div>
            </button>
            <p v-if="!availableAgents.length" class="text-sm text-n-slate-11 text-center py-3">
              {{ $t('AGENT_MGMT.NO_RESULTS') }}
            </p>
          </div>
        </div>

        <!-- Actions -->
        <div class="flex items-center justify-between">
          <Button
            faded
            slate
            size="sm"
            :label="t('TEAMS_SETTINGS.EDIT_FLOW.ADD_MEMBER')"
            icon="i-lucide-user-plus"
            @click="showAddPanel = !showAddPanel"
          />
          <Button
            :label="t('TEAMS_SETTINGS.EDIT_FLOW.AGENTS.BUTTON_TEXT')"
            :disabled="isSavingMembers"
            :is-loading="isSavingMembers"
            @click="saveMembers"
          />
        </div>
      </template>
    </div>
  </div>
</template>
