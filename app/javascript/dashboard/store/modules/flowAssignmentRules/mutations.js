import {
  SET_RULE_UI_FLAG,
  CLEAR_RULES,
  SET_RULES,
  SET_RULE_ITEM,
  DELETE_RULE,
} from './types';

export const mutations = {
  [SET_RULE_UI_FLAG]($state, data) {
    $state.uiFlags = { ...$state.uiFlags, ...data };
  },
  [CLEAR_RULES]: $state => {
    $state.records = {};
  },
  [SET_RULES]: ($state, data) => {
    const updatedRecords = { ...$state.records };
    data.forEach(rule => {
      updatedRecords[rule.id] = { ...(updatedRecords[rule.id] || {}), ...rule };
    });
    $state.records = updatedRecords;
  },
  [SET_RULE_ITEM]: ($state, data) => {
    $state.records = {
      ...$state.records,
      [data.id]: { ...($state.records[data.id] || {}), ...data },
    };
  },
  [DELETE_RULE]: ($state, id) => {
    const { [id]: toDelete, ...records } = $state.records;
    $state.records = records;
  },
};
