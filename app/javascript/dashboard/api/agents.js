/* global axios */

import ApiClient from './ApiClient';

class Agents extends ApiClient {
  constructor() {
    super('agents', { accountScoped: true });
  }

  bulkInvite({ emails }) {
    return axios.post(`${this.url}/bulk_create`, {
      emails,
    });
  }

  deactivate(agentId) {
    return axios.post(`${this.url}/${agentId}/deactivate`);
  }

  reactivate(agentId) {
    return axios.post(`${this.url}/${agentId}/reactivate`);
  }
}

export default new Agents();
