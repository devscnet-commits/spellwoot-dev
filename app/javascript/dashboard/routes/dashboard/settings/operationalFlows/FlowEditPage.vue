<script setup>
import { computed, onMounted, ref } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';

import Switch from 'dashboard/components-next/switch/Switch.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

const store = useStore();
const route = useRoute();
const router = useRouter();
const { t } = useI18n();

const getFlow = useMapGetter('operationalFlows/getFlow');
const uiFlags = useMapGetter('operationalFlows/getUIFlags');
const inboxes = useMapGetter('inboxes/getInboxes');
const conversationAttributes = useMapGetter('attributes/getConversationAttributes');

const flowId = computed(() =>
  route.params.flowId ? Number(route.params.flowId) : null
);
const isEdit = computed(() => !!flowId.value);

const CATEGORIES = ['sales', 'support'];
const POLARITIES = ['positive', 'negative', 'neutral'];
// Standard Meta event names a state can fire ('' = do not send). value only matters for Purchase.
const META_EVENTS = ['', 'Purchase', 'Lead', 'CompleteRegistration'];

const metaAttributeOptions = computed(() =>
  (conversationAttributes.value || []).map(attribute => ({
    value: attribute.attributeKey,
    label: attribute.attributeDisplayName,
  }))
);

// Each state mirrors a closing button: canonical_key is immutable, display_label is free text.
const defaultStates = () => [
  {
    canonical_key: 'won',
    display_label: 'Ganho',
    polarity: 'positive',
    requires_reason: false,
    meta_event_type: '',
    meta_value_attr: '',
    reasons: [],
  },
  {
    canonical_key: 'lost',
    display_label: 'Perdido',
    polarity: 'negative',
    requires_reason: false,
    meta_event_type: '',
    meta_value_attr: '',
    reasons: [],
  },
];

const name = ref('');
const category = ref('sales');
const active = ref(true);
const metaEnabled = ref(false);
const states = ref(defaultStates());
const removedReasonIds = ref([]);
const requirements = ref([]);
const removedRequirementIds = ref([]);
const selectedInboxIds = ref([]);
const isSaving = ref(false);
const isLoading = ref(false);

// A requirement's `when` is either 'always' or a resolution state's canonical_key.
const conditionToWhen = condition => {
  if (condition?.always) return 'always';
  return condition?.when?.canonical_key || 'always';
};
const whenToCondition = when =>
  when === 'always' ? { always: true } : { when: { canonical_key: when } };

// Condition choices: "always" plus one per resolution state (shown by its editable label).
const conditionOptions = computed(() => [
  {
    value: 'always',
    label: t('OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIREMENTS.ALWAYS'),
  },
  ...states.value.map(state => ({
    value: state.canonical_key,
    label: t('OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIREMENTS.WHEN_STATE', {
      state: state.display_label,
    }),
  })),
]);

const populate = flow => {
  if (!flow) return;
  name.value = flow.name || '';
  category.value = flow.category || 'sales';
  active.value = flow.active ?? true;
  metaEnabled.value = !!flow.meta_enabled;
  selectedInboxIds.value = [...(flow.inbox_ids || [])];

  const reasons = flow.reasons || [];
  const reasonsForResult = result =>
    reasons
      .filter(r => r.result === result)
      .sort((a, b) => a.position - b.position)
      .map(r => ({ id: r.id, label: r.label }));

  const apiStates = (flow.resolution_states || []).sort(
    (a, b) => a.sort_order - b.sort_order
  );
  states.value = (apiStates.length ? apiStates : defaultStates()).map(s => ({
    id: s.id,
    canonical_key: s.canonical_key,
    display_label: s.display_label,
    polarity: s.polarity || 'neutral',
    requires_reason: !!s.requires_reason,
    meta_event_type: s.meta_event_type || '',
    meta_value_attr: s.meta_value_attr || '',
    reasons: reasonsForResult(s.canonical_key),
  }));

  requirements.value = (flow.closing_requirements || [])
    .slice()
    .sort((a, b) => a.sort_order - b.sort_order)
    .map(r => ({
      id: r.id,
      attribute_key: r.attribute_key,
      when: conditionToWhen(r.condition),
    }));
};

