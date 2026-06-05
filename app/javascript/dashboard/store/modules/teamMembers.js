import TeamsAPI from '../../api/teams';

export const SET_TEAM_MEMBERS_UI_FLAG = 'SET_TEAM_MEMBERS_UI_FLAG';
export const ADD_AGENTS_TO_TEAM = 'ADD_AGENTS_TO_TEAM';
export const UPDATE_TEAM_MEMBER_ROLE = 'UPDATE_TEAM_MEMBER_ROLE';

export const state = {
  records: {},
  uiFlags: {
    isFetching: false,
    isCreating: false,
    isUpdating: false,
    isDeleting: false,
  },
};

export const getters = {
  getUIFlags(_state) {
    return _state.uiFlags;
  },
  getTeamMembers: $state => id => {
    return $state.records[id] || [];
  },
};

export const actions = {
  get: async ({ commit }, { teamId }) => {
    commit(SET_TEAM_MEMBERS_UI_FLAG, { isFetching: true });
    try {
      const { data } = await TeamsAPI.getAgents({ teamId });
      commit(ADD_AGENTS_TO_TEAM, { data, teamId });
    } catch (error) {
      throw new Error(error);
    } finally {
      commit(SET_TEAM_MEMBERS_UI_FLAG, { isFetching: false });
    }
  },
  create: async ({ commit }, { agentsList, teamId }) => {
    commit(SET_TEAM_MEMBERS_UI_FLAG, { isCreating: true });
    try {
      const { data } = await TeamsAPI.addAgents({ agentsList, teamId });
      commit(ADD_AGENTS_TO_TEAM, { teamId, data });
    } catch (error) {
      throw new Error(error);
    } finally {
      commit(SET_TEAM_MEMBERS_UI_FLAG, { isCreating: false });
    }
  },
  update: async ({ commit }, { agentsList, members, teamId }) => {
    commit(SET_TEAM_MEMBERS_UI_FLAG, { isUpdating: true });
    try {
      const { data } = await TeamsAPI.updateAgents({ agentsList, members, teamId });
      commit(ADD_AGENTS_TO_TEAM, { data, teamId });
    } catch (error) {
      throw new Error(error);
    } finally {
      commit(SET_TEAM_MEMBERS_UI_FLAG, { isUpdating: false });
    }
  },
  updateMemberRole: async ({ commit }, { teamId, userId, role }) => {
    try {
      await TeamsAPI.updateMemberRole({ teamId, userId, role });
      commit(UPDATE_TEAM_MEMBER_ROLE, { teamId, userId, role });
    } catch (error) {
      throw new Error(error);
    }
  },
};

export const mutations = {
  [SET_TEAM_MEMBERS_UI_FLAG]($state, data) {
    $state.uiFlags = {
      ...$state.uiFlags,
      ...data,
    };
  },
  [ADD_AGENTS_TO_TEAM]($state, { data, teamId }) {
    $state.records = {
      ...$state.records,
      [teamId]: data,
    };
  },
  [UPDATE_TEAM_MEMBER_ROLE]($state, { teamId, userId, role }) {
    const members = $state.records[teamId];
    if (!members) return;
    const member = members.find(m => m.id === userId);
    if (member) member.team_role = role;
  },
};

export default {
  namespaced: true,
  state,
  getters,
  actions,
  mutations,
};
