import AccountPlanAPI from '../../api/account/plan';

export const state = {
  plan: null,
  aiCreditBalance: null,
  subscription: null,
  limits: [],
  overageCharges: [],
  availableUpgrades: [],
  uiFlags: {
    isFetching: false,
    isLoading: false,
    isUpgrading: false,
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
  },

  SET_UI_LOADING(_state, value) {
    _state.uiFlags.isLoading = value;
  },

  SET_UI_FETCHING(_state, value) {
    _state.uiFlags.isFetching = value;
  },

  SET_UI_UPGRADING(_state, value) {
    _state.uiFlags.isUpgrading = value;
  },
};

export const actions = {
  fetchPlanData({ commit }) {
    commit('SET_UI_FETCHING', true);
    return AccountPlanAPI.getLimits()
      .then(response => {
        commit('SET_PLAN_DATA', response.data);
      })
      .catch(() => {
        // Error handling
      })
      .finally(() => {
        commit('SET_UI_FETCHING', false);
      });
  },

  // Upgrade imediato (Plan::ChangeSubscriptionService#upgrade!, backend recusa downgrade/mesmo
  // plano). Recarrega os dados do plano ao terminar para refletir o novo plano/limites na tela.
  upgradePlan({ commit, dispatch }, planSlug) {
    commit('SET_UI_UPGRADING', true);
    return AccountPlanAPI.upgrade(planSlug)
      .then(() => dispatch('fetchPlanData'))
      .finally(() => {
        commit('SET_UI_UPGRADING', false);
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
  getUIFlags: _state => _state.uiFlags,
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
