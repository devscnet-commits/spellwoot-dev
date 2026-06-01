import { computed } from 'vue';
import { useMapGetter } from 'dashboard/composables/store';
import { useAccount } from 'dashboard/composables/useAccount';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import { ATTRIBUTE_TYPES } from 'dashboard/components-next/ConversationWorkflow/constants';

// Normalize legacy string format to object format
const normalizeAttrConfig = item =>
  typeof item === 'string' ? { key: item, rule: 'always' } : item;

export function useConversationRequiredAttributes() {
  const { currentAccount, accountId } = useAccount();
  const isFeatureEnabledonAccount = useMapGetter(
    'accounts/isFeatureEnabledonAccount'
  );
  const conversationAttributes = useMapGetter(
    'attributes/getConversationAttributes'
  );

  const isFeatureEnabled = computed(() =>
    isFeatureEnabledonAccount.value(
      accountId.value,
      FEATURE_FLAGS.CONVERSATION_REQUIRED_ATTRIBUTES
    )
  );

  // Normalized array of { key, rule, condition_field?, condition_value? }
  const selectedAttributes = computed(() => {
    if (!isFeatureEnabled.value) return [];
    const raw =
      currentAccount.value?.settings?.conversation_required_attributes || [];
    return raw.map(normalizeAttrConfig);
  });

  // Backward-compat: array of keys only
  const requiredAttributeKeys = computed(() =>
    selectedAttributes.value.map(a => a.key)
  );

  const allAttributeOptions = computed(() =>
    (conversationAttributes.value || []).map(attribute => ({
      ...attribute,
      value: attribute.attributeKey,
      label: attribute.attributeDisplayName,
      type: attribute.attributeDisplayType,
      attributeValues: attribute.attributeValues,
    }))
  );

  // Full attribute definitions merged with rule config
  const requiredAttributes = computed(() =>
    selectedAttributes.value
      .map(attrConfig => {
        const def = allAttributeOptions.value.find(
          a => a.value === attrConfig.key
        );
        if (!def) return null;
        return { ...def, ...attrConfig };
      })
      .filter(Boolean)
  );

  const isRequired = (attrConfig, conversationCustomAttributes) => {
    if (attrConfig.rule === 'conditional') {
      return (
        conversationCustomAttributes[attrConfig.condition_field] ===
        attrConfig.condition_value
      );
    }
    return true;
  };

  const checkMissingAttributes = (conversationCustomAttributes = {}) => {
    if (!requiredAttributes.value.length) {
      return { hasMissing: false, missing: [] };
    }

    const missing = requiredAttributes.value.filter(attribute => {
      if (!isRequired(attribute, conversationCustomAttributes)) return false;

      const value = conversationCustomAttributes[attribute.value];

      if (attribute.type === ATTRIBUTE_TYPES.CHECKBOX) {
        return !(attribute.value in conversationCustomAttributes);
      }

      return value == null || String(value).trim() === '';
    });

    return {
      hasMissing: missing.length > 0,
      missing,
      all: requiredAttributes.value,
    };
  };

  return {
    selectedAttributes,
    requiredAttributeKeys,
    requiredAttributes,
    checkMissingAttributes,
  };
}
