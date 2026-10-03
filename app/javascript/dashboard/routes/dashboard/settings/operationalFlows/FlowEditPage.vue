<script setup>
import { computed, onMounted, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';

import Switch from 'dashboard/components-next/switch/Switch.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import FlowSelect from './FlowSelect.vue';
import { CONDITION_OPERATORS } from 'dashboard/components-next/ConversationWorkflow/constants';
import {
  STAGE_COLORS,
  STAGE_DOT_CLASS,
  stageColor,
} from 'dashboard/routes/dashboard/crm/helpers';

const store = useStore();
const route = useRoute();
const router = useRouter();
const { t } = useI18n();

const getFlow = useMapGetter('operationalFlows/getFlow');
const uiFlags = useMapGetter('operationalFlows/getUIFlags');
const conversationAttributes = useMapGetter(
  'attributes/getConversationAttributes'
);
const flowId = computed(() =>
  route.params.flowId ? Number(route.params.flowId) : null
);
const isEdit = computed(() => !!flowId.value);

const CATEGORIES = ['sales', 'support'];
// Polarity is fixed per canonical state (won=positive, lost=negative) — not user-editable,
// so reports can never be inverted by a mislabelled state. The badge shows the polarity
// (Positivo/Negativo) instead of the raw won/lost key kept in the backend.
const POLARITY_BY_CANONICAL = { won: 'positive', lost: 'negative' };
const statePolarity = state =>
  POLARITY_BY_CANONICAL[state.canonical_key] || state.polarity || 'neutral';
const isOpenStage = state => statePolarity(state) === 'neutral';
const POLARITY_BADGE_CLASS = {
  positive: 'text-n-teal-11 bg-n-teal-3',
  negative: 'text-n-ruby-11 bg-n-ruby-3',
  neutral: 'text-n-slate-11 bg-n-alpha-2',
};
// Standard Meta Conversions API event names a state can fire ('' = do not send).
// `value` is only sent for Purchase. Full standard catalog so any funnel can be mapped.
const META_EVENTS = [
  '',
  'Purchase',
  'Lead',
  'CompleteRegistration',
  'Contact',
  'Schedule',
  'SubmitApplication',
  'StartTrial',
  'Subscribe',
  'InitiateCheckout',
  'AddPaymentInfo',
  'AddToCart',
  'AddToWishlist',
  'ViewContent',
  'Search',
  'FindLocation',
  'CustomizeProduct',
  'Donate',
];

// Canonical Meta event names with a translated description; the canonical name is what gets sent.
const metaEventOptions = computed(() => [
  { value: '', label: t('OPERATIONAL_FLOWS_SETTINGS.FORM.STATES.META_NONE') },
  ...META_EVENTS.filter(Boolean).map(event => ({
    value: event,
    label: `${event} — ${t(`OPERATIONAL_FLOWS_SETTINGS.FORM.STATES.META_EVENT_DESC.${event}`)}`,
  })),
]);

// Deal / Purchase value must be numeric-ish: number and currency attributes, plus text for
// legacy "R$ 1.234,56" fields (the backend parses that format).
const valueAttributeOptions = computed(() =>
  (conversationAttributes.value || [])
    .filter(attribute =>
      ['number', 'currency', 'text'].includes(attribute.attributeDisplayType)
    )
    .map(attribute => ({
      value: attribute.attributeKey,
      label: attribute.attributeDisplayName,
    }))
);

// Every conversation attribute, with the bits the "if" clause editor needs (type + list options).
const attributeOptions = computed(() =>
  (conversationAttributes.value || []).map(attribute => ({
    value: attribute.attributeKey,
    label: attribute.attributeDisplayName,
    type: attribute.attributeDisplayType,
    attributeValues: attribute.attributeValues || [],
  }))
);

// Each state mirrors a closing button: canonical_key is immutable, display_label is free text.
const defaultStates = () => [
  {
    canonical_key: 'won',
    display_label: 'Ganho',
    polarity: 'positive',
    meta_event_type: '',
    meta_value_attr: '',
  },
  {
    canonical_key: 'lost',
    display_label: 'Perdido',
    polarity: 'negative',
    meta_event_type: '',
    meta_value_attr: '',
  },
];

const name = ref('');
const category = ref('sales');
const active = ref(true);
const metaEnabled = ref(false);
const valueAttributeKey = ref('');
// Open kanban stages (polarity neutral) in board order; exactly one is the entry stage.
const stages = ref([]);
const removedStageIds = ref([]);
// Closing states (won/lost), always after the open stages.
const states = ref(defaultStates());
const removedReasonIds = ref([]);
const requirements = ref([]);
const removedRequirementIds = ref([]);
const isSaving = ref(false);
const isLoading = ref(false);

// ---- Pipeline stages -----------------------------------------------------------------------

const KEY_SUFFIX_CHARS = 'abcdefghijklmnopqrstuvwxyz0123456789';
// canonical_key is immutable server-side, so a new stage gets it once from the label it was
// created with: ascii slug + random suffix (two stages may share a name, keys never collide).
const canonicalKeyFor = label => {
  const slug = label
    .normalize('NFD')
    .replace(/\p{Diacritic}/gu, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '');
  const suffix = Array.from(
    { length: 4 },
    () => KEY_SUFFIX_CHARS[Math.floor(Math.random() * KEY_SUFFIX_CHARS.length)]
  ).join('');
  return `${slug || 'etapa'}_${suffix}`;
};

const addStage = () => {
  stages.value.push({
    canonical_key: '',
    display_label: '',
    color: STAGE_COLORS[stages.value.length % STAGE_COLORS.length],
    is_default: stages.value.length === 0,
  });
};

// The key is fixed when the user leaves the label field for the first time; renaming later
// changes only display_label, exactly like the won/lost states.
const ensureStageKey = stage => {
  if (!stage.canonical_key && stage.display_label.trim()) {
    stage.canonical_key = canonicalKeyFor(stage.display_label);
  }
};

const setDefaultStage = index => {
  stages.value.forEach((stage, i) => {
    stage.is_default = i === index;
  });
};

const moveStage = (index, delta) => {
  const target = index + delta;
  if (target < 0 || target >= stages.value.length) return;
  const list = stages.value;
  [list[index], list[target]] = [list[target], list[index]];
};

const removeStage = index => {
  const [removed] = stages.value.splice(index, 1);
  if (removed.id) removedStageIds.value.push(removed.id);
  if (removed.is_default && stages.value.length) {
    stages.value[0].is_default = true;
  }
  // Requirements anchored on the removed stage fall back to "always".
  requirements.value.forEach(requirement => {
    if (requirement.when === removed.canonical_key) requirement.when = 'always';
  });
};

// ---- Requirements ---------------------------------------------------------------------------

const OPERATORS_WITHOUT_VALUE = ['is_present', 'is_not_present'];

// A requirement's `when` is 'always' or a state's canonical_key (open stage = from that stage
// onward, closing state = that state only). Old rows with only an `if` clause are "always".
const conditionToWhen = condition => {
  if (condition?.always) return 'always';
  return condition?.when?.canonical_key || 'always';
};

const triggerAttributeFor = key =>
  attributeOptions.value.find(option => option.value === key);

// Equal/not equal on a list attribute picks among its options; everything else types a value.
const usesOptionList = requirement =>
  triggerAttributeFor(requirement.condition_field)?.type === 'list' &&
  ['equal_to', 'not_equal_to'].includes(requirement.condition_operator);

const needsValue = requirement =>
  !OPERATORS_WITHOUT_VALUE.includes(requirement.condition_operator);

const conditionValuesOf = requirement => {
  if (!needsValue(requirement)) return [];
  if (usesOptionList(requirement)) return requirement.condition_values;
  const value = String(requirement.condition_values[0] ?? '').trim();
  return value ? [value] : [];
};

const buildCondition = requirement => {
  const condition =
    requirement.when === 'always'
      ? { always: true }
      : { when: { canonical_key: requirement.when } };
  if (requirement.has_condition && requirement.condition_field) {
    condition.if = {
      attribute_key: requirement.condition_field,
      operator: requirement.condition_operator,
      values: conditionValuesOf(requirement),
    };
  }
  return condition;
};

// "Obrigatório quando": always, from each open stage onward, or one closing state only.
const conditionOptions = computed(() => [
  {
    value: 'always',
    label: t('OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIREMENTS.ALWAYS'),
  },
  ...stages.value
    .filter(stage => stage.canonical_key)
    .map(stage => ({
      value: stage.canonical_key,
      label: t('OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIREMENTS.FROM_STAGE', {
        stage: stage.display_label,
      }),
    })),
  ...states.value.map(state => ({
    value: state.canonical_key,
    label: t('OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIREMENTS.WHEN_STATE', {
      state: state.display_label,
    }),
  })),
]);

const operatorOptions = computed(() =>
  CONDITION_OPERATORS.map(operator => ({
    value: operator,
    label: t(
      `OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIREMENTS.OPERATORS.${operator}`
    ),
  }))
);

const triggerValuesFor = key => triggerAttributeFor(key)?.attributeValues || [];

// Changing the trigger attribute invalidates the previously selected answers.
const onTriggerFieldChange = requirement => {
  requirement.condition_values = [];
};

// Switching between "pick options" and "type a value" leaves stale values behind; clear them.
const setOperator = (requirement, operator) => {
  const wasOptionList = usesOptionList(requirement);
  requirement.condition_operator = operator;
  if (usesOptionList(requirement) !== wasOptionList) {
    requirement.condition_values = [];
  }
};

const populate = flow => {
  if (!flow) return;
  name.value = flow.name || '';
  category.value = flow.category || 'sales';
  active.value = flow.active ?? true;
  metaEnabled.value = !!flow.meta_enabled;
  valueAttributeKey.value = flow.value_attribute_key || '';

  // Motivos (reasons) were removed from the editor; purge any leftovers on save so
  // old flows stop demanding a reason at closing time.
  removedReasonIds.value = (flow.reasons || []).map(r => r.id).filter(Boolean);

  const apiStates = (flow.resolution_states || [])
    .slice()
    .sort((a, b) => a.sort_order - b.sort_order);
  stages.value = apiStates.filter(isOpenStage).map((s, index) => ({
    id: s.id,
    canonical_key: s.canonical_key,
    display_label: s.display_label,
    color: stageColor(s, index),
    is_default: !!s.is_default,
  }));
  const closingStates = apiStates.filter(s => !isOpenStage(s));
  states.value = (closingStates.length ? closingStates : defaultStates()).map(
    s => ({
      id: s.id,
      canonical_key: s.canonical_key,
      display_label: s.display_label,
      polarity: s.polarity || 'neutral',
      meta_event_type: s.meta_event_type || '',
      meta_value_attr: s.meta_value_attr || '',
    })
  );

  requirements.value = (flow.closing_requirements || [])
    .slice()
    .sort((a, b) => a.sort_order - b.sort_order)
    .map(r => {
      const clause = r.condition?.if;
      // Rows saved before operators existed are "equal to"; a single legacy `value` becomes values[].
      const values =
        clause?.values || (clause?.value != null ? [clause.value] : []);
      return {
        id: r.id,
        attribute_key: r.attribute_key,
        when: conditionToWhen(r.condition),
        has_condition: !!clause?.attribute_key,
        condition_field: clause?.attribute_key || '',
        condition_operator: clause?.operator || 'equal_to',
        condition_values: values.map(String),
      };
    });
};

onMounted(async () => {
  store.dispatch('attributes/get');
  if (!isEdit.value) return;
  isLoading.value = true;
  try {
    await store.dispatch('operationalFlows/show', flowId.value);
    populate(getFlow.value(flowId.value));
  } finally {
    isLoading.value = false;
  }
});

// Kanban order: open stages first (list order), then the won and the lost columns.
const buildStatesAttributes = () => {
  const rows = [
    ...stages.value.map(stage => ({
      ...(stage.id ? { id: stage.id } : {}),
      canonical_key:
        stage.canonical_key || canonicalKeyFor(stage.display_label),
      display_label: stage.display_label.trim(),
      polarity: 'neutral',
      color: stage.color,
      is_default: stage.is_default,
      requires_reason: false,
      meta_event_type: null,
      meta_value_attr: null,
    })),
    ...states.value.map(state => ({
      ...(state.id ? { id: state.id } : {}),
      canonical_key: state.canonical_key,
      display_label: state.display_label.trim(),
      polarity:
        POLARITY_BY_CANONICAL[state.canonical_key] ||
        state.polarity ||
        'neutral',
      is_default: false,
      requires_reason: false,
      meta_event_type: state.meta_event_type || null,
      meta_value_attr: state.meta_value_attr || null,
    })),
  ].map((state, sortOrder) => ({ ...state, sort_order: sortOrder }));
  removedStageIds.value.forEach(id => rows.push({ id, _destroy: true }));
  return rows;
};

const buildReasonsAttributes = () =>
  removedReasonIds.value.map(id => ({ id, _destroy: true }));

const addRequirement = () => {
  requirements.value.push({
    attribute_key: '',
    when: 'always',
    has_condition: false,
    condition_field: '',
    condition_operator: 'equal_to',
    condition_values: [],
  });
};

const removeRequirement = index => {
  const [removed] = requirements.value.splice(index, 1);
  if (removed?.id) removedRequirementIds.value.push(removed.id);
};

// A Purchase needs its value at closing time: when a state sends Purchase with a value attribute,
// make that attribute a closing requirement for the state so the agent is asked when resolving.
const withValueRequirements = rows => {
  const present = new Set(
    // _destroy é a chave de nested attributes do Rails, não um nome nosso para renomear.
    // eslint-disable-next-line no-underscore-dangle
    rows.filter(r => !r._destroy).map(r => r.attribute_key)
  );
  states.value.forEach(state => {
    if (state.meta_event_type !== 'Purchase' || !state.meta_value_attr) return;
    if (present.has(state.meta_value_attr)) return;
    rows.push({
      attribute_key: state.meta_value_attr,
      condition: { when: { canonical_key: state.canonical_key } },
      sort_order: rows.length,
    });
    present.add(state.meta_value_attr);
  });
  return rows;
};

const buildRequirementsAttributes = () => {
  const rows = [];
  requirements.value.forEach((requirement, sortOrder) => {
    if (!requirement.attribute_key) return;
    rows.push({
      ...(requirement.id ? { id: requirement.id } : {}),
      attribute_key: requirement.attribute_key,
      condition: buildCondition(requirement),
      sort_order: sortOrder,
    });
  });
  removedRequirementIds.value.forEach(id => rows.push({ id, _destroy: true }));
  return withValueRequirements(rows);
};

const isValid = computed(
  () =>
    name.value.trim() &&
    [...stages.value, ...states.value].every(s => s.display_label.trim().length)
);

const save = async () => {
  if (!isValid.value) return;
  isSaving.value = true;
  const payload = {
    name: name.value.trim(),
    category: category.value,
    require_reason: false,
    active: active.value,
    meta_enabled: metaEnabled.value,
    value_attribute_key: valueAttributeKey.value || null,
    resolution_states_attributes: buildStatesAttributes(),
    reasons_attributes: buildReasonsAttributes(),
    closing_requirements_attributes: buildRequirementsAttributes(),
  };
  try {
    if (isEdit.value) {
      await store.dispatch('operationalFlows/update', {
        id: flowId.value,
        ...payload,
      });
      useAlert(t('OPERATIONAL_FLOWS_SETTINGS.FORM.UPDATE_SUCCESS'));
    } else {
      await store.dispatch('operationalFlows/create', payload);
      useAlert(t('OPERATIONAL_FLOWS_SETTINGS.FORM.CREATE_SUCCESS'));
    }
    router.push({ name: 'conversation_workflow_index' });
  } catch (error) {
    useAlert(t('OPERATIONAL_FLOWS_SETTINGS.FORM.ERROR_MESSAGE'));
  } finally {
    isSaving.value = false;
  }
};
</script>

<template>
  <div class="p-6 col-span-full w-full max-w-5xl mx-auto flex flex-col gap-6">
    <div v-if="isLoading" class="flex justify-center py-8">
      <Spinner class="text-n-brand" />
    </div>
    <template v-else>
      <div class="flex flex-col gap-1">
        <h1 class="text-heading-1 text-n-slate-12">
          {{
            isEdit
              ? $t('OPERATIONAL_FLOWS_SETTINGS.FORM.EDIT_TITLE')
              : $t('OPERATIONAL_FLOWS_SETTINGS.FORM.NEW_TITLE')
          }}
        </h1>
        <p class="text-body-main text-n-slate-11">
          {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.SUBTITLE') }}
        </p>
      </div>

      <div class="flex flex-col gap-1">
        <label class="text-sm font-medium text-n-slate-12">
          {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.NAME.LABEL') }}
        </label>
        <input
          v-model="name"
          type="text"
          :placeholder="$t('OPERATIONAL_FLOWS_SETTINGS.FORM.NAME.PLACEHOLDER')"
          class="w-full px-3 py-2.5 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
        />
      </div>

      <div class="flex flex-col gap-1">
        <label class="text-sm font-medium text-n-slate-12">
          {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.CATEGORY.LABEL') }}
        </label>
        <p class="text-sm text-n-slate-11">
          {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.CATEGORY.HELP') }}
        </p>
        <FlowSelect v-model="category">
          <option v-for="option in CATEGORIES" :key="option" :value="option">
            {{
              $t(`OPERATIONAL_FLOWS_SETTINGS.FORM.CATEGORY.OPTIONS.${option}`)
            }}
          </option>
        </FlowSelect>
      </div>

      <div
        class="flex items-center justify-between py-2 px-3 rounded-lg bg-n-alpha-2"
      >
        <span class="text-sm font-medium text-n-slate-12">
          {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.ACTIVE.LABEL') }}
        </span>
        <Switch v-model="active" />
      </div>

      <div
        class="flex items-center justify-between py-2 px-3 rounded-lg bg-n-alpha-2"
      >
        <div class="flex flex-col">
          <span class="text-sm font-medium text-n-slate-12">
            {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.META.LABEL') }}
          </span>
          <span class="text-sm text-n-slate-11">
            {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.META.HELP') }}
          </span>
        </div>
        <Switch v-model="metaEnabled" />
      </div>

      <!-- Open pipeline stages: the kanban columns before Ganho/Perdido -->
      <div class="flex flex-col gap-3">
        <div class="flex flex-col gap-1">
          <h3 class="text-lg font-medium text-n-slate-12">
            {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.PIPELINE.LABEL') }}
          </h3>
          <p class="text-sm text-n-slate-11">
            {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.PIPELINE.HELP') }}
          </p>
        </div>

        <p
          v-if="!stages.length"
          class="text-sm text-n-slate-11 rounded-lg border border-dashed border-n-weak p-3"
        >
          {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.PIPELINE.EMPTY') }}
        </p>

        <div
          v-for="(stage, index) in stages"
          :key="stage.id || stage.canonical_key || `new-${index}`"
          class="flex flex-col gap-3 border border-n-weak rounded-xl p-4"
        >
          <div class="flex items-end gap-2">
            <div class="flex flex-col">
              <Button
                ghost
                slate
                xs
                icon="i-lucide-chevron-up"
                :disabled="index === 0"
                :title="$t('OPERATIONAL_FLOWS_SETTINGS.FORM.PIPELINE.MOVE_UP')"
                @click="moveStage(index, -1)"
              />
              <Button
                ghost
                slate
                xs
                icon="i-lucide-chevron-down"
                :disabled="index === stages.length - 1"
                :title="
                  $t('OPERATIONAL_FLOWS_SETTINGS.FORM.PIPELINE.MOVE_DOWN')
                "
                @click="moveStage(index, 1)"
              />
            </div>
            <div class="flex flex-col gap-1 flex-1">
              <label class="text-sm font-medium text-n-slate-11">
                {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.PIPELINE.STAGE_LABEL') }}
              </label>
              <div class="flex items-center gap-2">
                <span
                  class="size-3 rounded-full shrink-0"
                  :class="STAGE_DOT_CLASS[stage.color]"
                />
                <input
                  v-model="stage.display_label"
                  type="text"
                  :placeholder="
                    $t(
                      'OPERATIONAL_FLOWS_SETTINGS.FORM.PIPELINE.STAGE_PLACEHOLDER'
                    )
                  "
                  class="w-full px-3 py-2.5 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
                  @blur="ensureStageKey(stage)"
                />
              </div>
            </div>
            <Button
              icon="i-woot-bin"
              slate
              sm
              class="hover:enabled:text-n-ruby-11 hover:enabled:bg-n-ruby-2"
              :title="$t('OPERATIONAL_FLOWS_SETTINGS.FORM.PIPELINE.REMOVE')"
              @click="removeStage(index)"
            />
          </div>

          <div
            class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between"
          >
            <div class="flex items-center gap-2">
              <span class="text-sm font-medium text-n-slate-11">
                {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.PIPELINE.COLOR') }}
              </span>
              <button
                v-for="color in STAGE_COLORS"
                :key="color"
                type="button"
                class="size-5 rounded-full ring-offset-2 ring-offset-n-background transition-opacity"
                :class="[
                  STAGE_DOT_CLASS[color],
                  stage.color === color
                    ? 'ring-2 ring-n-slate-12'
                    : 'opacity-50 hover:opacity-100',
                ]"
                :title="
                  $t(`OPERATIONAL_FLOWS_SETTINGS.FORM.PIPELINE.COLORS.${color}`)
                "
                @click="stage.color = color"
              />
            </div>
            <label
              class="flex items-center gap-2 text-sm text-n-slate-12 cursor-pointer"
              :title="
                $t('OPERATIONAL_FLOWS_SETTINGS.FORM.PIPELINE.DEFAULT_HELP')
              "
            >
              <input
                type="radio"
                name="default-stage"
                class="m-0"
                :checked="stage.is_default"
                @change="setDefaultStage(index)"
              />
              {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.PIPELINE.DEFAULT') }}
            </label>
          </div>
        </div>

        <p v-if="stages.length" class="text-sm text-n-slate-11">
          {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.PIPELINE.REMOVE_HINT') }}
        </p>
        <Button
          faded
          slate
          size="sm"
          icon="i-lucide-plus"
          :label="$t('OPERATIONAL_FLOWS_SETTINGS.FORM.PIPELINE.ADD')"
          @click="addStage"
        />

        <div class="flex flex-col gap-1 mt-2">
          <label class="text-sm font-medium text-n-slate-12">
            {{
              $t(
                'OPERATIONAL_FLOWS_SETTINGS.FORM.PIPELINE.VALUE_ATTRIBUTE.LABEL'
              )
            }}
          </label>
          <p class="text-sm text-n-slate-11">
            {{
              $t(
                'OPERATIONAL_FLOWS_SETTINGS.FORM.PIPELINE.VALUE_ATTRIBUTE.HELP'
              )
            }}
          </p>
          <FlowSelect v-model="valueAttributeKey">
            <option value="">
              {{
                $t(
                  'OPERATIONAL_FLOWS_SETTINGS.FORM.PIPELINE.VALUE_ATTRIBUTE.NONE'
                )
              }}
            </option>
            <option
              v-for="option in valueAttributeOptions"
              :key="option.value"
              :value="option.value"
            >
              {{ option.label }}
            </option>
          </FlowSelect>
        </div>
      </div>

      <div class="flex flex-col gap-3">
        <h3 class="text-lg font-medium text-n-slate-12">
          {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.STATES.LABEL') }}
        </h3>

        <div
          v-for="state in states"
          :key="state.canonical_key"
          class="flex flex-col gap-3 border border-n-weak rounded-xl p-4"
        >
          <div class="flex items-center gap-2">
            <span
              class="px-1.5 py-0.5 text-xs font-medium rounded"
              :class="POLARITY_BADGE_CLASS[statePolarity(state)]"
            >
              {{
                $t(
                  `OPERATIONAL_FLOWS_SETTINGS.FORM.STATES.POLARITY_OPTIONS.${statePolarity(
                    state
                  )}`
                )
              }}
            </span>
          </div>

          <div class="flex flex-col gap-1">
            <label class="text-sm font-medium text-n-slate-11">
              {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.STATES.DISPLAY_LABEL') }}
            </label>
            <input
              v-model="state.display_label"
              type="text"
              class="w-full px-3 py-2.5 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
            />
          </div>

          <div
            v-if="metaEnabled"
            class="flex flex-col gap-3 border-t border-n-weak pt-3"
          >
            <div class="flex flex-col gap-3 sm:flex-row">
              <div class="flex flex-col gap-1 flex-1">
                <label class="text-sm font-medium text-n-slate-11">
                  {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.STATES.META_EVENT') }}
                </label>
                <FlowSelect v-model="state.meta_event_type">
                  <option
                    v-for="option in metaEventOptions"
                    :key="option.value"
                    :value="option.value"
                  >
                    {{ option.label }}
                  </option>
                </FlowSelect>
              </div>
              <div
                v-if="state.meta_event_type === 'Purchase'"
                class="flex flex-col gap-1 flex-1"
              >
                <label class="text-sm font-medium text-n-slate-11">
                  {{
                    $t('OPERATIONAL_FLOWS_SETTINGS.FORM.STATES.META_VALUE_ATTR')
                  }}
                </label>
                <FlowSelect v-model="state.meta_value_attr">
                  <option value="">
                    {{
                      $t('OPERATIONAL_FLOWS_SETTINGS.FORM.STATES.META_NO_VALUE')
                    }}
                  </option>
                  <option
                    v-for="option in valueAttributeOptions"
                    :key="option.value"
                    :value="option.value"
                  >
                    {{ option.label }}
                  </option>
                </FlowSelect>
              </div>
            </div>
            <p
              v-if="
                state.meta_event_type === 'Purchase' && !state.meta_value_attr
              "
              class="text-sm text-n-amber-11"
            >
              {{
                $t(
                  'OPERATIONAL_FLOWS_SETTINGS.FORM.STATES.META_NEED_VALUE_ATTR'
                )
              }}
            </p>
            <p
              v-else-if="state.meta_event_type === 'Purchase'"
              class="text-sm text-n-slate-11"
            >
              {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.STATES.META_VALUE_HELP') }}
            </p>
          </div>
        </div>
      </div>

      <div class="flex flex-col gap-3">
        <div class="flex flex-col gap-1">
          <h3 class="text-lg font-medium text-n-slate-12">
            {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIREMENTS.LABEL') }}
          </h3>
          <p class="text-sm text-n-slate-11">
            {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIREMENTS.HELP') }}
          </p>
        </div>
        <div
          v-for="(requirement, index) in requirements"
          :key="requirement.id || `new-${index}`"
          class="flex flex-col gap-2 border border-n-weak rounded-xl p-4"
        >
          <div class="flex flex-col gap-2 sm:flex-row sm:items-center">
            <FlowSelect v-model="requirement.attribute_key" class="flex-1">
              <option value="" disabled>
                {{
                  $t(
                    'OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIREMENTS.SELECT_ATTRIBUTE'
                  )
                }}
              </option>
              <option
                v-for="option in attributeOptions"
                :key="option.value"
                :value="option.value"
              >
                {{ option.label }}
              </option>
            </FlowSelect>
            <FlowSelect v-model="requirement.when" class="sm:w-64">
              <option
                v-for="option in conditionOptions"
                :key="option.value"
                :value="option.value"
              >
                {{ option.label }}
              </option>
            </FlowSelect>
            <Button
              icon="i-woot-bin"
              slate
              sm
              class="hover:enabled:text-n-ruby-11 hover:enabled:bg-n-ruby-2"
              @click="removeRequirement(index)"
            />
          </div>

          <!-- "Obrigatório se": independent of the stage choice, gates the requirement on another
               attribute's value (trigger attribute + operator + value(s)) -->
          <div class="flex items-center justify-between gap-3 pt-1">
            <div class="flex flex-col">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIREMENTS.IF') }}
              </span>
              <span class="text-sm text-n-slate-11">
                {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIREMENTS.IF_HELP') }}
              </span>
            </div>
            <Switch v-model="requirement.has_condition" />
          </div>

          <div
            v-if="requirement.has_condition"
            class="flex flex-col gap-2 rounded-lg border border-n-weak bg-n-solid-1 p-3"
          >
            <div class="flex flex-col gap-2 sm:flex-row">
              <div class="flex flex-col gap-1 flex-1">
                <label class="text-sm font-medium text-n-slate-11">
                  {{
                    $t('OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIREMENTS.IF_FIELD')
                  }}
                </label>
                <FlowSelect
                  v-model="requirement.condition_field"
                  select-class="bg-n-solid-2"
                  @change="onTriggerFieldChange(requirement)"
                >
                  <option value="" disabled>
                    {{
                      $t(
                        'OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIREMENTS.IF_FIELD_PLACEHOLDER'
                      )
                    }}
                  </option>
                  <option
                    v-for="option in attributeOptions"
                    :key="option.value"
                    :value="option.value"
                  >
                    {{ option.label }}
                  </option>
                </FlowSelect>
              </div>
              <div class="flex flex-col gap-1 sm:w-56">
                <label class="text-sm font-medium text-n-slate-11">
                  {{
                    $t(
                      'OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIREMENTS.IF_OPERATOR'
                    )
                  }}
                </label>
                <FlowSelect
                  :model-value="requirement.condition_operator"
                  select-class="bg-n-solid-2"
                  @update:model-value="setOperator(requirement, $event)"
                >
                  <option
                    v-for="option in operatorOptions"
                    :key="option.value"
                    :value="option.value"
                  >
                    {{ option.label }}
                  </option>
                </FlowSelect>
              </div>
            </div>
            <p v-if="!attributeOptions.length" class="text-sm text-n-amber-11">
              {{
                $t('OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIREMENTS.IF_NO_ATTRS')
              }}
            </p>

            <template
              v-if="requirement.condition_field && needsValue(requirement)"
            >
              <template v-if="usesOptionList(requirement)">
                <label class="text-sm font-medium text-n-slate-11 mt-1">
                  {{
                    $t('OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIREMENTS.IF_VALUES')
                  }}
                </label>
                <div class="flex flex-wrap gap-x-4 gap-y-1.5">
                  <label
                    v-for="value in triggerValuesFor(
                      requirement.condition_field
                    )"
                    :key="value"
                    class="flex items-center gap-1.5 text-sm text-n-slate-12 cursor-pointer"
                  >
                    <input
                      v-model="requirement.condition_values"
                      type="checkbox"
                      :value="value"
                      class="m-0"
                    />
                    {{ value }}
                  </label>
                </div>
              </template>
              <div v-else class="flex flex-col gap-1">
                <label class="text-sm font-medium text-n-slate-11 mt-1">
                  {{
                    $t('OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIREMENTS.IF_VALUE')
                  }}
                </label>
                <input
                  v-model="requirement.condition_values[0]"
                  type="text"
                  :placeholder="
                    $t(
                      'OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIREMENTS.IF_VALUE_PLACEHOLDER'
                    )
                  "
                  class="w-full px-3 py-2.5 rounded-lg border border-n-weak bg-n-solid-2 text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
                />
              </div>
            </template>
          </div>
        </div>
        <Button
          faded
          slate
          size="sm"
          icon="i-lucide-plus"
          :label="$t('OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIREMENTS.ADD')"
          @click="addRequirement"
        />
      </div>

      <div class="flex justify-end">
        <Button
          :label="$t('OPERATIONAL_FLOWS_SETTINGS.FORM.SAVE')"
          :disabled="
            !isValid || isSaving || uiFlags.isCreating || uiFlags.isUpdating
          "
          :is-loading="isSaving"
          @click="save"
        />
      </div>
    </template>
  </div>
</template>
