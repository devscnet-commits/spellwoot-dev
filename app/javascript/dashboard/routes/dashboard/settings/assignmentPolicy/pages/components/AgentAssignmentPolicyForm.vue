<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import { useMapGetter } from 'dashboard/composables/store';
import { useFormDirty } from 'dashboard/composables/useFormDirty';
import BaseInfo from 'dashboard/components-next/AssignmentPolicy/components/BaseInfo.vue';
import RadioCard from 'dashboard/components-next/radioCard/RadioCard.vue';
import FairDistribution from 'dashboard/components-next/AssignmentPolicy/components/FairDistribution.vue';
import WithLabel from 'v3/components/Form/WithLabel.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import SearchInput from 'dashboard/components-next/input/SearchInput.vue';
import {
  OPTIONS,
  ROUND_ROBIN,
  BALANCED,
  EARLIEST_CREATED,
  LONGEST_WAITING,
  DEFAULT_FAIR_DISTRIBUTION_LIMIT,
  DEFAULT_FAIR_DISTRIBUTION_WINDOW,
} from 'dashboard/routes/dashboard/settings/assignmentPolicy/constants';

const props = defineProps({
  initialData: {
    type: Object,
    default: () => ({
      name: '',
      description: '',
      enabled: true,
      assignmentOrder: ROUND_ROBIN,
      conversationPriority: EARLIEST_CREATED,
      fairDistributionLimit: DEFAULT_FAIR_DISTRIBUTION_LIMIT,
      fairDistributionWindow: DEFAULT_FAIR_DISTRIBUTION_WINDOW,
    }),
  },
  mode: {
    type: String,
    required: true,
    validator: value => ['CREATE', 'EDIT'].includes(value),
  },
  policyInboxes: { type: Array, default: () => [] },
  inboxList:     { type: Array, default: () => [] },
  // Legacy prop — kept for EDIT compat but no longer controls visibility
  showInboxSection: { type: Boolean, default: true },
  isLoading:        { type: Boolean, default: false },
  isInboxLoading:   { type: Boolean, default: false },
});

const emit = defineEmits([
  'submit',
  'addInbox',
  'deleteInbox',
  'navigateToInbox',
  'validationChange',
  'dirtyChange',
]);

const { t } = useI18n();
const route = useRoute();

const accountId = computed(() => Number(route.params.accountId));
const isFeatureEnabledonAccount = useMapGetter('accounts/isFeatureEnabledonAccount');
const BASE_KEY = 'ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY';

const isCreate = computed(() => props.mode === 'CREATE');

// ── Form state ────────────────────────────────────────────────────────────────

const state = reactive({
  name: '',
  description: '',
  enabled: true,
  assignmentOrder: ROUND_ROBIN,
  conversationPriority: EARLIEST_CREATED,
  fairDistributionLimit: DEFAULT_FAIR_DISTRIBUTION_LIMIT,
  fairDistributionWindow: DEFAULT_FAIR_DISTRIBUTION_WINDOW,
});

const validationState = ref({ isValid: false });

// ── Dirty tracking (EDIT mode only) ──────────────────────────────────────────

const { isDirty, capture } = useFormDirty(() => ({
  name: state.name,
  description: state.description,
  enabled: state.enabled,
  assignmentOrder: state.assignmentOrder,
  conversationPriority: state.conversationPriority,
  fairDistributionLimit: state.fairDistributionLimit,
  fairDistributionWindow: state.fairDistributionWindow,
}));

watch(isDirty, val => emit('dirtyChange', val));

// ── Inbox selection ───────────────────────────────────────────────────────────

const inboxSearch = ref('');
// Local selected IDs — used in CREATE mode only
const localSelectedIds = ref([]);

const isInboxSelected = inbox => {
  if (isCreate.value) return localSelectedIds.value.includes(inbox.id);
  return props.policyInboxes.some(i => i.id === inbox.id);
};

const toggleInbox = inbox => {
  if (isInboxSelected(inbox)) {
    if (isCreate.value) {
      localSelectedIds.value = localSelectedIds.value.filter(id => id !== inbox.id);
    } else {
      emit('deleteInbox', inbox.id);
    }
  } else {
    if (isCreate.value) {
      localSelectedIds.value = [...localSelectedIds.value, inbox.id];
    } else {
      emit('addInbox', inbox);
    }
  }
};

