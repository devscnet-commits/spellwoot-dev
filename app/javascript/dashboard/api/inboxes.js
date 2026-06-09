/* global axios */
import CacheEnabledApiClient from './CacheEnabledApiClient';

class Inboxes extends CacheEnabledApiClient {
  constructor() {
    super('inboxes', { accountScoped: true });
  }

  migrateInbox(sourceInboxId, targetInboxId, deleteSource = false) {
    return axios.post(`${this.url}/${sourceInboxId}/migrate`, {
      target_inbox_id: targetInboxId,
      delete_source: deleteSource,
    });
  }

  // eslint-disable-next-line class-methods-use-this
  get cacheModelName() {
    return 'inbox';
  }

  getCampaigns(inboxId) {
    return axios.get(`${this.url}/${inboxId}/campaigns`);
  }

  deleteInboxAvatar(inboxId) {
    return axios.delete(`${this.url}/${inboxId}/avatar`);
  }

  getAgentBot(inboxId) {
    return axios.get(`${this.url}/${inboxId}/agent_bot`);
  }

  setAgentBot(inboxId, botId) {
    return axios.post(`${this.url}/${inboxId}/set_agent_bot`, {
      agent_bot: botId,
    });
  }

  syncTemplates(inboxId) {
    return axios.post(`${this.url}/${inboxId}/sync_templates`);
  }

  replicateBusinessHours(inboxId, { scope, inboxIds = [] }) {
    return axios.post(`${this.url}/${inboxId}/replicate_business_hours`, {
      scope,
      inbox_ids: inboxIds,
    });
  }

  // UazAPI methods
  getUazapiStatus(inboxId) {
    return axios.get(`${this.url}/${inboxId}/uazapi_status`);
  }

  connectUazapi(inboxId) {
    return axios.post(`${this.url}/${inboxId}/uazapi_connect`);
  }

  disconnectUazapi(inboxId) {
    return axios.post(`${this.url}/${inboxId}/uazapi_disconnect`);
  }

  reconfigureUazapi(inboxId) {
    return axios.post(`${this.url}/${inboxId}/uazapi_reconfigure`);
  }

  createCSATTemplate(inboxId, template) {
    return axios.post(`${this.url}/${inboxId}/csat_template`, {
      template,
    });
  }

  getCSATTemplateStatus(inboxId) {
    return axios.get(`${this.url}/${inboxId}/csat_template`);
  }
}

export default new Inboxes();
