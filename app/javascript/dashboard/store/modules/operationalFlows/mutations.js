import {
  SET_FLOW_UI_FLAG,
  CLEAR_FLOWS,
  SET_FLOWS,
  SET_FLOW_ITEM,
  DELETE_FLOW,
} from './types';

export const mutations = {
  [SET_FLOW_UI_FLAG]($state, data) {
    $state.uiFlags = { ...$state.uiFlags, ...data };
  },
  [CLEAR_FLOWS]: $state => {
    $state.records = {};
  },
  [SET_FLOWS]: ($state, data) => {
    const updatedRecords = { ...$state.records };
    data.forEach(flow => {
      updatedRecords[flow.id] = { ...(updatedRecords[flow.id] || {}), ...flow };
    });
    $state.records = updatedRecords;
  },
  [SET_FLOW_ITEM]: ($state, data) => {
    $state.records = {
      ...$state.records,
      [data.id]: { ...($state.records[data.id] || {}), ...data },
    };
  },
  [DELETE_FLOW]: ($state, id) => {
    const { [id]: toDelete, ...records } = $state.records;
    $state.records = records;
  },
};
