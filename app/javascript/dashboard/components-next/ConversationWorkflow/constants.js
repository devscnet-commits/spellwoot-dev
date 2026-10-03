export const ATTRIBUTE_TYPES = {
  TEXT: 'text',
  NUMBER: 'number',
  CURRENCY: 'currency',
  PERCENT: 'percent',
  LINK: 'link',
  DATE: 'date',
  LIST: 'list',
  CHECKBOX: 'checkbox',
};

// Operators of a closing requirement's "if" clause (mirror of ClosingRequirement#operator_match?).
export const CONDITION_OPERATORS = [
  'equal_to',
  'not_equal_to',
  'is_present',
  'is_not_present',
  'greater_than',
  'less_than',
];

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

const isBlankValue = value =>
  value === undefined || value === null || String(value).trim() === '';

// Number typed in a custom attribute: 1234.56, "1234.56" or the Brazilian "R$ 1.234,56"
// (mirror of OperationalFlow.parse_amount so both sides compare the same number).
export const parseAmount = raw => {
  if (typeof raw === 'number') return raw;
  let text = String(raw ?? '').replace(/[^\d,.-]/g, '');
  if (text.includes(',')) text = text.replace(/\./g, '').replace(',', '.');
  return Number.parseFloat(text) || 0;
};

// Evaluates "<actual> <operator> <values>" the way the backend does: text comparison for
// equal/not equal, blank checks for presence and parsed amounts for greater/less than.
export const conditionOperatorMatches = (operator, actual, conditionValue) => {
  const values = (
    Array.isArray(conditionValue) ? conditionValue : [conditionValue]
  )
    .filter(value => value !== undefined && value !== null && value !== '')
    .map(String);
  const text = isBlankValue(actual) ? '' : String(actual);
  switch (operator) {
    case 'is_present':
      return text.trim() !== '';
    case 'is_not_present':
      return text.trim() === '';
    case 'not_equal_to':
      return values.length > 0 && !values.includes(text);
    case 'greater_than':
    case 'less_than': {
      if (isBlankValue(actual) || isBlankValue(values[0])) return false;
      const left = parseAmount(actual);
      const right = parseAmount(values[0]);
      return operator === 'greater_than' ? left > right : left < right;
    }
    default:
      return values.length > 0 && values.includes(text);
  }
};

// Returns true if an attribute should be visible given current form values
export const isAttrVisible = (attr, formValues) => {
  if (attr.rule !== 'conditional') return true;
  const operator = attr.condition_operator || 'equal_to';
  const fieldValue = formValues[attr.condition_field];
  // Presence checks carry no value: they only need the trigger attribute.
  if (operator === 'is_present' || operator === 'is_not_present') {
    return conditionOperatorMatches(operator, fieldValue, []);
  }
  // A half-configured conditional rule (no condition value) never applies,
  // otherwise undefined === undefined would wrongly match.
  if (
    attr.condition_value == null ||
    attr.condition_value === '' ||
    (Array.isArray(attr.condition_value) && !attr.condition_value.length)
  ) {
    return false;
  }
  return conditionOperatorMatches(operator, fieldValue, attr.condition_value);
};

// Whether a closing requirement applies to the chosen resolution state (mirror of
// ClosingRequirement#stage_match?). A closing state (won/lost) applies only to itself; an OPEN
// stage means "from this stage onward", so it reaches every closing state. "if" clauses are not
// decided here: their evaluation is value-based and happens live in the modal.
const requirementApplies = (condition, state, states) => {
  if (!condition) return true;
  const when = condition.when;
  if (condition.always || !when) return true;
  if ('polarity' in when) return state?.polarity === when.polarity;
  if (!('canonical_key' in when)) return true;
  const reference = states.find(s => s.canonical_key === when.canonical_key);
  if (reference?.polarity !== 'neutral') {
    return state?.canonical_key === when.canonical_key;
  }
  if (!state) return false;
  return (
    state.polarity !== 'neutral' || state.sort_order >= reference.sort_order
  );
};

// Maps a closing flow's per-flow requirements to the attribute-definition shape the outcome modal
// renders, keeping only the ones that apply to the chosen resolution state. "if" conditions are
// mapped to the conditional rule shape (with their operator) so the modal shows/hides them as the
// trigger value changes.
export const flowRequiredAttributes = (
  flow,
  canonicalKey,
  attributeOptions
) => {
  const requirements = flow?.closing_requirements || [];
  if (!requirements.length) return [];

  const states = flow.resolution_states || [];
  const state = states.find(s => s.canonical_key === canonicalKey);

  return requirements
    .filter(req => requirementApplies(req.condition, state, states))
    .map(req => {
      const def = (attributeOptions || []).find(
        a => a.value === req.attribute_key
      );
      if (!def) return null;
      const ifClause = req.condition?.if;
      if (ifClause?.attribute_key) {
        // Older rows stored a single `value`; the backend reads both shapes.
        const values =
          ifClause.values || (ifClause.value != null ? [ifClause.value] : []);
        return {
          ...def,
          key: req.attribute_key,
          rule: 'conditional',
          condition_field: ifClause.attribute_key,
          condition_operator: ifClause.operator || 'equal_to',
          condition_value: values,
        };
      }
      return { ...def, key: req.attribute_key, rule: 'always' };
    })
    .filter(Boolean);
};
