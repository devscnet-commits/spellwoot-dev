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

const emptyForm = () => ({
  id: null,
  operational_flow_id: null,
  team_id: '',
  excluded_inbox_ids: [],
});

const form = ref(emptyForm());
const showForm = ref(false);
const loadingRow = ref({});

onMounted(() => {
  store.dispatch('flowAssignmentRules/get');
  store.dispatch('operationalFlows/get');
  store.dispatch('inboxes/get');
  store.dispatch('teams/get');
});

const nameById = (list, id) => list.find(item => item.id === id)?.name || '';
const flowName = id => nameById(flows.value, id);

// Caixas that belong to the selected team — offered for exclusion. New caixas added to the
// team later are NOT excluded by default, so they auto-join the flow (dynamic behavior).
const teamInboxes = computed(() => {
  const team = teams.value.find(tm => tm.id === Number(form.value.team_id));
  const ids = team?.inbox_ids || [];
  return inboxes.value.filter(inbox => ids.includes(inbox.id));
});

const isExcluded = id => form.value.excluded_inbox_ids.includes(id);
const toggleExcluded = id => {
  form.value.excluded_inbox_ids = isExcluded(id)
    ? form.value.excluded_inbox_ids.filter(x => x !== id)
    : [...form.value.excluded_inbox_ids, id];
};

// Compact summary for the rule list: "Time X" (+ "exceto: A, B").
const summarizePredicate = predicate => {
  if (!predicate.team_id) {
    return t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.ANY_CONVERSATION');
  }
  const base = `${t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.DIMENSIONS.TEAM')}: ${nameById(teams.value, Number(predicate.team_id))}`;
  const excluded = (predicate.excluded_inbox_ids || [])
    .map(id => nameById(inboxes.value, Number(id)))
    .filter(Boolean);
  if (!excluded.length) return base;
  return `${base} (${t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.EXCEPT')} ${excluded.join(', ')})`;
};

const predicateSummary = rule => summarizePredicate(rule.predicate || {});

const openCreate = () => {
  form.value = emptyForm();
  showForm.value = true;
};

const openEdit = rule => {
  const predicate = rule.predicate || {};
  form.value = {
    id: rule.id,
    operational_flow_id: rule.operational_flow_id,
    team_id: predicate.team_id || '',
    excluded_inbox_ids: (predicate.excluded_inbox_ids || []).map(Number),
  };
  showForm.value = true;
};

const closeForm = () => {
  showForm.value = false;
  form.value = emptyForm();
};

const buildPredicate = () => {
  const predicate = {};
  if (form.value.team_id) predicate.team_id = form.value.team_id;
  // Only keep exclusions that still belong to the selected team.
  const excluded = form.value.excluded_inbox_ids.filter(id =>
    teamInboxes.value.some(inbox => inbox.id === id)
  );
  if (excluded.length) predicate.excluded_inbox_ids = excluded;
  return predicate;
};

// Live, natural-language description of the rule being built.
const tr = (key, args) =>
  t(`OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.HUMAN.${key}`, args);

const humanSummary = computed(() => {
  if (!form.value.operational_flow_id) return '';
  const apply = tr('APPLY', { flow: flowName(form.value.operational_flow_id) });
  if (!form.value.team_id) return `${apply} ${tr('ANY')}`;
  let sentence = `${apply} ${tr('WHEN')} ${tr('TEAM', { name: nameById(teams.value, Number(form.value.team_id)) })}`;
  const excluded = teamInboxes.value
    .filter(inbox => isExcluded(inbox.id))
    .map(inbox => inbox.name);
  if (excluded.length) {
    sentence += ` ${tr('EXCEPT_CAIXAS', { names: excluded.join(', ') })}`;
  }
  return `${sentence}.`;
});

const save = async () => {
  if (!form.value.operational_flow_id) return;
  const predicate = buildPredicate();
  // The most specific rule wins automatically: more conditions => lower priority number =>
  // evaluated first. No manual priority needed.
  const priority = 3 - Object.keys(predicate).length;
  const payload = {
    operational_flow_id: form.value.operational_flow_id,
    predicate,
    priority,
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
  <div
    class="flex flex-col gap-4 outline-1 outline outline-n-container rounded-xl bg-n-solid-2 p-5"
  >
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
          <div class="flex flex-col gap-1">
            <span class="text-sm text-n-slate-12">
              {{ predicateSummary(rule) }}
              <span class="text-n-slate-11">→</span>
              <span class="font-medium">{{
                flowName(rule.operational_flow_id)
              }}</span>
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

      <p class="text-xs text-n-slate-11">
        {{ $t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.FORM.CONDITIONS_INTRO') }}
      </p>

      <!-- Primary dimension: the team decides the flow -->
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

      <!-- Exclude caixas of the team (all included by default → dynamic) -->
      <div
        v-if="form.team_id && teamInboxes.length"
        class="flex flex-col gap-1"
      >
        <label class="text-xs font-medium text-n-slate-11">
          {{ $t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.FORM.EXCLUDE_CAIXAS_LABEL') }}
        </label>
        <p class="text-xs text-n-slate-11">
          {{ $t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.FORM.EXCLUDE_CAIXAS_HELP') }}
        </p>
        <div class="flex flex-col gap-1 border border-n-weak rounded-lg p-3 mt-1">
          <label
            v-for="inbox in teamInboxes"
            :key="inbox.id"
            class="flex items-center gap-2 py-1 cursor-pointer"
          >
            <input
              type="checkbox"
              :checked="isExcluded(inbox.id)"
              @change="toggleExcluded(inbox.id)"
            />
            <span
              class="text-sm"
              :class="
                isExcluded(inbox.id)
                  ? 'text-n-slate-9 line-through'
                  : 'text-n-slate-12'
              "
            >
              {{ inbox.name }}
            </span>
          </label>
        </div>
      </div>

      <!-- Natural-language summary of the rule being built -->
      <div class="rounded-lg bg-n-alpha-2 px-3 py-2 text-sm">
        <p class="text-xs font-medium text-n-slate-11 mb-1">
          {{ $t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.HUMAN.MEANS') }}
        </p>
        <p class="text-n-slate-12">
          {{
            humanSummary ||
            $t('OPERATIONAL_FLOWS_SETTINGS.ASSIGNMENT_RULES.HUMAN.PICK_FLOW')
          }}
        </p>
      </div>

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
