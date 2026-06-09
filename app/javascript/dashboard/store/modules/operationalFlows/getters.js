export const getters = {
  getFlows($state) {
    return Object.values($state.records).sort((a, b) => a.id - b.id);
  },
  getFlow: $state => id => {
    return $state.records[id] || {};
  },
  getUIFlags($state) {
    return $state.uiFlags;
  },
};
