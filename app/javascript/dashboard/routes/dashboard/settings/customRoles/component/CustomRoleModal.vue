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
const scopeSearch = ref('');

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
  scopeSearch.value = '';
});

const scopeItems = computed(() => {
  const list = scopeType.value === 'inboxes' ? inboxList.value : teamList.value;
  const q = scopeSearch.value.toLowerCase();
  if (!q) return list;
  return list.filter(item => item.name.toLowerCase().includes(q));
});

const toggleScopeId = id => {
  if (scopeIds.value.includes(id)) {
    scopeIds.value = scopeIds.value.filter(x => x !== id);
  } else {
    scopeIds.value = [...scopeIds.value, id];
  }
};

const scopeItemName = id => {
  const list = scopeType.value === 'inboxes' ? inboxList.value : teamList.value;
  return list.find(item => item.id === id)?.name ?? id;
};

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

        <template v-if="scopeType !== 'all'">
          <!-- Search -->
          <div class="relative mb-2">
            <span
              class="absolute left-2.5 top-1/2 -translate-y-1/2 i-lucide-search text-n-slate-9 text-sm pointer-events-none"
            />
            <input
              v-model="scopeSearch"
              type="text"
              :placeholder="scopeType === 'inboxes' ? 'Buscar caixa...' : 'Buscar time...'"
              class="w-full pl-8 pr-3 py-2 text-sm rounded-lg border border-n-weak bg-n-solid-2 text-n-slate-12 placeholder:text-n-slate-9 focus:outline-none focus:border-n-brand-8"
            />
          </div>

          <!-- Checkable list -->
          <div class="rounded-lg border border-n-weak max-h-40 overflow-y-auto">
            <label
              v-for="item in scopeItems"
              :key="item.id"
              class="flex items-center gap-2 px-3 py-2 cursor-pointer hover:bg-n-slate-1 border-b border-n-weak/50 last:border-0"
            >
              <input
                type="checkbox"
                :checked="scopeIds.includes(item.id)"
                class="rounded shrink-0"
                @change="toggleScopeId(item.id)"
              />
              <span class="text-sm text-n-slate-12 select-none">{{ item.name }}</span>
            </label>
            <div
              v-if="scopeItems.length === 0"
              class="px-3 py-3 text-sm text-n-slate-10 text-center"
            >
              Nenhum item encontrado
            </div>
          </div>

          <!-- Selected tags -->
          <div v-if="scopeIds.length > 0" class="flex flex-wrap gap-1.5 mt-2">
            <span
              v-for="id in scopeIds"
              :key="id"
              class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs bg-n-brand-3 text-n-brand-11"
            >
              {{ scopeItemName(id) }}
              <button
                type="button"
                class="i-lucide-x text-xs leading-none"
                @click="toggleScopeId(id)"
              />
            </span>
          </div>
        </template>
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
