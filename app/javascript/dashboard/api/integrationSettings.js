import axios from 'axios';

export default {
  get(accountId, provider) {
    return axios.get(`/api/v1/accounts/${accountId}/integration_settings/${provider}`);
  },
  update(accountId, provider, config, enabled = true) {
    return axios.put(`/api/v1/accounts/${accountId}/integration_settings/${provider}`, {
      config,
      enabled,
    });
  },
  importFromEnv(accountId, provider) {
    return axios.post(
      `/api/v1/accounts/${accountId}/integration_settings/${provider}/import_from_env`
    );
  },
  testConnection(accountId, provider) {
    return axios.post(
      `/api/v1/accounts/${accountId}/integration_settings/${provider}/test`
    );
  },
  syncChatwoot(accountId, provider) {
    return axios.post(
      `/api/v1/accounts/${accountId}/integration_settings/${provider}/sync_chatwoot`
    );
  },
};
