import AccountPlanAPI from '../../api/account/plan';

export const state = {
  plan: null,
  aiCreditBalance: null,
  subscription: null,
  limits: [],
  overageCharges: [],
  availableUpgrades: [],
  aiKey: null,
  // Número da Conexiia (só dígitos) que recebe pedidos de upgrade; null = não configurado.
  upgradeWhatsappNumber: null,
  // null | 'no_plan' (conta sem assinatura ativa — API responde 404) | 'unknown'
  fetchError: null,
  uiFlags: {
    isFetching: false,
    isLoading: false,
  },
};

export const mutations = {
  SET_PLAN_DATA(_state, data) {
    _state.plan = data.plan;
    _state.aiCreditBalance = data.ai_credit_balance;
    _state.subscription = data.subscription;
    _state.limits = data.limits;
    _state.overageCharges = data.overage_charges || [];
    _state.availableUpgrades = data.available_upgrades || [];
    _state.aiKey = data.ai_key || null;
    _state.upgradeWhatsappNumber =
      data.upgrade_contact?.whatsapp_number || null;
  },

  SET_FETCH_ERROR(_state, value) {
    _state.fetchError = value;
  },

  SET_UI_LOADING(_state, value) {
    _state.uiFlags.isLoading = value;
  },

  SET_UI_FETCHING(_state, value) {
    _state.uiFlags.isFetching = value;
  },
};

export const actions = {
  fetchPlanData({ commit }) {
    commit('SET_UI_FETCHING', true);
    commit('SET_FETCH_ERROR', null);
    return AccountPlanAPI.getLimits()
      .then(response => {
        commit('SET_PLAN_DATA', response.data);
      })
      .catch(error => {
        commit(
          'SET_FETCH_ERROR',
          error?.response?.status === 404 ? 'no_plan' : 'unknown'
        );
      })
      .finally(() => {
        commit('SET_UI_FETCHING', false);
      });
  },
};

export const getters = {
  getPlan: _state => _state.plan,
  getAiCreditBalance: _state => _state.aiCreditBalance,
  getSubscription: _state => _state.subscription,
  getLimits: _state => _state.limits,
  getOverageCharges: _state => _state.overageCharges,
  getAvailableUpgrades: _state => _state.availableUpgrades,
  getAiKey: _state => _state.aiKey,
  getUpgradeWhatsappNumber: _state => _state.upgradeWhatsappNumber,
  getUIFlags: _state => _state.uiFlags,
  getFetchError: _state => _state.fetchError,
};

// store/index.js importa este módulo como default (`import plan from './modules/plan'`) e o registra
// namespaced (os getters são acessados como `plan/getPlan`). Sem este default o build do Vite/Rollup
// quebra ("default is not exported"). Mesma convenção de sla.js/reports.js.
export default {
  namespaced: true,
  state,
  getters,
  actions,
  mutations,
};
