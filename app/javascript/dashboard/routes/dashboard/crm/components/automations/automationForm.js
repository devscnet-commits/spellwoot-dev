// Shared bits of the stage automations page: option lists of the editor, draft factories, the
// delay <-> minutes conversion of the trigger inputs, validation and the payload sent to the API.
import { isBlank } from '../../helpers';

export const TRIGGER_TYPES = [
  { value: 'stage_entered', icon: 'i-lucide-log-in' },
  { value: 'time_in_stage', icon: 'i-lucide-timer' },
  { value: 'inactivity', icon: 'i-lucide-message-circle-off' },
];

export const INACTIVITY_SENDERS = ['agent', 'contact', 'any'];

export const DELAY_UNITS = [
  { value: 'minutes', minutes: 1 },
  { value: 'hours', minutes: 60 },
  { value: 'days', minutes: 1440 },
];

export const CONDITION_ATTRIBUTES = [
  'label',
  'priority',
  'team_id',
  'assignee_id',
  'custom_attribute',
  'sla',
  'temperature',
  'status',
];

// Mockup order: igual a / diferente / vazio / não está vazio / maior que / menor que.
export const OPERATORS = [
  'equal_to',
  'not_equal_to',
  'is_not_present',
  'is_present',
  'greater_than',
  'less_than',
];
export const VALUELESS_OPERATORS = ['is_present', 'is_not_present'];

export const PRIORITIES = ['urgent', 'high', 'medium', 'low'];
export const SLA_STATUSES = ['breached', 'on_time', 'none'];
export const TEMPERATURE_VALUES = ['hot', 'warm', 'cold'];
export const CONVERSATION_STATUSES = ['open', 'pending', 'resolved', 'snoozed'];

// Order of the "+ Adicionar Ação" dropdown.
export const ACTIONS = [
  { name: 'send_message', icon: 'i-lucide-message-square' },
  { name: 'add_private_note', icon: 'i-lucide-sticky-note' },
  { name: 'send_template', icon: 'i-lucide-layout-template' },
  { name: 'send_webhook', icon: 'i-lucide-webhook' },
  { name: 'create_conversation', icon: 'i-lucide-message-square-plus' },
  { name: 'move_stage', icon: 'i-lucide-kanban' },
  { name: 'assign_team', icon: 'i-lucide-users' },
  { name: 'assign_agent', icon: 'i-lucide-user-check' },
  { name: 'change_priority', icon: 'i-lucide-flag' },
  { name: 'add_label', icon: 'i-lucide-tag' },
  { name: 'remove_label', icon: 'i-lucide-tags' },
  { name: 'add_sla', icon: 'i-lucide-alarm-clock' },
  { name: 'remove_sla', icon: 'i-lucide-alarm-clock-off' },
  { name: 'change_status', icon: 'i-lucide-circle-check' },
  { name: 'change_temperature', icon: 'i-lucide-thermometer' },
];

export const actionIcon = name =>
  ACTIONS.find(action => action.name === name)?.icon || 'i-lucide-zap';

// inbox_id of send_template is only for the editor (templates are listed per inbox); the backend
// sends the template on the card's own conversation.
const DEFAULT_PARAMS = {
  send_message: () => ({ content: '' }),
  add_private_note: () => ({ content: '' }),
  send_template: () => ({ inbox_id: '', template: null, content: '' }),
  send_webhook: () => ({ url: '' }),
  create_conversation: () => ({ inbox_id: '', content: '', template: null }),
  move_stage: ({ pipelineId }) => ({ pipeline_id: pipelineId, stage_id: '' }),
  assign_team: () => ({ team_id: '' }),
  assign_agent: () => ({ assignee_id: '' }),
  change_priority: () => ({ priority: '' }),
  add_label: () => ({ labels: [] }),
  remove_label: () => ({ labels: [] }),
  add_sla: () => ({ minutes: 15 }),
  remove_sla: () => ({}),
  change_status: () => ({ status: '' }),
  change_temperature: () => ({ temperature: '' }),
};

export const newAutomation = stageId => ({
  id: null,
  resolution_state_id: stageId,
  name: '',
  active: true,
  trigger_type: 'stage_entered',
  delay_minutes: 0,
  inactivity_sender: 'agent',
  match_type: 'all',
  conditions: [],
  actions: [],
  sort_order: 0,
});

export const newCondition = () => ({
  attribute: 'label',
  attribute_key: '',
  operator: 'equal_to',
  value: '',
});

export const newAction = (name, context = {}) => ({
  action_name: name,
  action_params: DEFAULT_PARAMS[name](context),
});

export const isOfficialWhatsApp = inbox =>
  inbox?.channel_type === 'Channel::Whatsapp';

export const toMinutes = (value, unit) => {
  const factor = DELAY_UNITS.find(u => u.value === unit)?.minutes || 1;
  return Math.max(0, Math.round(Number(value) || 0)) * factor;
};

// Largest unit that divides the minutes evenly, so 120 reads as "2 horas".
export const splitMinutes = minutes => {
  const total = Number(minutes) || 0;
  const unit =
    [...DELAY_UNITS]
      .reverse()
      .find(u => total > 0 && total % u.minutes === 0) || DELAY_UNITS[0];
  return { value: total / unit.minutes, unit: unit.value };
};

