/* global axios */
import ApiClient from '../ApiClient';

class AccountPlanAPI extends ApiClient {
  constructor() {
    super('', { accountScoped: true });
  }

  getLimits() {
    return axios.get(`${this.url}plan/limits`);
  }
}

export default new AccountPlanAPI();
