<script setup>
import { ref, computed, watch, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import { useStore } from 'dashboard/composables/store';
import { useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import AgentSelector from '../AgentSelector.vue';
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

// Members
const selectedAgents = ref([]);
const isSavingMembers = ref(false);

function syncFromTeam(teamData) {
  if (!teamData) return;
  formName.value = teamData.name || '';
  formDescription.value = teamData.description || '';
  formAllowAutoAssign.value = teamData.allow_auto_assign ?? true;
}

onMounted(async () => {
  store.dispatch('agents/get');
  await store.dispatch('teamMembers/get', { teamId: teamId.value });
  selectedAgents.value = teamMembers.value.map(m => m.id);
});

watch(team, syncFromTeam, { immediate: true });
watch(teamMembers, members => {
  selectedAgents.value = members.map(m => m.id);
}, { immediate: false });

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
    await store.dispatch('teamMembers/update', {
      teamId: teamId.value,
      agentsList: selectedAgents.value,
    });
    await store.dispatch('teamMembers/get', { teamId: teamId.value });
    store.dispatch('teams/get');
    useAlert(t('TEAMS_SETTINGS.EDIT_FLOW.MEMBERS_UPDATED'));
  } catch {
    useAlert(t('TEAMS_SETTINGS.TEAM_FORM.ERROR_MESSAGE'));
  } finally {
    isSavingMembers.value = false;
  }
}
</script>

<template>
  <div class="p-6 col-span-full w-full max-w-3xl flex flex-col gap-6">
    <!-- Team name heading -->
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
        <Spinner class="text-n-blue-11" />
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
        <div class="flex items-center justify-between py-2 px-3 rounded-lg bg-n-slate-2">
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
        <Spinner class="text-n-blue-11" />
      </div>
      <form v-else @submit.prevent="saveMembers">
        <AgentSelector
          :agent-list="agentList.value || []"
          :selected-agents="selectedAgents"
          :update-selected-agents="(ids) => { selectedAgents.value = ids; }"
          :is-working="isSavingMembers"
          :submit-button-text="t('TEAMS_SETTINGS.EDIT_FLOW.AGENTS.BUTTON_TEXT')"
        />
      </form>
    </div>
  </div>
</template>
