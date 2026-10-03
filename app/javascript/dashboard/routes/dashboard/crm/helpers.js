import { conditionOperatorMatches } from 'dashboard/components-next/ConversationWorkflow/constants';

// Shared bits of the CRM kanban pages: stage colors, money/duration formatting, lead temperature
// and the stage requirement rules (mirror of ClosingRequirement#applies_to? on the backend).

export const STAGE_COLORS = [
  'blue',
  'violet',
  'amber',
  'iris',
  'teal',
  'ruby',
  'slate',
];

// Full class names so Tailwind keeps them.
export const STAGE_DOT_CLASS = {
  blue: 'bg-n-blue-9',
  violet: 'bg-n-violet-9',
  amber: 'bg-n-amber-9',
  iris: 'bg-n-iris-9',
  teal: 'bg-n-teal-9',
  ruby: 'bg-n-ruby-9',
  slate: 'bg-n-slate-9',
};

export const stageColor = (stage, index = 0) => {
  if (stage?.color) return stage.color;
  if (stage?.polarity === 'positive') return 'teal';
  if (stage?.polarity === 'negative') return 'ruby';
  return STAGE_COLORS[index % 4];
};

export const isOpenStage = stage => stage?.polarity === 'neutral';

export const TEMPERATURES = [
  { value: 'hot', icon: 'i-lucide-flame', textClass: 'text-n-ruby-11' },
  { value: 'warm', icon: 'i-lucide-cloud-sun', textClass: 'text-n-amber-11' },
  { value: 'cold', icon: 'i-lucide-snowflake', textClass: 'text-n-blue-11' },
];

export const temperatureOf = value => TEMPERATURES.find(t => t.value === value);

const moneyFormat = new Intl.NumberFormat('pt-BR', {
  style: 'currency',
  currency: 'BRL',
});

export const formatMoney = value => moneyFormat.format(Number(value) || 0);

// Compact duration: 45m, 26h, 3d.
export const formatDuration = seconds => {
  const minutes = Math.max(0, Math.round(seconds / 60));
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 72) return `${hours}h`;
  return `${Math.floor(hours / 24)}d`;
};

export const isBlank = value =>
  value === undefined || value === null || String(value).trim() === '';

// A closing state applies only to itself; an open stage means "from this stage onward": the later
// open stages and both closing columns (won and lost).
export const requirementAppliesToStage = (requirement, stage, stages) => {
  const condition = requirement?.condition || {};
  const when = condition.when;
  if (condition.always || !when) return true;
  if ('polarity' in when) return stage?.polarity === when.polarity;
  if (!('canonical_key' in when)) return true;
  const reference = stages.find(s => s.canonical_key === when.canonical_key);
  if (!isOpenStage(reference))
    return stage?.canonical_key === when.canonical_key;
  if (!stage) return false;
  return !isOpenStage(stage) || stage.sort_order >= reference.sort_order;
};

// "Obrigatório SE atributo <operador> valor" (same operators as the backend).
export const requirementConditionMet = (requirement, values) => {
  const clause = requirement?.condition?.if;
  if (!clause) return true;
  if (!clause.attribute_key) return false;
  const expected =
    clause.values ?? (clause.value != null ? [clause.value] : []);
  return conditionOperatorMatches(
    clause.operator || 'equal_to',
    values?.[clause.attribute_key],
    expected
  );
};
