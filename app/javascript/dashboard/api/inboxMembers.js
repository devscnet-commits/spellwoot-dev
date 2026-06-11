/* global axios */
import ApiClient from './ApiClient';

class InboxMembers extends ApiClient {
  constructor() {
    super('inbox_members', { accountScoped: true });
  }

  update({ inboxId, agentList }) {
    return axios.patch(this.url, {
      inbox_id: inboxId,
      user_ids: agentList,
    });
  }

  updateWithEligibility({ inboxId, members }) {
    return axios.patch(this.url, {
      inbox_id: inboxId,
      members,
    });
  }

  removeAgents({ inboxId, agentIds }) {
    return axios.delete(this.url, {
      data: { inbox_id: inboxId, user_ids: agentIds },
    });
  }
}

export default new InboxMembers();
