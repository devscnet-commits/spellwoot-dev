/* global axios */
import ApiClient from './ApiClient';

// CRM kanban: pipelines (closing flows with open stages), boards, card moves and reports.
class PipelinesAPI extends ApiClient {
  constructor() {
    super('pipelines', { accountScoped: true });
  }

  board(id, filters = {}) {
    return axios.get(`${this.url}/${id}`, { params: filters });
  }

  stageCards(id, stageId, { page, ...filters }) {
    return axios.get(`${this.url}/${id}/stages/${stageId}/cards`, {
      params: { page, ...filters },
    });
  }

  move(id, { conversationId, stageId, customAttributes }) {
    return axios.post(`${this.url}/${id}/move`, {
      conversation_id: conversationId,
      stage_id: stageId,
      custom_attributes: customAttributes,
    });
  }

  createCard(id, payload) {
    return axios.post(`${this.url}/${id}/cards`, payload);
  }

  report(id, params) {
    return axios.get(`${this.url}/${id}/report`, { params });
  }
}

export default new PipelinesAPI();
