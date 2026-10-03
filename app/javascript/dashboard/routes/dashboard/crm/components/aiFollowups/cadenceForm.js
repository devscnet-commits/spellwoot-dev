// Form state of a stage cadence (PipelineAiFollowup) and its (de)serialization. The form always
// holds one behavior per schedule context so the pills map 1:1; only contexts with attempts are
// saved. Delays are edited as value + unit and stored in minutes.

let uidCounter = 0;
export const nextUid = () => {
  uidCounter += 1;
  return uidCounter;
};

export const CONTEXTS = ['inbox_hours', 'outside_hours', 'custom'];
export const SENDERS = ['contact', 'agent', 'any'];
export const NO_RESPONSE_ACTIONS = [
  'assign',
  'finalize',
  'discard',
  'wait',
  'wait_business_hours',
  'move_stage',
];
export const UNITS = [
  { value: 'minutes', minutes: 1 },
  { value: 'hours', minutes: 60 },
  { value: 'days', minutes: 1440 },
];

// 90 -> 90 minutes, 120 -> 2 hours, 2880 -> 2 days (largest unit that divides exactly).
export const minutesToDelay = minutes => {
  const total = Number(minutes) || 0;
  const unit =
    [...UNITS].reverse().find(u => total > 0 && total % u.minutes === 0) ||
    UNITS[0];
  return { delay_value: total / unit.minutes, delay_unit: unit.value };
};

export const delayToMinutes = ({ delay_value, delay_unit }) => {
  const unit = UNITS.find(u => u.value === delay_unit) || UNITS[0];
  return Math.round((Number(delay_value) || 0) * unit.minutes);
};

export const blankWindow = () => ({ uid: nextUid(), start: '', end: '' });

export const blankAttempt = (overrides = {}) => ({
  uid: nextUid(),
  name: '',
  active: true,
  delay_value: 15,
  delay_unit: 'minutes',
  inactivity_sender: 'contact',
  ai_agent_id: '',
  prompt: '',
  ...overrides,
});

export const blankBehavior = context => ({
  uid: nextUid(),
  context,
  windows: context === 'custom' ? [blankWindow()] : [],
  attempts: [],
  no_response_action: 'assign',
  no_response_stage_id: '',
});

const hydrateAttempt = attempt => ({
  uid: nextUid(),
  name: attempt.name || '',
  active: attempt.active !== false,
  ...minutesToDelay(attempt.delay_minutes),
  inactivity_sender: attempt.inactivity_sender || 'contact',
  ai_agent_id: attempt.ai_agent_id || '',
  prompt: attempt.prompt || '',
});

const hydrateBehavior = behavior => ({
  ...blankBehavior(behavior.context),
  windows: (behavior.windows || []).map(window => ({
    uid: nextUid(),
    start: window.start || '',
    end: window.end || '',
  })),
  attempts: (behavior.attempts || []).map(hydrateAttempt),
  no_response_action: behavior.no_response_action || 'assign',
  no_response_stage_id: behavior.no_response_stage_id || '',
});

export const hydrateCadence = cadence => {
  const saved = (cadence?.behaviors || []).map(hydrateBehavior);
  return {
    id: cadence?.id || null,
    active: cadence ? cadence.active !== false : true,
    inactivity_minutes: cadence?.inactivity_minutes ?? 30,
    close_message: cadence?.close_message || '',
    behaviors: CONTEXTS.map(
      context =>
        saved.find(behavior => behavior.context === context) ||
        blankBehavior(context)
    ),
  };
};

export const cadencePayload = (form, stageId) => ({
  resolution_state_id: stageId,
  active: form.active,
  inactivity_minutes: Number(form.inactivity_minutes) || 0,
  close_message: form.close_message,
  behaviors: form.behaviors
    .filter(behavior => behavior.attempts.length)
    .map(behavior => ({
      context: behavior.context,
      windows:
        behavior.context === 'custom'
          ? behavior.windows.map(({ start, end }) => ({ start, end }))
          : [],
      attempts: behavior.attempts.map(attempt => ({
        name: attempt.name,
        active: attempt.active,
        delay_minutes: delayToMinutes(attempt),
        inactivity_sender: attempt.inactivity_sender,
        ai_agent_id: attempt.ai_agent_id,
        prompt: attempt.prompt,
      })),
      no_response_action: behavior.no_response_action,
      no_response_stage_id:
        behavior.no_response_action === 'move_stage'
          ? behavior.no_response_stage_id
          : null,
    })),
});

// Attempts that will actually fire: the "N follow-ups" badge of a stage.
export const activeAttemptsCount = behaviors =>
  (behaviors || []).reduce(
    (sum, behavior) =>
      sum +
      (behavior.attempts || []).filter(attempt => attempt.active !== false)
        .length,
    0
  );