export const formatDelay = (minutes, t) => {
  const { value, unit } = splitMinutes(minutes);
  return t(
    `CRM_AUTOMATIONS.SUMMARY.${unit.toUpperCase()}`,
    { count: value },
    value
  );
};

// "Imediato ao entrar" / "Após 5 min na etapa" / "Inatividade 1h (cliente não respondeu)".
export const triggerSummary = (automation, t) => {
  const time = formatDelay(automation.delay_minutes, t);
  if (automation.trigger_type === 'time_in_stage') {
    return t('CRM_AUTOMATIONS.SUMMARY.TIME_IN_STAGE', { time });
  }
  if (automation.trigger_type === 'inactivity') {
    return t('CRM_AUTOMATIONS.SUMMARY.INACTIVITY', {
      time,
      sender: t(
        `CRM_AUTOMATIONS.SUMMARY.SENDERS.${automation.inactivity_sender}`
      ),
    });
  }
  return t('CRM_AUTOMATIONS.SUMMARY.STAGE_ENTERED');
};

const isHttpUrl = url => /^https?:\/\/\S+$/i.test(String(url || '').trim());

const templateError = template => {
  if (!template?.name) return 'TEMPLATE';
  const values = Object.values(template.processed_params?.body || {});
  return values.every(value => !isBlank(value)) ? '' : 'TEMPLATE_PARAMS';
};

const conditionError = condition => {
  if (!condition.attribute) return 'ATTRIBUTE';
  if (condition.attribute === 'custom_attribute' && !condition.attribute_key) {
    return 'ATTRIBUTE_KEY';
  }
  if (
    !VALUELESS_OPERATORS.includes(condition.operator) &&
    isBlank(condition.value)
  ) {
    return 'VALUE';
  }
  return '';
};

const actionError = (action, inboxes) => {
  const params = action.action_params || {};
  switch (action.action_name) {
    case 'send_message':
    case 'add_private_note':
      return isBlank(params.content) ? 'CONTENT' : '';
    case 'send_template':
      return params.inbox_id ? templateError(params.template) : 'INBOX';
    case 'send_webhook':
      return isHttpUrl(params.url) ? '' : 'URL';
    case 'create_conversation': {
      const inbox = inboxes.find(i => i.id === Number(params.inbox_id));
      if (!inbox) return 'INBOX';
      if (isOfficialWhatsApp(inbox)) return templateError(params.template);
      return isBlank(params.content) ? 'CONTENT' : '';
    }
    case 'add_label':
    case 'remove_label':
      return params.labels?.length ? '' : 'LABELS';
    case 'add_sla':
      return Number(params.minutes) > 0 ? '' : 'MINUTES';
    case 'change_status':
      return params.status ? '' : 'STATUS';
    default:
      return '';
  }
};

// Error keys (translated by the components) indexed like the draft; `any` tells if saving is blocked.
export const validateConditions = conditions =>
  conditions.reduce((errors, condition, index) => {
    const key = conditionError(condition);
    if (key) errors[index] = key;
    return errors;
  }, {});

export const validateAutomation = (draft, inboxes) => {
  const errors = {
    name: isBlank(draft.name) ? 'NAME' : '',
    trigger:
      draft.trigger_type !== 'stage_entered' && !(draft.delay_minutes > 0)
        ? 'DELAY'
        : '',
    conditions: validateConditions(draft.conditions),
    actionsList: draft.actions.length ? '' : 'ACTIONS',
    actions: {},
  };
  draft.actions.forEach((action, index) => {
    const key = actionError(action, inboxes);
    if (key) errors.actions[index] = key;
  });
  errors.any = Boolean(
    errors.name ||
      errors.trigger ||
      errors.actionsList ||
      Object.keys(errors.conditions).length ||
      Object.keys(errors.actions).length
  );
  return errors;
};

const conditionPayload = condition => {
  const payload = {
    attribute: condition.attribute,
    operator: condition.operator,
  };
  if (condition.attribute === 'custom_attribute') {
    payload.attribute_key = condition.attribute_key;
  }
  if (!VALUELESS_OPERATORS.includes(condition.operator)) {
    payload.value = condition.value;
  }
  return payload;
};

// `active` only goes on create: the list checkbox is the single place that toggles it afterwards.
export const toPayload = draft => {
  const payload = {
    resolution_state_id: draft.resolution_state_id,
    name: draft.name.trim(),
    trigger_type: draft.trigger_type,
    delay_minutes:
      draft.trigger_type === 'stage_entered' ? 0 : draft.delay_minutes,
    inactivity_sender:
      draft.trigger_type === 'inactivity' ? draft.inactivity_sender : 'any',
    match_type: draft.match_type,
    conditions: draft.conditions.map(conditionPayload),
    actions: draft.actions.map(({ action_name, action_params }) => ({
      action_name,
      action_params,
    })),
    sort_order: draft.sort_order || 0,
  };
  if (!draft.id) payload.active = true;
  return payload;
};