onMounted(async () => {
  store.dispatch('inboxes/get');
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

const addReason = state => {
  state.reasons.push({ label: '' });
};

const removeReason = (state, index) => {
  const [removed] = state.reasons.splice(index, 1);
  if (removed?.id) removedReasonIds.value.push(removed.id);
};

const buildStatesAttributes = () =>
  states.value.map((state, sortOrder) => ({
    ...(state.id ? { id: state.id } : {}),
    canonical_key: state.canonical_key,
    display_label: state.display_label.trim(),
    polarity: state.polarity,
    requires_reason: state.requires_reason,
    meta_event_type: state.meta_event_type || null,
    meta_value_attr: state.meta_value_attr || null,
    sort_order: sortOrder,
  }));

const buildReasonsAttributes = () => {
  const rows = [];
  states.value.forEach(state => {
    state.reasons.forEach((reason, position) => {
      if (!reason.label.trim()) return;
      rows.push({
        ...(reason.id ? { id: reason.id } : {}),
        result: state.canonical_key,
        label: reason.label.trim(),
        position,
        active: true,
      });
    });
  });
  removedReasonIds.value.forEach(id => rows.push({ id, _destroy: true }));
  return rows;
};

const addRequirement = () => {
  requirements.value.push({ attribute_key: '', when: 'always' });
};

const removeRequirement = index => {
  const [removed] = requirements.value.splice(index, 1);
  if (removed?.id) removedRequirementIds.value.push(removed.id);
};

const buildRequirementsAttributes = () => {
  const rows = [];
  requirements.value.forEach((requirement, sortOrder) => {
    if (!requirement.attribute_key) return;
    rows.push({
      ...(requirement.id ? { id: requirement.id } : {}),
      attribute_key: requirement.attribute_key,
      condition: whenToCondition(requirement.when),
      sort_order: sortOrder,
    });
  });
  removedRequirementIds.value.forEach(id => rows.push({ id, _destroy: true }));
  return rows;
};

const isValid = computed(
  () =>
    name.value.trim() && states.value.every(s => s.display_label.trim().length)
);

const save = async () => {
  if (!isValid.value) return;
  isSaving.value = true;
  const payload = {
    name: name.value.trim(),
    category: category.value,
    require_reason: states.value.some(s => s.requires_reason),
    active: active.value,
    meta_enabled: metaEnabled.value,
    inbox_ids: selectedInboxIds.value,
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
  <div class="p-6 col-span-full w-full max-w-3xl mx-auto flex flex-col gap-6">
    <div v-if="isLoading" class="flex justify-center py-8">
      <Spinner class="text-n-brand" />
    </div>
    <template v-else>
      <div class="flex flex-col gap-0.5">
        <h2 class="text-heading-2 font-semibold text-n-slate-12">
          {{
            isEdit
              ? $t('OPERATIONAL_FLOWS_SETTINGS.FORM.EDIT_TITLE')
              : $t('OPERATIONAL_FLOWS_SETTINGS.FORM.NEW_TITLE')
          }}
        </h2>
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
          class="w-full px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
        />
      </div>

      <div class="flex flex-col gap-1">
        <label class="text-sm font-medium text-n-slate-12">
          {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.CATEGORY.LABEL') }}
        </label>
        <p class="text-xs text-n-slate-11">
          {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.CATEGORY.HELP') }}
        </p>
        <select
          v-model="category"
          class="w-full px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
        >
          <option v-for="option in CATEGORIES" :key="option" :value="option">
            {{ $t(`OPERATIONAL_FLOWS_SETTINGS.FORM.CATEGORY.OPTIONS.${option}`) }}
          </option>
        </select>
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
          <span class="text-xs text-n-slate-11">
            {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.META.HELP') }}
          </span>
        </div>
        <Switch v-model="metaEnabled" />
      </div>

      <div class="flex flex-col gap-3">
        <div class="flex flex-col gap-0.5">
          <label class="text-sm font-medium text-n-slate-12">
            {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.STATES.LABEL') }}
          </label>
          <p class="text-xs text-n-slate-11">
            {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.STATES.HELP') }}
          </p>
        </div>

        <div
          v-for="state in states"
          :key="state.canonical_key"
          class="flex flex-col gap-3 border border-n-weak rounded-xl p-4"
        >
          <div class="flex items-center gap-2">
            <span
              class="px-1.5 py-0.5 text-xs font-mono rounded text-n-slate-11 bg-n-alpha-2"
            >
              {{ state.canonical_key }}
            </span>
            <span class="text-xs text-n-slate-11">
              {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.STATES.CANONICAL_FIXED') }}
            </span>
          </div>

          <div class="flex flex-col gap-3 sm:flex-row">
            <div class="flex flex-col gap-1 flex-1">
              <label class="text-xs font-medium text-n-slate-11">
                {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.STATES.DISPLAY_LABEL') }}
              </label>
              <input
                v-model="state.display_label"
                type="text"
                class="w-full px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
              />
            </div>
            <div class="flex flex-col gap-1 sm:w-40">
              <label class="text-xs font-medium text-n-slate-11">
                {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.STATES.POLARITY') }}
              </label>
              <select
                v-model="state.polarity"
                class="w-full px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
              >
                <option
                  v-for="option in POLARITIES"
                  :key="option"
                  :value="option"
                >
                  {{
                    $t(
                      `OPERATIONAL_FLOWS_SETTINGS.FORM.STATES.POLARITY_OPTIONS.${option}`
                    )
                  }}
                </option>
              </select>
            </div>
          </div>

          <div class="flex items-center justify-between">
            <span class="text-xs text-n-slate-11">
              {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.STATES.REQUIRES_REASON') }}
            </span>
            <Switch v-model="state.requires_reason" />
          </div>

          <div
            v-if="metaEnabled"
            class="flex flex-col gap-3 sm:flex-row border-t border-n-weak pt-3"
          >
            <div class="flex flex-col gap-1 flex-1">
              <label class="text-xs font-medium text-n-slate-11">
                {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.STATES.META_EVENT') }}
              </label>
              <select
                v-model="state.meta_event_type"
                class="w-full px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
              >
                <option v-for="option in META_EVENTS" :key="option" :value="option">
                  {{
                    option ||
                    $t('OPERATIONAL_FLOWS_SETTINGS.FORM.STATES.META_NONE')
                  }}
                </option>
              </select>
            </div>
            <div
              v-if="state.meta_event_type === 'Purchase'"
              class="flex flex-col gap-1 flex-1"
            >
              <label class="text-xs font-medium text-n-slate-11">
                {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.STATES.META_VALUE_ATTR') }}
              </label>
              <select
                v-model="state.meta_value_attr"
                class="w-full px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
              >
                <option value="">
                  {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.STATES.META_NO_VALUE') }}
                </option>
                <option
                  v-for="option in metaAttributeOptions"
                  :key="option.value"
                  :value="option.value"
                >
                  {{ option.label }}
                </option>
              </select>
            </div>
          </div>

          <div class="flex flex-col gap-2">
            <div
              v-for="(reason, index) in state.reasons"
              :key="index"
              class="flex items-center gap-2"
            >
              <input
                v-model="reason.label"
                type="text"
                :placeholder="
                  $t('OPERATIONAL_FLOWS_SETTINGS.FORM.REASON_PLACEHOLDER')
                "
                class="flex-1 px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
              />
              <Button
                icon="i-woot-bin"
                slate
                sm
                class="hover:enabled:text-n-ruby-11 hover:enabled:bg-n-ruby-2"
                @click="removeReason(state, index)"
              />
            </div>
            <Button
              faded
              slate
              size="sm"
              icon="i-lucide-plus"
              :label="$t('OPERATIONAL_FLOWS_SETTINGS.FORM.ADD_REASON')"
              @click="addReason(state)"
            />
          </div>
        </div>
      </div>

      <div class="flex flex-col gap-3">
        <div class="flex flex-col gap-0.5">
          <label class="text-sm font-medium text-n-slate-12">
            {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIREMENTS.LABEL') }}
          </label>
          <p class="text-xs text-n-slate-11">
            {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIREMENTS.HELP') }}
          </p>
        </div>
        <div
          v-for="(requirement, index) in requirements"
          :key="index"
          class="flex flex-col gap-2 sm:flex-row sm:items-center"
        >
          <select
            v-model="requirement.attribute_key"
            class="flex-1 px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
          >
            <option value="" disabled>
              {{
                $t('OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIREMENTS.SELECT_ATTRIBUTE')
              }}
            </option>
            <option
              v-for="option in metaAttributeOptions"
              :key="option.value"
              :value="option.value"
            >
              {{ option.label }}
            </option>
          </select>
          <select
            v-model="requirement.when"
            class="sm:w-56 px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
          >
            <option
              v-for="option in conditionOptions"
              :key="option.value"
              :value="option.value"
            >
              {{ option.label }}
            </option>
          </select>
          <Button
            icon="i-woot-bin"
            slate
            sm
            class="hover:enabled:text-n-ruby-11 hover:enabled:bg-n-ruby-2"
            @click="removeRequirement(index)"
          />
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

      <div class="flex flex-col gap-2">
        <label class="text-sm font-medium text-n-slate-12">
          {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.INBOXES.LABEL') }}
        </label>
        <p class="text-xs text-n-slate-11">
          {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.INBOXES.HELP') }}
        </p>
        <div
          v-if="inboxes.length"
          class="flex flex-col gap-1 border border-n-weak rounded-xl p-3"
        >
          <label
            v-for="inbox in inboxes"
            :key="inbox.id"
            class="flex items-center gap-2 py-1 cursor-pointer"
          >
            <input
              v-model="selectedInboxIds"
              type="checkbox"
              :value="inbox.id"
            />
            <span class="text-sm text-n-slate-12">{{ inbox.name }}</span>
          </label>
        </div>
        <p v-else class="text-sm text-n-slate-11">
          {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.INBOXES.EMPTY') }}
        </p>
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
