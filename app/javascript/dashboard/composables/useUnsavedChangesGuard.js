import { unref } from 'vue';
import { onBeforeRouteLeave } from 'vue-router';
import { useI18n } from 'vue-i18n';

/**
 * Prompts for confirmation before leaving the route while a form has unsaved changes.
 *
 * @param {import('vue').Ref<boolean>|Function} isDirty - Ref/getter that is true when there are pending changes.
 * @param {string} messageKey - i18n key for the confirmation message.
 *
 * Usage:
 *   useUnsavedChangesGuard(isFormDirty, `${BASE_KEY}.EDIT.UNSAVED_LEAVE_CONFIRM`);
 */
export function useUnsavedChangesGuard(isDirty, messageKey) {
  const { t } = useI18n();

  onBeforeRouteLeave(() => {
    const dirty = typeof isDirty === 'function' ? isDirty() : unref(isDirty);
    if (!dirty) return true;
    // eslint-disable-next-line no-alert
    return window.confirm(t(messageKey));
  });
}
