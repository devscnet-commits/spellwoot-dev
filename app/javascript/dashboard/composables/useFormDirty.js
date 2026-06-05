import { ref, computed, nextTick } from 'vue';

/**
 * Tracks whether a form has unsaved changes.
 *
 * @param {Function} getState - Returns the serializable form state to watch.
 *
 * Usage:
 *   const { isDirty, capture, reset } = useFormDirty(() => ({ name, description, ... }));
 *   // Call capture() after initial data loads.
 *   // Call reset()   after a successful save (or pass resetOnCapture: true).
 *   // isDirty.value  is true when the current state differs from the snapshot.
 */
export function useFormDirty(getState) {
  const snapshotStr = ref('');
  const initialized = ref(false);

  const serialize = () => JSON.stringify(getState());

  const capture = () => {
    nextTick(() => {
      snapshotStr.value = serialize();
      initialized.value = true;
    });
  };

  const isDirty = computed(() => {
    if (!initialized.value) return false;
    return serialize() !== snapshotStr.value;
  });

  // Reset dirty state to the current state (call after successful save).
  const reset = () => capture();

  return { isDirty, capture, reset };
}
