export const ATTRIBUTE_TYPES = {
  TEXT: 'text',
  NUMBER: 'number',
  LINK: 'link',
  DATE: 'date',
  LIST: 'list',
  CHECKBOX: 'checkbox',
};

// System-level fields available as condition triggers (not custom attributes)
export const SYSTEM_OUTCOME_FIELD = '__resultado_conversa__';

export const SYSTEM_CONDITION_FIELDS = [
  {
    value: SYSTEM_OUTCOME_FIELD,
    label: 'Resultado da Conversa (Sistema)',
    type: 'list',
    attributeValues: ['ganho', 'perdido'],
    isSystem: true,
  },
];

// Map API outcome values to system field values
export const OUTCOME_TO_SYSTEM_VALUE = {
  won: 'ganho',
  lost: 'perdido',
};

// Returns true if attrConfig.condition_value matches fieldValue (supports OR via array)
export const matchesConditionValue = (fieldValue, conditionValue) => {
  if (Array.isArray(conditionValue)) return conditionValue.includes(fieldValue);
  return fieldValue === conditionValue;
};

// Returns true if an attribute should be visible given current form values
export const isAttrVisible = (attr, formValues) => {
  if (attr.rule !== 'conditional') return true;
  const fieldValue = formValues[attr.condition_field];
  return matchesConditionValue(fieldValue, attr.condition_value);
};

