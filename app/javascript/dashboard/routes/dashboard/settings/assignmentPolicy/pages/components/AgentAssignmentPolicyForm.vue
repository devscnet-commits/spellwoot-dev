<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute } from 'vue-router';
import { useMapGetter } from 'dashboard/composables/store';
import { useFormDirty } from 'dashboard/composables/useFormDirty';
import { vOnClickOutside } from '@vueuse/components';
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
  policyInboxes:    { type: Array,   default: () => [] },
  inboxList:        { type: Array,   default: () => [] },
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

// ── Inbox multi-select ────────────────────────────────────────────────────────

const isDropdownOpen = ref(false);
const inboxSearch = ref('');
// Local selected IDs — used in CREATE mode only
const localSelectedIds = ref([]);

const closeDropdown = () => {
  isDropdownOpen.value = false;
  inboxSearch.value = '';
};

const isInboxSelected = inbox => {
  if (isCreate.value) return localSelectedIds.value.includes(inbox.id);
  return props.policyInboxes.some(i => i.id === inbox.id);
};

// Inboxes shown as selected chips
const selectedInboxes = computed(() => {
  if (isCreate.value) {
    return props.inboxList.filter(i => localSelectedIds.value.includes(i.id));
  }
  return props.policyInboxes;
});

// Inboxes shown inside the dropdown (not yet selected, filtered by search)
const dropdownInboxes = computed(() => {
  const q = inboxSearch.value.toLowerCase();
  return props.inboxList.filter(
    i => !isInboxSelected(i) && (!q || i.name.toLowerCase().includes(q))
  );
});

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

const removeInbox = inbox => {
  if (isCreate.value) {
    localSelectedIds.value = localSelectedIds.value.filter(id => id !== inbox.id);
  } else {
    emit('deleteInbox', inbox.id);
  }
};

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
  closeDropdown();
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

      <!-- 1. Nome e descrição -->
      <BaseInfo
        v-model:policy-name="state.name"
        v-model:description="state.description"
        :name-label="t(`${BASE_KEY}.FORM.NAME.LABEL`)"
        :name-placeholder="t(`${BASE_KEY}.FORM.NAME.PLACEHOLDER`)"
        :description-label="t(`${BASE_KEY}.FORM.DESCRIPTION.LABEL`)"
        :description-placeholder="t(`${BASE_KEY}.FORM.DESCRIPTION.PLACEHOLDER`)"
        @validation-change="handleValidationChange"
      />

      <!-- 2. Caixas de entrada vinculadas -->
      <div class="pt-4 flex flex-col gap-3">
        <div class="flex flex-col gap-0.5">
          <label class="text-sm font-medium text-n-slate-12">
            Caixas de entrada vinculadas
          </label>
          <p class="text-sm text-n-slate-10">
            Selecione as caixas de entrada que participarão desta política.
          </p>
        </div>

        <!-- Dropdown trigger -->
        <div v-on-click-outside="closeDropdown" class="relative">
          <button
            type="button"
            class="flex items-center justify-between w-full px-3 py-2 text-sm rounded-lg border border-n-weak bg-n-solid-2 text-n-slate-12 hover:border-n-brand transition-colors focus:outline-none focus:border-n-brand"
            @click="isDropdownOpen = !isDropdownOpen"
          >
            <span class="text-n-slate-9">Selecionar caixas de entrada</span>
            <span
              class="i-lucide-chevron-down size-4 text-n-slate-9 transition-transform duration-200"
              :class="{ 'rotate-180': isDropdownOpen }"
            />
          </button>

          <!-- Dropdown panel -->
          <div
            v-if="isDropdownOpen"
            class="absolute z-20 mt-1 w-full rounded-lg border border-n-weak bg-n-solid-1 shadow-lg"
          >
            <!-- Search inside dropdown -->
            <div class="p-2 border-b border-n-weak">
              <SearchInput
                v-model="inboxSearch"
                placeholder="Buscar caixa de entrada..."
              />
            </div>

            <!-- Loading -->
            <div v-if="isInboxLoading" class="px-3 py-4 text-sm text-n-slate-10 text-center">
              Carregando caixas de entrada...
            </div>

            <!-- Inbox list -->
            <div v-else class="max-h-48 overflow-y-auto">
              <button
                v-for="inbox in dropdownInboxes"
                :key="inbox.id"
                type="button"
                class="flex items-center gap-2 w-full px-3 py-2.5 text-left text-sm text-n-slate-12 hover:bg-n-alpha-black2 transition-colors"
                @click="toggleInbox(inbox)"
              >
                <span class="i-lucide-inbox size-4 text-n-slate-9 flex-shrink-0" />
                <span class="flex-1 truncate">{{ inbox.name }}</span>
              </button>

              <div
                v-if="!dropdownInboxes.length"
                class="px-3 py-4 text-sm text-n-slate-10 text-center"
              >
                {{ inboxSearch ? 'Nenhuma caixa encontrada.' : 'Todas as caixas já foram vinculadas.' }}
              </div>
            </div>
          </div>
        </div>

        <!-- Selected inboxes as chips -->
        <div v-if="selectedInboxes.length" class="flex flex-wrap gap-2">
          <span
            v-for="inbox in selectedInboxes"
            :key="inbox.id"
            class="inline-flex items-center gap-1.5 pl-3 pr-1.5 py-1 rounded-full text-sm font-medium bg-n-blue-3 text-n-blue-11 border border-n-blue-6"
          >
            {{ inbox.name }}
            <button
              type="button"
              class="flex items-center justify-center size-4 rounded-full hover:bg-n-blue-5 transition-colors flex-shrink-0"
              @click="removeInbox(inbox)"
            >
              <span class="i-lucide-x size-3" />
            </button>
          </span>
        </div>

        <p v-else class="text-sm text-n-slate-10">
          Nenhuma caixa vinculada.
        </p>
      </div>

      <!-- 3. Ordem de atribuição -->
      <div class="flex flex-col items-center">
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

        <!-- 4. Prioridade de atribuição -->
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

      <!-- 5. Política de distribuição justa -->
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
    </div>

    <!-- Salvar -->
    <Button
      type="submit"
      :label="buttonLabel"
      :disabled="!validationState.isValid || isLoading || (!isCreate && !isDirty)"
      :is-loading="isLoading"
    />
  </form>
</template>
