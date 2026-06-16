<script>
import { mapGetters } from 'vuex';
import { useAlert } from 'dashboard/composables';

import router from '../../../../index';
import PageHeader from '../../SettingsSubPageHeader.vue';
import AgentSelector from '../AgentSelector.vue';
import { useVuelidate } from '@vuelidate/core';

export default {
  components: {
    PageHeader,
    AgentSelector,
  },
  validations: {
    selectedAgents: {
      isEmpty() {
        return !!this.selectedAgents.length;
      },
    },
  },

  setup() {
    return { v$: useVuelidate() };
  },

  data() {
    return {
      selectedAgents: [],
      isCreating: false,
    };
  },

  computed: {
    ...mapGetters({
      agentList: 'agents/getAgents',
      teamsList: 'teams/getTeams',
    }),

    // agentId -> team name for agents already in another team (single-team rule).
    lockedAgents() {
      const locked = {};
      (this.teamsList || []).forEach(team => {
        if (team.id === Number(this.teamId)) return;
        (team.member_ids || []).forEach(id => {
          locked[id] = team.name;
        });
      });
      return locked;
    },

    teamId() {
      return this.$route.params.teamId;
    },
    headerTitle() {
      return this.$t('TEAMS_SETTINGS.ADD.TITLE', {
        teamName: this.currentTeam.name,
      });
    },
    currentTeam() {
      return this.$store.getters['teams/getTeam'](this.teamId);
    },
  },

  mounted() {
    this.$store.dispatch('agents/get');
    this.$store.dispatch('teams/get', { cache: false });
  },

  methods: {
    updateSelectedAgents(newAgentList) {
      this.v$.selectedAgents.$touch();
      this.selectedAgents = [...newAgentList];
    },
    selectAllAgents() {
      this.selectedAgents = this.agentList.map(agent => agent.id);
    },
    async addAgents() {
      this.isCreating = true;
      const { teamId, selectedAgents } = this;

      try {
        await this.$store.dispatch('teamMembers/create', {
          teamId,
          agentsList: selectedAgents,
        });
        router.replace({
          name: 'settings_teams_finish',
          params: {
            page: 'new',
            teamId,
          },
        });
        this.$store.dispatch('teams/get');
      } catch (error) {
        useAlert(error.message);
      }
      this.isCreating = false;
    },
  },
};
</script>

<template>
  <div class="h-full w-full p-8 col-span-6 overflow-auto">
    <form class="flex flex-col gap-4 mx-0" @submit.prevent="addAgents">
      <PageHeader
        :header-title="headerTitle"
        :header-content="$t('TEAMS_SETTINGS.ADD.DESC')"
      />

      <div class="w-full h-full">
        <div v-if="v$.selectedAgents.$error">
          <p class="error-message pb-2">
            {{ $t('TEAMS_SETTINGS.ADD.AGENT_VALIDATION_ERROR') }}
          </p>
        </div>
        <AgentSelector
          :agent-list="agentList"
          :selected-agents="selectedAgents"
          :update-selected-agents="updateSelectedAgents"
          :is-working="isCreating"
          :submit-button-text="$t('TEAMS_SETTINGS.ADD.BUTTON_TEXT')"
          :locked-agents="lockedAgents"
        />
      </div>
    </form>
  </div>
</template>
