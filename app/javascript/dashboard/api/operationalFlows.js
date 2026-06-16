import ApiClient from './ApiClient';

class OperationalFlowsAPI extends ApiClient {
  constructor() {
    super('operational_flows', { accountScoped: true });
  }
}

export default new OperationalFlowsAPI();
