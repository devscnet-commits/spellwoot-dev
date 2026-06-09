import {
  SET_RULE_UI_FLAG,
  CLEAR_RULES,
  SET_RULES,
  SET_RULE_ITEM,
  DELETE_RULE,
} from './types';
import FlowAssignmentRulesAPI from '../../../api/flowAssignmentRules';

export const actions = {
  get: async ({ commit }) => {
    commit(SET_RULE_UI_FLAG, { isFetching: true });
    try {
      const response = await FlowAssignmentRulesAPI.get();
      commit(CLEAR_RULES);
      commit(SET_RULES, response.data);
    } finally {
      commit(SET_RULE_UI_FLAG, { isFetching: false });
    }
  },
  create: async ({ commit }, ruleInfo) => {
    commit(SET_RULE_UI_FLAG, { isCreating: true });
    try {
      const response = await FlowAssignmentRulesAPI.create(ruleInfo);
      commit(SET_RULE_ITEM, response.data);
      return response.data;
    } finally {
      commit(SET_RULE_UI_FLAG, { isCreating: false });
    }
  },
  update: async ({ commit }, { id, ...ruleInfo }) => {
    commit(SET_RULE_UI_FLAG, { isUpdating: true });
    try {
      const response = await FlowAssignmentRulesAPI.update(id, ruleInfo);
      commit(SET_RULE_ITEM, response.data);
      return response.data;
    } finally {
      commit(SET_RULE_UI_FLAG, { isUpdating: false });
    }
  },
  delete: async ({ commit }, id) => {
    commit(SET_RULE_UI_FLAG, { isDeleting: true });
    try {
      await FlowAssignmentRulesAPI.delete(id);
      commit(DELETE_RULE, id);
    } finally {
      commit(SET_RULE_UI_FLAG, { isDeleting: false });
    }
  },
};
