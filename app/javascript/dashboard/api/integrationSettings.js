import axios from 'axios';

export default {
  get(accountId, provider) {
    return axios.get(`/api/v1/accounts/${accountId}/integration_settings/${provider}`);
  },
  update(accountId, provider, config) {
    return axios.put(`/api/v1/accounts/${accountId}/integration_settings/${provider}`, { config });
  },
};
