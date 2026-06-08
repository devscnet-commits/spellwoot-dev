<script setup>
import { computed, onMounted, ref } from 'vue';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useAdmin } from 'dashboard/composables/useAdmin';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

const store = useStore();
const { t } = useI18n();
const { isAdmin } = useAdmin();

const rules = useMapGetter('flowAssignmentRules/getRules');
const uiFlags = useMapGetter('flowAssignmentRules/getUIFlags');
const flows = useMapGetter('operationalFlows/getFlows');
const inboxes = useMapGetter('inboxes/getInboxes');
const teams = useMapGetter('teams/getTeams');
const roles = useMapGetter('customRole/getCustomRoles');

const emptyForm = () => ({
  id: null,
  operational_flow_id: null,
  role_id: '',
  inbox_id: '',
  team_id: '',
  conversation_origin: '',
  priority: 0,
  is_default: false,
});

const form = ref(emptyForm());
const showForm = ref(false);
const loadingRow = ref({});

onMounted(() => {
  store.dispatch('flowAssignmentRules/get');
  store.dispatch('operationalFlows/get');
  store.dispatch('inboxes/get');
  store.dispatch('teams/get');
  store.dispatch('customRole/getCustomRole');
});

const nameById = (list, id) => list.find(item => item.id === id)?.name || '';
const flowName = id => nameById(flows.value, id);

// Human-readable summary of the predicate dimensions that are set on a rule.
const predicateSummary = rule => {
  const predicate = rule.predicate || {};
  const parts = [];
  if (predicate.role_id) {
    parts.push(
      `${t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.DIMENSIONS.ROLE')}: ${nameById(roles.value, Number(predicate.role_id))}`
    );
  }
  if (predicate.inbox_id) {
    parts.push(
      `${t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.DIMENSIONS.INBOX')}: ${nameById(inboxes.value, Number(predicate.inbox_id))}`
    );
  }
  if (predicate.team_id) {
    parts.push(
      `${t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.DIMENSIONS.TEAM')}: ${nameById(teams.value, Number(predicate.team_id))}`
    );
  }
  if (predicate.conversation_origin) {
    parts.push(
      `${t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.DIMENSIONS.ORIGIN')}: ${predicate.conversation_origin}`
    );
  }
  return parts.length
    ? parts.join(' · ')
    : t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.ANY');
};

const openCreate = () => {
  form.value = emptyForm();
  showForm.value = true;
};

const openEdit = rule => {
  const predicate = rule.predicate || {};
  form.value = {
    id: rule.id,
    operational_flow_id: rule.operational_flow_id,
    role_id: predicate.role_id || '',
    inbox_id: predicate.inbox_id || '',
    team_id: predicate.team_id || '',
    conversation_origin: predicate.conversation_origin || '',
    priority: rule.priority,
    is_default: rule.is_default,
  };
  showForm.value = true;
};

const closeForm = () => {
  showForm.value = false;
  form.value = emptyForm();
};

const buildPredicate = () => {
  const predicate = {};
  if (form.value.role_id) predicate.role_id = form.value.role_id;
  if (form.value.inbox_id) predicate.inbox_id = form.value.inbox_id;
  if (form.value.team_id) predicate.team_id = form.value.team_id;
  if (form.value.conversation_origin) {
    predicate.conversation_origin = form.value.conversation_origin.trim();
  }
  return predicate;
};

