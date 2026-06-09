<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useFormDirty } from 'dashboard/composables/useFormDirty';
import BaseInfo from 'dashboard/components-next/AssignmentPolicy/components/BaseInfo.vue';
import DataTable from 'dashboard/components-next/AssignmentPolicy/components/DataTable.vue';
import AddDataDropdown from 'dashboard/components-next/AssignmentPolicy/components/AddDataDropdown.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import ExclusionRules from 'dashboard/components-next/AssignmentPolicy/components/ExclusionRules.vue';
import InboxCapacityLimits from 'dashboard/components-next/AssignmentPolicy/components/InboxCapacityLimits.vue';

const props = defineProps({
  initialData: {
    type: Object,
    default: () => ({
      name: '',
      description: '',
      enabled: false,
      exclusionRules: {
        excludedLabels: [],
        excludeOlderThanHours: null,
      },
      inboxCapacityLimits: [],
    }),
  },
  mode: {
    type: String,
    required: true,
    validator: value => ['CREATE', 'EDIT'].includes(value),
  },
  policyUsers: {
    type: Array,
    default: () => [],
  },
  agentList: {
    type: Array,
    default: () => [],
  },
  labelList: {
    type: Array,
    default: () => [],
  },
  inboxList: {
    type: Array,
    default: () => [],
  },
  isLoading: {
    type: Boolean,
    default: false,
  },
  isUsersLoading: {
    type: Boolean,
    default: false,
  },
  isInboxesLoading: {
    type: Boolean,
    default: false,
  },
});

const emit = defineEmits([
  'submit',
  'addUser',
  'deleteUser',
  'validationChange',
  'deleteInboxLimit',
  'addInboxLimit',
  'updateInboxLimit',
  'dirtyChange',
]);

const { t } = useI18n();

const BASE_KEY = 'ASSIGNMENT_POLICY.AGENT_CAPACITY_POLICY';

const isCreate = computed(() => props.mode === 'CREATE');

const state = reactive({
  name: '',
  description: '',
  exclusionRules: {
    excludedLabels: [],
    excludeOlderThanHours: null,
  },
  inboxCapacityLimits: [],
  localUsers: [], // only used in CREATE mode
});

const validationState = ref({ isValid: false });

// ── Dirty tracking (EDIT mode only) ──────────────────────────────────────────

const { isDirty, capture } = useFormDirty(() => ({
  name: state.name,
  description: state.description,
  exclusionRules: JSON.parse(JSON.stringify(state.exclusionRules)),
}));

watch(isDirty, val => emit('dirtyChange', val));

const buttonLabel = computed(() => {
  if (isCreate.value) return t(`${BASE_KEY}.CREATE.CREATE_BUTTON`);
  return isDirty.value
    ? t(`${BASE_KEY}.EDIT.SAVE_CHANGES_BUTTON`)
    : t(`${BASE_KEY}.EDIT.SAVED_BUTTON`);
});

// ── Computed for display ──────────────────────────────────────────────────────

const displayUsers = computed(() =>
  isCreate.value ? state.localUsers : props.policyUsers
);

// In CREATE mode, filter out already-selected agents
const availableAgents = computed(() => {
  if (!isCreate.value) return props.agentList;
  const selectedIds = new Set(state.localUsers.map(u => u.id));
  return props.agentList.filter(a => !selectedIds.has(a.id));
});

const totalCapacity = computed(() =>
  state.inboxCapacityLimits.reduce((sum, l) => sum + (l.conversationLimit || 0), 0)
);

// ── Handlers ─────────────────────────────────────────────────────────────────

const handleValidationChange = validation => {
  validationState.value = validation;
  emit('validationChange', validation);
};

// Inbox limits — local in CREATE, emit events in EDIT
const handleAddInboxLimit = limit => {
  if (isCreate.value) {
    state.inboxCapacityLimits.push({
      id: limit.inboxId,       // use inboxId as temp key (no DB id yet)
      inboxId: limit.inboxId,
      conversationLimit: limit.conversationLimit,
    });
  } else {
    emit('addInboxLimit', limit);
  }
};

const handleDeleteInboxLimit = id => {
  if (isCreate.value) {
    const idx = state.inboxCapacityLimits.findIndex(l => l.id === id);
    if (idx !== -1) state.inboxCapacityLimits.splice(idx, 1);
  } else {
    emit('deleteInboxLimit', id);
  }
};

const handleLimitChange = limit => {
  if (!isCreate.value) {
    emit('updateInboxLimit', limit);
  }
  // In CREATE mode the v-model.number in InboxCapacityLimits mutates directly
};

// Users — local in CREATE, emit events in EDIT
const handleAddUser = agent => {
  if (isCreate.value) {
    state.localUsers.push(agent);
  } else {
    emit('addUser', agent);
  }
};

