import {
  SET_FLOW_UI_FLAG,
  CLEAR_FLOWS,
  SET_FLOWS,
  SET_FLOW_ITEM,
  DELETE_FLOW,
} from './types';
import OperationalFlowsAPI from '../../../api/operationalFlows';

export const actions = {
  get: async ({ commit }) => {
    commit(SET_FLOW_UI_FLAG, { isFetching: true });
    try {
      const response = await OperationalFlowsAPI.get();
      commit(CLEAR_FLOWS);
      commit(SET_FLOWS, response.data);
    } finally {
      commit(SET_FLOW_UI_FLAG, { isFetching: false });
    }
  },
  show: async ({ commit }, id) => {
    commit(SET_FLOW_UI_FLAG, { isFetchingItem: true });
    try {
      const response = await OperationalFlowsAPI.show(id);
      commit(SET_FLOW_ITEM, response.data);
    } finally {
      commit(SET_FLOW_UI_FLAG, { isFetchingItem: false });
    }
  },
  create: async ({ commit }, flowInfo) => {
    commit(SET_FLOW_UI_FLAG, { isCreating: true });
    try {
      const response = await OperationalFlowsAPI.create(flowInfo);
      commit(SET_FLOW_ITEM, response.data);
      return response.data;
    } finally {
      commit(SET_FLOW_UI_FLAG, { isCreating: false });
    }
  },
  update: async ({ commit }, { id, ...flowInfo }) => {
    commit(SET_FLOW_UI_FLAG, { isUpdating: true });
    try {
      const response = await OperationalFlowsAPI.update(id, flowInfo);
      commit(SET_FLOW_ITEM, response.data);
      return response.data;
    } finally {
      commit(SET_FLOW_UI_FLAG, { isUpdating: false });
    }
  },
  delete: async ({ commit }, id) => {
    commit(SET_FLOW_UI_FLAG, { isDeleting: true });
    try {
      await OperationalFlowsAPI.delete(id);
      commit(DELETE_FLOW, id);
    } finally {
      commit(SET_FLOW_UI_FLAG, { isDeleting: false });
    }
  },
};
