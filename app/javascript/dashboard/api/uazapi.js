/* global axios */
import ApiClient from './ApiClient';

class UazapiAPI extends ApiClient {
  constructor() {
    super('uazapi_inboxes', { accountScoped: true });
  }

  createInbox(data) {
    return axios.post(this.url, data);
  }

  fromInstance(data) {
    return axios.post(`${this.url}/from_instance`, data);
  }

  getStatus(inboxId) {
    return axios.get(`${this.baseUrl()}/inboxes/${inboxId}/uazapi_status`);
  }

  connect(inboxId) {
    return axios.post(`${this.baseUrl()}/inboxes/${inboxId}/uazapi_connect`);
  }

  disconnect(inboxId) {
    return axios.post(`${this.baseUrl()}/inboxes/${inboxId}/uazapi_disconnect`);
  }

  baseUrl() {
    return `${this.apiVersion}/accounts/${this.accountIdFromRoute}`;
  }
}

export default new UazapiAPI();
