/* global axios */
// Must use the app's global axios: it carries the session auth headers — a bare
// import returns 401 on every call (the bug that got this screen disabled).

export default {
  get(accountId, provider) {
    return axios.get(
      `/api/v1/accounts/${accountId}/integration_settings/${provider}`
    );
  },
  update(accountId, provider, config, enabled = true) {
    return axios.put(
      `/api/v1/accounts/${accountId}/integration_settings/${provider}`,
      {
        config,
        enabled,
      }
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
  syncInstances(accountId, provider) {
    return axios.post(
      `/api/v1/accounts/${accountId}/integration_settings/${provider}/sync_instances`
    );
  },
  clearAccount(accountId, provider) {
    return axios.delete(
      `/api/v1/accounts/${accountId}/integration_settings/${provider}`
    );
  },
};
