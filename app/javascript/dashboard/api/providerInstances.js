/* global axios */
// Must use the app's global axios: it carries the session auth headers — a bare
// import returns 401 on every call (the bug that got this screen disabled).

export default {
  list(accountId, provider) {
    return axios.get(`/api/v1/accounts/${accountId}/provider_instances`, {
      params: { provider },
    });
  },
};
