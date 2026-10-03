/* global axios */
import ApiClient from './ApiClient';

// AI follow-up cadences of a pipeline's stages (one per stage, nested under the closing flow).
class PipelineAiFollowupsAPI extends ApiClient {
  constructor() {
    super('operational_flows', { accountScoped: true });
  }

  list(flowId) {
    return axios.get(`${this.url}/${flowId}/pipeline_ai_followups`);
  }

  createCadence(flowId, cadence) {
    return axios.post(`${this.url}/${flowId}/pipeline_ai_followups`, {
      pipeline_ai_followup: cadence,
    });
  }

  updateCadence(flowId, id, cadence) {
    return axios.patch(`${this.url}/${flowId}/pipeline_ai_followups/${id}`, {
      pipeline_ai_followup: cadence,
    });
  }

  deleteCadence(flowId, id) {
    return axios.delete(`${this.url}/${flowId}/pipeline_ai_followups/${id}`);
  }
}

export default new PipelineAiFollowupsAPI();
