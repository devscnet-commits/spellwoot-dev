import { computed } from 'vue';
import { useMapGetter } from 'dashboard/composables/store';
import { useAccount } from 'dashboard/composables/useAccount';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import {
  ATTRIBUTE_TYPES,
  SYSTEM_CONDITION_FIELDS,
  SYSTEM_OUTCOME_FIELD,
  OUTCOME_TO_SYSTEM_VALUE,
  matchesConditionValue,
  isAttrVisible,
} from 'dashboard/components-next/ConversationWorkflow/constants';

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
  // System fields (e.g. __resultado_conversa__) are not in allAttributeOptions —
  // they appear as condition triggers but not as required fields themselves.
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

  // All custom attributes available as condition fields (for the rule picker)
  const conditionFieldOptions = computed(() => [
    ...SYSTEM_CONDITION_FIELDS,
    ...allAttributeOptions.value.filter(a =>
      [ATTRIBUTE_TYPES.LIST, ATTRIBUTE_TYPES.TEXT].includes(a.type)
    ),
  ]);

  const isRequired = (attrConfig, context) => {
    if (attrConfig.rule === 'conditional') {
      const fieldValue = context[attrConfig.condition_field];
      return matchesConditionValue(fieldValue, attrConfig.condition_value);
    }
    return true;
  };

  // systemContext: optional dict with system field values (e.g. __resultado_conversa__)
  // derived from additional_attributes, since system fields are not in custom_attributes
  const checkMissingAttributes = (conversationCustomAttributes = {}, systemContext = {}) => {
    if (!requiredAttributes.value.length) {
      return { hasMissing: false, missing: [] };
    }

    const fullContext = { ...conversationCustomAttributes, ...systemContext };

    const missing = requiredAttributes.value.filter(attribute => {
      if (!isRequired(attribute, fullContext)) return false;

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
    conditionFieldOptions,
    checkMissingAttributes,
    isAttrVisible,
    SYSTEM_OUTCOME_FIELD,
  };
}
