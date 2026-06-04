<script setup>
import { ref, reactive, computed, onMounted, watch } from 'vue';
import { useStore } from 'dashboard/composables/store';
import { useMapGetter } from 'dashboard/composables/store';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { required, minLength } from '@vuelidate/validators';
import { useAlert } from 'dashboard/composables';
import {
  AVAILABLE_CUSTOM_ROLE_PERMISSIONS,
  MANAGE_ALL_CONVERSATION_PERMISSIONS,
  CONVERSATION_UNASSIGNED_PERMISSIONS,
  CONVERSATION_PARTICIPATING_PERMISSIONS,
} from 'dashboard/constants/permissions.js';

import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  mode: {
    type: String,
    default: 'add',
    validator: value => ['add', 'edit'].includes(value),
  },
  selectedRole: {
    type: Object,
    default: () => ({}),
  },
});

const emit = defineEmits(['close']);

const store = useStore();
const { t } = useI18n();

const inboxList = useMapGetter('inboxes/getInboxes');
const teamList = useMapGetter('teams/getTeams');

const name = ref('');
const description = ref('');
const selectedPermissions = ref([]);
const scopeType = ref('all');
const scopeIds = ref([]);

const nameInput = ref(null);

const addCustomRole = reactive({
  showLoading: false,
  message: '',
});

const rules = computed(() => ({
  name: { required, minLength: minLength(2) },
  description: { required },
  selectedPermissions: { required, minLength: minLength(1) },
}));

const v$ = useVuelidate(rules, { name, description, selectedPermissions });

const resetForm = () => {
  name.value = '';
  description.value = '';
  selectedPermissions.value = [];
  scopeType.value = 'all';
  scopeIds.value = [];
  v$.value.$reset();
};

const populateEditForm = () => {
  name.value = props.selectedRole.name || '';
  description.value = props.selectedRole.description || '';
  selectedPermissions.value = props.selectedRole.permissions || [];
  scopeType.value = props.selectedRole.scope_type || 'all';
  scopeIds.value = props.selectedRole.scope_ids || [];
};

watch(
  selectedPermissions,
  (newValue, oldValue) => {
    // Check if manage all conversation permission is added or removed
    const hasAddedManageAllConversation =
      newValue.includes(MANAGE_ALL_CONVERSATION_PERMISSIONS) &&
      !oldValue.includes(MANAGE_ALL_CONVERSATION_PERMISSIONS);
    const hasRemovedManageAllConversation =
      oldValue.includes(MANAGE_ALL_CONVERSATION_PERMISSIONS) &&
      !newValue.includes(MANAGE_ALL_CONVERSATION_PERMISSIONS);

    if (hasAddedManageAllConversation) {
      // If manage all conversation permission is added,
      // then add unassigned and participating permissions automatically
      selectedPermissions.value = [
        ...new Set([
          ...selectedPermissions.value,
          CONVERSATION_UNASSIGNED_PERMISSIONS,
          CONVERSATION_PARTICIPATING_PERMISSIONS,
        ]),
      ];
    } else if (hasRemovedManageAllConversation) {
      // If manage all conversation permission is removed,
      // then only remove manage all conversation permission
      selectedPermissions.value = selectedPermissions.value.filter(
        p => p !== MANAGE_ALL_CONVERSATION_PERMISSIONS
      );
    }
  },
  { deep: true }
);

onMounted(() => {
  if (props.mode === 'edit') {
    populateEditForm();
  }
  // Focus the name input when mounted
  nameInput.value?.focus();
});

const getTranslationKey = base => {
  return props.mode === 'edit'
    ? `CUSTOM_ROLE.EDIT.${base}`
    : `CUSTOM_ROLE.ADD.${base}`;
};

const modalTitle = computed(() => t(getTranslationKey('TITLE')));
const modalDescription = computed(() => t(getTranslationKey('DESC')));
const submitButtonText = computed(() => t(getTranslationKey('SUBMIT')));

watch(scopeType, () => {
  scopeIds.value = [];
});

const handleCustomRole = async () => {
  v$.value.$touch();
  if (v$.value.$invalid) return;

  addCustomRole.showLoading = true;
  try {
    const roleData = {
      name: name.value,
      description: description.value,
      permissions: selectedPermissions.value,
      scope_type: scopeType.value,
      scope_ids: scopeType.value === 'all' ? [] : scopeIds.value.map(Number),
    };

    if (props.mode === 'edit') {
      await store.dispatch('customRole/updateCustomRole', {
        id: props.selectedRole.id,
        ...roleData,
      });
      useAlert(t('CUSTOM_ROLE.EDIT.API.SUCCESS_MESSAGE'));
    } else {
      await store.dispatch('customRole/createCustomRole', roleData);
      useAlert(t('CUSTOM_ROLE.ADD.API.SUCCESS_MESSAGE'));
    }

    resetForm();
    emit('close');
  } catch (error) {
    const errorMessage =
      error?.message || t(`CUSTOM_ROLE.FORM.API.ERROR_MESSAGE`);
    useAlert(errorMessage);
  } finally {
    addCustomRole.showLoading = false;
  }
};

