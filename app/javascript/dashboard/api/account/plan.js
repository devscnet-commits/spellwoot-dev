/* global axios */
import ApiClient from '../ApiClient';

class AccountPlanAPI extends ApiClient {
  constructor() {
    super('', { accountScoped: true });
  }

  getLimits() {
    return axios.get(`${this.url}plan/limits`);
  }

  // Não muda o plano: só avisa a equipe Conexiia (usado quando não há WhatsApp de upgrade configurado).
  requestUpgrade(planSlug) {
    return axios.post(`${this.url}plan/upgrade_request`, {
      plan_slug: planSlug,
    });
  }
}

export default new AccountPlanAPI();
