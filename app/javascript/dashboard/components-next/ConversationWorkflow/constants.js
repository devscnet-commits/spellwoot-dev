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
export const SYSTEM_CONTACT_EMAIL_FIELD = '__contato_email__';

// Values for the contact-email system field. Lets a required attribute be gated on whether the
// contact already has an email on file (e.g. require the Email field only when it is missing).
export const CONTACT_EMAIL_FILLED = 'preenchido';
export const CONTACT_EMAIL_EMPTY = 'vazio';

export const contactEmailSystemValue = hasEmail =>
  hasEmail ? CONTACT_EMAIL_FILLED : CONTACT_EMAIL_EMPTY;

export const SYSTEM_CONDITION_FIELDS = [
  {
    value: SYSTEM_OUTCOME_FIELD,
    label: 'Resultado da Conversa (Sistema)',
    type: 'list',
    attributeValues: ['ganho', 'perdido'],
    isSystem: true,
  },
  {
    value: SYSTEM_CONTACT_EMAIL_FIELD,
    label: 'Email do contato (Sistema)',
    type: 'list',
    attributeValues: [CONTACT_EMAIL_FILLED, CONTACT_EMAIL_EMPTY],
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
  // A half-configured conditional rule (no condition value) never applies,
  // otherwise undefined === undefined would wrongly match.
  if (
    attr.condition_value == null ||
    attr.condition_value === '' ||
    (Array.isArray(attr.condition_value) && !attr.condition_value.length)
  ) {
    return false;
  }
  const fieldValue = formValues[attr.condition_field];
  return matchesConditionValue(fieldValue, attr.condition_value);
};

// Whether a closing requirement applies to the chosen resolution state. "if attribute = value"
// conditions pass through here: their evaluation is value-based and happens live in the modal.
const requirementApplies = (condition = {}, canonicalKey, polarity) => {
  if (condition.if) return true;
  if (condition.always) return true;
  const when = condition.when;
  if (!when) return true;
  if ('canonical_key' in when) return when.canonical_key === canonicalKey;
  if ('polarity' in when) return when.polarity === polarity;
  return true;
};

// Maps a closing flow's per-flow requirements to the attribute-definition shape the outcome modal
// renders, keeping only the ones that apply to the chosen resolution state. "if" conditions are
// mapped to the conditional rule shape so the modal shows/hides them as the trigger value changes.
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
      if (!def) return null;
      const ifClause = req.condition?.if;
      if (ifClause?.attribute_key) {
        return {
          ...def,
          key: req.attribute_key,
          rule: 'conditional',
          condition_field: ifClause.attribute_key,
          condition_value: ifClause.values || [],
        };
      }
      return { ...def, key: req.attribute_key, rule: 'always' };
    })
    .filter(Boolean);
};

