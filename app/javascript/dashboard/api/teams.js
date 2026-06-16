/* global axios */
// import ApiClient from './ApiClient';
import CacheEnabledApiClient from './CacheEnabledApiClient';

export class TeamsAPI extends CacheEnabledApiClient {
  constructor() {
    super('teams', { accountScoped: true });
  }

  // eslint-disable-next-line class-methods-use-this
  get cacheModelName() {
    return 'team';
  }

  // eslint-disable-next-line class-methods-use-this
  extractDataFromResponse(response) {
    return response.data;
  }

  // eslint-disable-next-line class-methods-use-this
  marshallData(dataToParse) {
    return { data: dataToParse };
  }

  getAgents({ teamId }) {
    return axios.get(`${this.url}/${teamId}/team_members`);
  }

  addAgents({ teamId, agentsList }) {
    return axios.post(`${this.url}/${teamId}/team_members`, {
      user_ids: agentsList,
    });
  }

  // agentsList: array of user_ids (legacy) or members: [{user_id, role}]
  updateAgents({ teamId, agentsList, members }) {
    const payload = members ? { members } : { user_ids: agentsList };
    return axios.patch(`${this.url}/${teamId}/team_members`, payload);
  }

  updateMemberRole({ teamId, userId, role }) {
    return axios.patch(`${this.url}/${teamId}/team_members/update_member_role`, {
      user_id: userId,
      role,
    });
  }

  getInboxes({ teamId }) {
    return axios.get(`${this.url}/${teamId}/team_inboxes`);
  }

  updateInboxes({ teamId, inboxIds }) {
    return axios.patch(`${this.url}/${teamId}/team_inboxes/update`, {
      inbox_ids: inboxIds,
    });
  }
}

export default new TeamsAPI();
