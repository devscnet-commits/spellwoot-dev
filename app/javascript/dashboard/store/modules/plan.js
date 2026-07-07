import AccountPlanAPI from '../../api/account/plan';

export const state = {
  plan: null,
  aiCreditBalance: null,
  subscription: null,
  limits: [],
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
};

export const getters = {
  getPlan: _state => _state.plan,
  getAiCreditBalance: _state => _state.aiCreditBalance,
  getSubscription: _state => _state.subscription,
  getLimits: _state => _state.limits,
  getUIFlags: _state => _state.uiFlags,
};
