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

// Whether a closing requirement applies to the chosen resolution state.
const requirementApplies = (condition = {}, canonicalKey, polarity) => {
  if (condition.always) return true;
  const when = condition.when;
  if (!when) return true;
  if ('canonical_key' in when) return when.canonical_key === canonicalKey;
  if ('polarity' in when) return when.polarity === polarity;
  return true;
};

// Maps a closing flow's per-flow requirements to the attribute-definition shape the outcome modal
// renders, keeping only the ones that apply to the chosen resolution state. Requirements live only
// on the flow, so this always returns an array (empty when there is no flow or no requirements).
export const flowRequiredAttributes = (flow, canonicalKey, attributeOptions) => {
  const requirements = flow?.closing_requirements || [];
  if (!requirements.length) return [];

  const state = (flow.resolution_states || []).find(
    s => s.canonical_key === canonicalKey
  );
  const polarity = state?.polarity;

  return requirements
    .filter(req => requirementApplies(req.condition, canonicalKey, polarity))
    .map(req => {
      const def = (attributeOptions || []).find(
        a => a.value === req.attribute_key
      );
      return def ? { ...def, key: req.attribute_key, rule: 'always' } : null;
    })
    .filter(Boolean);
};

