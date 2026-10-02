/* global axios */
import ApiClient from './ApiClient';

// Stage automations and AI follow-up cadences of a pipeline (nested under the closing flow).
class PipelineAutomationsAPI extends ApiClient {
  constructor() {
    super('operational_flows', { accountScoped: true });
  }

  list(flowId) {
    return axios.get(`${this.url}/${flowId}/pipeline_automations`);
  }

  createAutomation(flowId, automation) {
    return axios.post(`${this.url}/${flowId}/pipeline_automations`, {
      pipeline_automation: automation,
    });
  }

  updateAutomation(flowId, id, automation) {
    return axios.patch(`${this.url}/${flowId}/pipeline_automations/${id}`, {
      pipeline_automation: automation,
    });
  }

  deleteAutomation(flowId, id) {
    return axios.delete(`${this.url}/${flowId}/pipeline_automations/${id}`);
  }

  simulate(flowId, automation) {
    return axios.post(`${this.url}/${flowId}/pipeline_automations/simulate`, {
      pipeline_automation: automation,
    });
  }
}

export default new PipelineAutomationsAPI();
