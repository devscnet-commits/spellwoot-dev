import axios from 'axios';

export default {
  list(accountId, provider) {
    return axios.get(`/api/v1/accounts/${accountId}/provider_instances`, {
      params: { provider },
    });
  },
};
