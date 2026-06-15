/* global axios */
import { DataManager } from '../helper/CacheHelper/DataManager';
import ApiClient from './ApiClient';

class CacheEnabledApiClient extends ApiClient {
  constructor(resource, options = {}) {
    super(resource, options);
    this.dataManager = new DataManager(this.accountIdFromRoute);
  }

  // eslint-disable-next-line class-methods-use-this
  get cacheModelName() {
    throw new Error('cacheModelName is not defined');
  }

  get(cache = false) {
    if (cache) {
      return this.getFromCache();
    }

    return this.getFromNetwork();
  }

  getFromNetwork() {
    return axios.get(this.url);
  }

  // An old tab holding a previous IndexedDB version blocks the open forever (the browser
  // waits for it to release the connection). Cap the wait so a stale tab can never freeze
  // the UI — past the timeout we just serve from the network.
  initDbWithTimeout(timeoutMs = 2000) {
    return Promise.race([
      this.dataManager.initDb(),
      new Promise((resolve, reject) => {
        setTimeout(() => reject(new Error('idb-open-timeout')), timeoutMs);
      }),
    ]);
  }

  // eslint-disable-next-line class-methods-use-this
  extractDataFromResponse(response) {
    return response.data.payload;
  }

  // eslint-disable-next-line class-methods-use-this
  marshallData(dataToParse) {
    return { data: { payload: dataToParse } };
  }

  async getFromCache() {
    try {
      // IDB is not supported in Firefox private mode: https://bugzilla.mozilla.org/show_bug.cgi?id=781982
      await this.initDbWithTimeout();
    } catch {
      return this.getFromNetwork();
    }

    const { data } = await axios.get(
      `/api/v1/accounts/${this.accountIdFromRoute}/cache_keys`
    );
    const cacheKeyFromApi = data.cache_keys[this.cacheModelName];
    const isCacheValid = await this.validateCacheKey(cacheKeyFromApi);

    let localData = [];
    if (isCacheValid) {
      localData = await this.dataManager.get({
        modelName: this.cacheModelName,
      });
    }

    if (localData.length === 0) {
      return this.refetchAndCommit(cacheKeyFromApi);
    }

    return this.marshallData(localData);
  }

  async refetchAndCommit(newKey = null) {
    const response = await this.getFromNetwork();

    try {
      await this.initDbWithTimeout();

      this.dataManager.replace({
        modelName: this.cacheModelName,
        data: this.extractDataFromResponse(response),
      });

      await this.dataManager.setCacheKeys({
        [this.cacheModelName]: newKey,
      });
    } catch {
      // Ignore error
    }

    return response;
  }

  async validateCacheKey(cacheKeyFromApi) {
    if (!this.dataManager.db) {
      await this.initDbWithTimeout();
    }

    const cachekey = await this.dataManager.getCacheKey(this.cacheModelName);
    return cacheKeyFromApi === cachekey;
  }
}

export default CacheEnabledApiClient;
