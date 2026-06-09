import ApiClient from './ApiClient';

class FlowAssignmentRulesAPI extends ApiClient {
  constructor() {
    super('flow_assignment_rules', { accountScoped: true });
  }
}

export default new FlowAssignmentRulesAPI();