// Selected first, then available — both filtered by search
const sortedInboxes = computed(() => {
  const q = inboxSearch.value.toLowerCase();
  const filtered = props.inboxList.filter(i => i.name.toLowerCase().includes(q));
  return [
    ...filtered.filter(i => isInboxSelected(i)),
    ...filtered.filter(i => !isInboxSelected(i)),
  ];
});

const selectedInboxCount = computed(() =>
  isCreate.value ? localSelectedIds.value.length : props.policyInboxes.length
);

// ── Radio options ─────────────────────────────────────────────────────────────

const createOption = (type, key, stateKey, disabled = false, disabledMessage = '', disabledLabel = '') => ({
  key,
  label: t(`${BASE_KEY}.FORM.${type}.${key.toUpperCase()}.LABEL`),
  description: t(`${BASE_KEY}.FORM.${type}.${key.toUpperCase()}.DESCRIPTION`),
  isActive: state[stateKey] === key,
  disabled,
  disabledMessage,
  disabledLabel,
});

const assignmentOrderOptions = computed(() => {
  const hasAdvancedAssignment = isFeatureEnabledonAccount.value(accountId.value, 'advanced_assignment');
  return OPTIONS.ORDER.map(key => {
    const isBalanced = key === BALANCED;
    const disabled = isBalanced && !hasAdvancedAssignment;
    return createOption(
      'ASSIGNMENT_ORDER',
      key,
      'assignmentOrder',
      disabled,
      disabled ? t(`${BASE_KEY}.FORM.ASSIGNMENT_ORDER.BALANCED.PREMIUM_MESSAGE`) : '',
      disabled ? t(`${BASE_KEY}.FORM.ASSIGNMENT_ORDER.BALANCED.PREMIUM_BADGE`) : ''
    );
  });
});

const assignmentPriorityOptions = computed(() =>
  OPTIONS.PRIORITY.map(key => createOption('ASSIGNMENT_PRIORITY', key, 'conversationPriority'))
);

// ── Summary ───────────────────────────────────────────────────────────────────

const summaryStrategy = computed(() => {
  const key = state.assignmentOrder === BALANCED ? 'BALANCED' : 'ROUND_ROBIN';
  return t(`${BASE_KEY}.FORM.ASSIGNMENT_ORDER.${key}.LABEL`);
});

const summaryPriority = computed(() => {
  const key = state.conversationPriority === LONGEST_WAITING ? 'LONGEST_WAITING' : 'EARLIEST_CREATED';
  return t(`${BASE_KEY}.FORM.ASSIGNMENT_PRIORITY.${key}.LABEL`);
});

const summaryLimit = computed(() => {
  const secs = state.fairDistributionWindow;
  const unitLabel = secs % 3600 === 0
    ? `${secs / 3600}h`
    : `${Math.round(secs / 60)}min`;
  return `${state.fairDistributionLimit} / ${unitLabel}`;
});

// ── Misc ──────────────────────────────────────────────────────────────────────

const buttonLabel = computed(() => {
  if (isCreate.value) return t(`${BASE_KEY}.CREATE.CREATE_BUTTON`);
  return isDirty.value
    ? t(`${BASE_KEY}.EDIT.SAVE_CHANGES_BUTTON`)
    : t(`${BASE_KEY}.EDIT.SAVED_BUTTON`);
});

const handleValidationChange = validation => {
  validationState.value = validation;
  emit('validationChange', validation);
};

const resetForm = () => {
  Object.assign(state, {
    name: '',
    description: '',
    enabled: true,
    assignmentOrder: ROUND_ROBIN,
    conversationPriority: EARLIEST_CREATED,
    fairDistributionLimit: DEFAULT_FAIR_DISTRIBUTION_LIMIT,
    fairDistributionWindow: DEFAULT_FAIR_DISTRIBUTION_WINDOW,
  });
  localSelectedIds.value = [];
  inboxSearch.value = '';
  capture();
};

