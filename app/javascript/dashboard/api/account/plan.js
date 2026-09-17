/* global axios */
import ApiClient from '../ApiClient';

class AccountPlanAPI extends ApiClient {
  constructor() {
    super('', { accountScoped: true });
  }

  getLimits() {
    return axios.get(`${this.url}plan/limits`);
  }

  upgrade(planSlug) {
    return axios.post(`${this.url}plan/upgrade`, { plan_slug: planSlug });
  }
}

export default new AccountPlanAPI();