const save = async () => {
  if (!form.value.operational_flow_id) return;
  const payload = {
    operational_flow_id: form.value.operational_flow_id,
    predicate: buildPredicate(),
    priority: Number(form.value.priority) || 0,
    is_default: form.value.is_default,
  };
  try {
    if (form.value.id) {
      await store.dispatch('flowAssignmentRules/update', {
        id: form.value.id,
        ...payload,
      });
    } else {
      await store.dispatch('flowAssignmentRules/create', payload);
    }
    useAlert(t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.SAVE_SUCCESS'));
    closeForm();
  } catch (error) {
    useAlert(t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.SAVE_ERROR'));
  }
};

const remove = async rule => {
  try {
    loadingRow.value[rule.id] = true;
    await store.dispatch('flowAssignmentRules/delete', rule.id);
    useAlert(t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.DELETE_SUCCESS'));
  } catch (error) {
    useAlert(t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.SAVE_ERROR'));
  } finally {
    loadingRow.value[rule.id] = false;
  }
};

const canSave = computed(() => !!form.value.operational_flow_id);
</script>

<template>
  <div class="flex flex-col gap-4">
    <div class="flex items-start justify-between gap-4">
      <div class="flex flex-col gap-1">
        <h3 class="text-base font-medium text-n-slate-12">
          {{ $t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.HEADER') }}
        </h3>
        <p class="text-sm text-n-slate-11">
          {{ $t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.DESCRIPTION') }}
        </p>
      </div>
      <Button
        v-if="isAdmin"
        :label="$t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.NEW_RULE')"
        size="sm"
        @click="openCreate"
      />
    </div>

    <div v-if="uiFlags.isFetching" class="flex justify-center py-6">
      <Spinner class="text-n-brand" />
    </div>

    <p
      v-else-if="!rules.length && !showForm"
      class="py-6 text-sm text-center text-n-slate-11"
    >
      {{ $t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.EMPTY') }}
    </p>

    <div
      v-else-if="rules.length"
      class="divide-y divide-n-weak border-t border-n-weak"
    >
      <div
        v-for="rule in rules"
        :key="rule.id"
        class="flex justify-between flex-row items-start gap-4 py-3"
      >
        <div class="flex items-start gap-3">
          <span
            class="px-1.5 py-0.5 text-xs font-mono rounded text-n-slate-11 bg-n-alpha-2 mt-0.5"
          >
            #{{ rule.priority }}
          </span>
          <div class="flex flex-col gap-1">
            <span class="text-sm text-n-slate-12">
              {{ predicateSummary(rule) }}
              <span class="text-n-slate-11">→</span>
              <span class="font-medium">{{
                flowName(rule.operational_flow_id)
              }}</span>
            </span>
            <span
              v-if="rule.is_default"
              class="text-xs px-1.5 py-0.5 rounded-full font-medium bg-n-slate-3 text-n-slate-11 w-fit"
            >
              {{ $t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.DEFAULT') }}
            </span>
          </div>
        </div>
        <div v-if="isAdmin" class="flex justify-end gap-2">
          <Button icon="i-woot-settings" slate sm @click="openEdit(rule)" />
          <Button
            icon="i-woot-bin"
            slate
            sm
            class="hover:enabled:text-n-ruby-11 hover:enabled:bg-n-ruby-2"
            :is-loading="loadingRow[rule.id]"
            @click="remove(rule)"
          />
        </div>
      </div>
    </div>

    <div
      v-if="showForm"
      class="flex flex-col gap-3 border border-n-weak rounded-xl p-4"
    >
      <div class="flex flex-col gap-1">
        <label class="text-xs font-medium text-n-slate-11">
          {{ $t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.FORM.FLOW') }}
        </label>
        <select
          v-model="form.operational_flow_id"
          class="w-full px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
        >
          <option :value="null" disabled>
            {{ $t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.FORM.SELECT') }}
          </option>
          <option v-for="flow in flows" :key="flow.id" :value="flow.id">
            {{ flow.name }}
          </option>
        </select>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div class="flex flex-col gap-1">
          <label class="text-xs font-medium text-n-slate-11">
            {{ $t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.DIMENSIONS.ROLE') }}
          </label>
          <select
            v-model="form.role_id"
            class="w-full px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
          >
            <option value="">
              {{ $t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.ANY') }}
            </option>
            <option v-for="role in roles" :key="role.id" :value="role.id">
              {{ role.name }}
            </option>
          </select>
        </div>
        <div class="flex flex-col gap-1">
          <label class="text-xs font-medium text-n-slate-11">
            {{
              $t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.DIMENSIONS.INBOX')
            }}
          </label>
          <select
            v-model="form.inbox_id"
            class="w-full px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
          >
            <option value="">
              {{ $t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.ANY') }}
            </option>
            <option v-for="inbox in inboxes" :key="inbox.id" :value="inbox.id">
              {{ inbox.name }}
            </option>
          </select>
        </div>
        <div class="flex flex-col gap-1">
          <label class="text-xs font-medium text-n-slate-11">
            {{ $t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.DIMENSIONS.TEAM') }}
          </label>
          <select
            v-model="form.team_id"
            class="w-full px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
          >
            <option value="">
              {{ $t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.ANY') }}
            </option>
            <option v-for="team in teams" :key="team.id" :value="team.id">
              {{ team.name }}
            </option>
          </select>
        </div>
        <div class="flex flex-col gap-1">
          <label class="text-xs font-medium text-n-slate-11">
            {{ $t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.PRIORITY') }}
          </label>
          <input
            v-model="form.priority"
            type="number"
            class="w-full px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
          />
        </div>
      </div>

      <p class="text-xs text-n-slate-11">
        {{ $t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.PRIORITY_HELP') }}
      </p>

      <div class="flex justify-end gap-2">
        <Button
          :label="$t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.FORM.CANCEL')"
          variant="ghost"
          slate
          size="sm"
          @click="closeForm"
        />
        <Button
          :label="$t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.FORM.SAVE')"
          size="sm"
          :disabled="!canSave || uiFlags.isCreating || uiFlags.isUpdating"
          @click="save"
        />
      </div>
    </div>
  </div>
</template>
