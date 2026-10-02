/* global axios */
import ApiClient from './ApiClient';

// Quick actions on a kanban card; the id is the conversation display_id.
class PipelineCardsAPI extends ApiClient {
  constructor() {
    super('pipeline_cards', { accountScoped: true });
  }

  setTemperature(conversationId, temperature) {
    return axios.patch(`${this.url}/${conversationId}`, { temperature });
  }

  aiFollowup(conversationId, payload = {}) {
    return axios.post(`${this.url}/${conversationId}/ai_followup`, payload);
  }
}

export default new PipelineCardsAPI();
