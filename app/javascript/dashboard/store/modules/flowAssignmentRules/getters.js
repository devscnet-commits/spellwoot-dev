export const getters = {
  getRules($state) {
    return Object.values($state.records).sort(
      (a, b) => a.priority - b.priority || a.id - b.id
    );
  },
  getUIFlags($state) {
    return $state.uiFlags;
  },
};