const isSubmitDisabled = computed(
  () => v$.value.$invalid || addCustomRole.showLoading
);
</script>

<template>
  <div class="flex flex-col h-auto overflow-auto">
    <woot-modal-header
      :header-title="modalTitle"
      :header-content="modalDescription"
    />
    <form class="flex flex-col w-full" @submit.prevent="handleCustomRole">
      <div class="w-full">
        <label :class="{ error: v$.name.$error }">
          {{ $t('CUSTOM_ROLE.FORM.NAME.LABEL') }}
          <input
            ref="nameInput"
            v-model.trim="name"
            type="text"
            :placeholder="$t('CUSTOM_ROLE.FORM.NAME.PLACEHOLDER')"
            @blur="v$.name.$touch"
          />
        </label>
      </div>

      <div class="w-full">
        <label :class="{ error: v$.description.$error }">
          {{ $t('CUSTOM_ROLE.FORM.DESCRIPTION.LABEL') }}

          <textarea
            v-model="description"
            :rows="3"
            :placeholder="$t('CUSTOM_ROLE.FORM.DESCRIPTION.PLACEHOLDER')"
            @blur="v$.description.$touch"
          />
        </label>
      </div>

      <div class="w-full">
        <label :class="{ 'text-n-ruby-9': v$.selectedPermissions.$error }">
          {{ $t('CUSTOM_ROLE.FORM.PERMISSIONS.LABEL') }}
        </label>
        <div class="flex flex-col gap-2.5 mb-4 mt-2">
          <div
            v-for="permission in AVAILABLE_CUSTOM_ROLE_PERMISSIONS"
            :key="permission"
            class="flex items-center"
          >
            <input
              :id="permission"
              v-model="selectedPermissions"
              type="checkbox"
              :value="permission"
              name="permissions"
              class="ltr:mr-2 rtl:ml-2"
            />
            <label :for="permission" class="text-sm font-normal">
              {{ $t(`CUSTOM_ROLE.PERMISSIONS.${permission.toUpperCase()}`) }}
            </label>
          </div>
        </div>
      </div>

      <!-- Scope de acesso -->
      <div class="w-full mt-2">
        <p class="text-sm font-medium text-n-slate-12 mb-2">Escopo de acesso</p>
        <div class="flex flex-col gap-2 mb-3">
          <label
            v-for="opt in [
              { value: 'all',     label: 'Todas as caixas' },
              { value: 'inboxes', label: 'Caixas específicas' },
              { value: 'teams',   label: 'Times específicos' },
            ]"
            :key="opt.value"
            class="flex items-center gap-2 cursor-pointer"
          >
            <input
              v-model="scopeType"
              type="radio"
              :value="opt.value"
              name="scope_type"
              class="ltr:mr-1 rtl:ml-1"
            />
            <span class="text-sm font-normal text-n-slate-12">{{ opt.label }}</span>
          </label>
        </div>

        <select
          v-if="scopeType === 'inboxes'"
          v-model="scopeIds"
          multiple
          class="w-full border border-n-weak rounded-lg px-2 py-1.5 text-sm text-n-slate-12 bg-n-solid-2 min-h-[110px]"
        >
          <option
            v-for="inbox in inboxList"
            :key="inbox.id"
            :value="inbox.id"
          >
            {{ inbox.name }}
          </option>
        </select>

        <select
          v-if="scopeType === 'teams'"
          v-model="scopeIds"
          multiple
          class="w-full border border-n-weak rounded-lg px-2 py-1.5 text-sm text-n-slate-12 bg-n-solid-2 min-h-[110px]"
        >
          <option
            v-for="team in teamList"
            :key="team.id"
            :value="team.id"
          >
            {{ team.name }}
          </option>
        </select>

        <p
          v-if="scopeType !== 'all'"
          class="text-xs text-n-slate-11 mt-1"
        >
          Segure Ctrl / Cmd para selecionar múltiplos itens.
        </p>
      </div>

      <div class="flex flex-row justify-end w-full gap-2 px-0 py-2">
        <Button
          faded
          slate
          type="reset"
          :label="$t('CUSTOM_ROLE.FORM.CANCEL_BUTTON_TEXT')"
          @click.prevent="emit('close')"
        />
        <Button
          type="submit"
          :label="submitButtonText"
          :disabled="isSubmitDisabled"
          :is-loading="addCustomRole.showLoading"
        />
      </div>
    </form>
  </div>
</template>