const handleSubmit = () => {
  const payload = { ...state };
  if (isCreate.value) {
    payload.inboxIds = [...localSelectedIds.value];
  }
  emit('submit', payload);
};

watch(
  () => props.initialData,
  newData => {
    Object.assign(state, newData);
    if (!isCreate.value) capture();
  },
  { immediate: true, deep: true }
);

defineExpose({ resetForm });
</script>

<template>
  <form @submit.prevent="handleSubmit">
    <div class="flex flex-col gap-4 divide-y divide-n-weak mb-4">

      <!-- 1. Informações Gerais -->
      <BaseInfo
        v-model:policy-name="state.name"
        v-model:description="state.description"
        :name-label="t(`${BASE_KEY}.FORM.NAME.LABEL`)"
        :name-placeholder="t(`${BASE_KEY}.FORM.NAME.PLACEHOLDER`)"
        :description-label="t(`${BASE_KEY}.FORM.DESCRIPTION.LABEL`)"
        :description-placeholder="t(`${BASE_KEY}.FORM.DESCRIPTION.PLACEHOLDER`)"
        @validation-change="handleValidationChange"
      />

      <!-- 2. Aplicação — Caixas participantes -->
      <div class="pt-4 flex flex-col gap-3">
        <div class="flex flex-col gap-0.5">
          <label class="text-sm font-medium text-n-slate-12">
            {{ t(`${BASE_KEY}.FORM.INBOXES.LABEL`) }}
          </label>
          <p class="text-sm text-n-slate-10">
            {{ t(`${BASE_KEY}.FORM.INBOXES.DESCRIPTION`) }}
          </p>
        </div>

        <!-- Search -->
        <SearchInput
          v-model="inboxSearch"
          :placeholder="t(`${BASE_KEY}.FORM.INBOXES.SEARCH_PLACEHOLDER`)"
        />

        <!-- Inbox checklist -->
        <div v-if="inboxList.length" class="flex flex-col max-h-48 overflow-y-auto rounded-xl border border-n-weak divide-y divide-n-weak">
          <button
            v-for="inbox in sortedInboxes"
            :key="inbox.id"
            type="button"
            class="flex items-center gap-3 px-3 py-2.5 text-left transition-colors hover:bg-n-alpha-black2"
            :class="isInboxSelected(inbox) ? 'bg-n-blue-3' : ''"
            @click="toggleInbox(inbox)"
          >
            <span
              class="size-4 flex-shrink-0 flex items-center justify-center rounded border transition-colors"
              :class="isInboxSelected(inbox)
                ? 'bg-n-blue-9 border-n-blue-9 text-white'
                : 'border-n-weak bg-n-solid-2'"
            >
              <span v-if="isInboxSelected(inbox)" class="i-lucide-check size-3" />
            </span>
            <span class="text-sm text-n-slate-12 flex-1 truncate">{{ inbox.name }}</span>
            <span
              v-if="isInboxSelected(inbox)"
              class="text-label-small text-n-blue-9 font-medium flex-shrink-0"
            >
              {{ t(`${BASE_KEY}.FORM.INBOXES.SELECTED`) }}
            </span>
          </button>

          <div
            v-if="!sortedInboxes.length"
            class="px-3 py-4 text-sm text-n-slate-10 text-center"
          >
            {{ t(`${BASE_KEY}.FORM.INBOXES.EMPTY_STATE`) }}
          </div>
        </div>

        <div
          v-else-if="isInboxLoading"
          class="text-sm text-n-slate-10 text-center py-4"
        >
          {{ t(`${BASE_KEY}.FORM.INBOXES.LOADING`) }}
        </div>

        <p v-if="selectedInboxCount > 0" class="text-label-small text-n-slate-11">
          {{ t(`${BASE_KEY}.FORM.INBOXES.SELECTED_COUNT`, { count: selectedInboxCount }) }}
        </p>
      </div>

      <!-- 3. Estratégia e Prioridade -->
      <div class="flex flex-col items-center">
        <!-- Strategy -->
        <div class="py-4 flex flex-col items-start gap-3 w-full">
          <WithLabel
            :label="t(`${BASE_KEY}.FORM.ASSIGNMENT_ORDER.LABEL`)"
            name="assignmentOrder"
            class="w-full flex items-start flex-col gap-3"
          >
            <div class="grid grid-cols-1 xs:grid-cols-2 gap-4 w-full">
              <RadioCard
                v-for="option in assignmentOrderOptions"
                :id="option.key"
                :key="option.key"
                :label="option.label"
                :description="option.description"
                :is-active="option.isActive"
                :disabled="option.disabled"
                :disabled-label="option.disabledLabel"
                :disabled-message="option.disabledMessage"
                @select="state.assignmentOrder = $event"
              />
            </div>
          </WithLabel>
        </div>

        <!-- Priority -->
        <div class="py-4 flex flex-col items-start gap-3 w-full border-t border-n-weak">
          <WithLabel
            :label="t(`${BASE_KEY}.FORM.ASSIGNMENT_PRIORITY.LABEL`)"
            name="conversationPriority"
            class="w-full flex items-start flex-col gap-3"
          >
            <div class="grid grid-cols-1 xs:grid-cols-2 gap-4 w-full">
              <RadioCard
                v-for="option in assignmentPriorityOptions"
                :id="option.key"
                :key="option.key"
                :label="option.label"
                :description="option.description"
                :is-active="option.isActive"
                :disabled="option.disabled"
                :disabled-label="option.disabledLabel"
                :disabled-message="option.disabledMessage"
                @select="state.conversationPriority = $event"
              />
            </div>
          </WithLabel>
        </div>
      </div>

      <!-- 4. Limite de distribuição (ex "Política de distribuição justa") -->
      <div class="pt-4 pb-2 flex-col flex gap-4">
        <div class="flex flex-col items-start gap-1 py-1">
          <label class="text-sm font-medium text-n-slate-12 py-1">
            {{ t(`${BASE_KEY}.FORM.FAIR_DISTRIBUTION.LABEL`) }}
          </label>
          <p class="mb-0 text-n-slate-11 text-sm">
            {{ t(`${BASE_KEY}.FORM.FAIR_DISTRIBUTION.DESCRIPTION`) }}
          </p>
        </div>
        <FairDistribution
          v-model:fair-distribution-limit="state.fairDistributionLimit"
          v-model:fair-distribution-window="state.fairDistributionWindow"
          v-model:window-unit="state.windowUnit"
        />
      </div>

      <!-- 5. Resumo -->
      <div class="pt-4 pb-2 flex flex-col gap-2">
        <p class="text-sm font-medium text-n-slate-12">
          {{ t(`${BASE_KEY}.FORM.SUMMARY.TITLE`) }}
        </p>
        <ul class="flex flex-col gap-1.5 text-sm text-n-slate-11">
          <li class="flex items-center gap-2">
            <span class="i-lucide-inbox size-4 text-n-slate-9" />
            {{ t(`${BASE_KEY}.FORM.SUMMARY.INBOXES`, { count: selectedInboxCount }) }}
          </li>
          <li class="flex items-center gap-2">
            <span class="i-lucide-shuffle size-4 text-n-slate-9" />
            {{ t(`${BASE_KEY}.FORM.SUMMARY.STRATEGY`) }}: <strong class="text-n-slate-12">{{ summaryStrategy }}</strong>
          </li>
          <li class="flex items-center gap-2">
            <span class="i-lucide-arrow-up-narrow-wide size-4 text-n-slate-9" />
            {{ t(`${BASE_KEY}.FORM.SUMMARY.PRIORITY`) }}: <strong class="text-n-slate-12">{{ summaryPriority }}</strong>
          </li>
          <li class="flex items-center gap-2">
            <span class="i-lucide-gauge size-4 text-n-slate-9" />
            {{ t(`${BASE_KEY}.FORM.SUMMARY.LIMIT`) }}: <strong class="text-n-slate-12">{{ summaryLimit }}</strong>
          </li>
        </ul>
      </div>
    </div>

    <!-- Save -->
    <Button
      type="submit"
      :label="buttonLabel"
      :disabled="!validationState.isValid || isLoading || (!isCreate && !isDirty)"
      :is-loading="isLoading"
    />
  </form>
</template>