const handleDeleteUser = agentId => {
  if (isCreate.value) {
    const idx = state.localUsers.findIndex(u => u.id === agentId);
    if (idx !== -1) state.localUsers.splice(idx, 1);
  } else {
    emit('deleteUser', agentId);
  }
};

const resetForm = () => {
  Object.assign(state, {
    name: '',
    description: '',
    exclusionRules: { excludedLabels: [], excludeOlderThanHours: null },
    inboxCapacityLimits: [],
    localUsers: [],
  });
};

const handleSubmit = () => {
  const payload = {
    name: state.name,
    description: state.description,
    exclusionRules: { ...state.exclusionRules },
    inboxCapacityLimits: [...state.inboxCapacityLimits],
  };

  if (isCreate.value) {
    payload.inboxLimits = state.inboxCapacityLimits.map(l => ({
      inboxId: l.inboxId,
      conversationLimit: l.conversationLimit,
    }));
    payload.agentIds = state.localUsers.map(u => u.id);
  }

  emit('submit', payload);
};

watch(
  () => props.initialData,
  newData => {
    Object.assign(state, { ...newData, localUsers: [] });
    if (!isCreate.value) capture();
  },
  { immediate: true, deep: true }
);

defineExpose({ resetForm });
</script>

<template>
  <form @submit.prevent="handleSubmit">
    <div class="flex flex-col gap-4 mb-2 divide-y divide-n-weak">
      <!-- Base info + exclusion rules -->
      <BaseInfo
        v-model:policy-name="state.name"
        v-model:description="state.description"
        :name-label="t(`${BASE_KEY}.FORM.NAME.LABEL`)"
        :name-placeholder="t(`${BASE_KEY}.FORM.NAME.PLACEHOLDER`)"
        :description-label="t(`${BASE_KEY}.FORM.DESCRIPTION.LABEL`)"
        :description-placeholder="t(`${BASE_KEY}.FORM.DESCRIPTION.PLACEHOLDER`)"
        @validation-change="handleValidationChange"
      />
      <ExclusionRules
        v-model:excluded-labels="state.exclusionRules.excludedLabels"
        v-model:exclude-older-than-minutes="state.exclusionRules.excludeOlderThanHours"
        :tags-list="labelList"
      />

      <!-- Inbox capacity limits — always visible -->
      <InboxCapacityLimits
        v-model:inbox-capacity-limits="state.inboxCapacityLimits"
        :inbox-list="inboxList"
        :is-fetching="isInboxesLoading"
        @delete="handleDeleteInboxLimit"
        @add="handleAddInboxLimit"
        @update="handleLimitChange"
      />

      <!-- Agents — always visible -->
      <div class="py-4 flex-col flex gap-4">
        <div class="flex items-end gap-4 w-full justify-between">
          <div class="flex flex-col items-start gap-1 py-1">
            <label class="text-sm font-medium text-n-slate-12 py-1">
              {{ t(`${BASE_KEY}.FORM.USERS.LABEL`) }}
            </label>
            <p class="mb-0 text-n-slate-11 text-sm">
              {{ t(`${BASE_KEY}.FORM.USERS.DESCRIPTION`) }}
            </p>
          </div>
          <AddDataDropdown
            :label="t(`${BASE_KEY}.FORM.USERS.ADD_BUTTON`)"
            :search-placeholder="t(`${BASE_KEY}.FORM.USERS.DROPDOWN.SEARCH_PLACEHOLDER`)"
            :items="availableAgents"
            @add="handleAddUser"
          />
        </div>
        <DataTable
          :items="displayUsers"
          :is-fetching="!isCreate && isUsersLoading"
          :empty-state-message="t(`${BASE_KEY}.FORM.USERS.EMPTY_STATE`)"
          @delete="handleDeleteUser"
        />
      </div>

      <!-- Summary (CREATE only) -->
      <div v-if="isCreate" class="py-4 flex flex-col gap-2">
        <p class="text-sm font-medium text-n-slate-12">
          {{ t(`${BASE_KEY}.FORM.SUMMARY.TITLE`) }}
        </p>
        <div class="flex flex-wrap gap-4 text-sm text-n-slate-11">
          <span>
            {{ t(`${BASE_KEY}.FORM.SUMMARY.INBOXES`, { count: state.inboxCapacityLimits.length }) }}
          </span>
          <span>
            {{ t(`${BASE_KEY}.FORM.SUMMARY.AGENTS`, { count: state.localUsers.length }) }}
          </span>
          <span>
            {{ t(`${BASE_KEY}.FORM.SUMMARY.CAPACITY`, { total: totalCapacity }) }}
          </span>
        </div>
      </div>
    </div>

    <Button
      type="submit"
      :label="buttonLabel"
      :disabled="!validationState.isValid || isLoading || (!isCreate && !isDirty)"
      :is-loading="isLoading"
    />
  </form>
</template>
