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

const flowId = computed(() =>
  route.params.flowId ? Number(route.params.flowId) : null
);
const isEdit = computed(() => !!flowId.value);

const name = ref('');
const requireReason = ref(false);
const active = ref(true);
const wonReasons = ref([]);
const lostReasons = ref([]);
const removedReasonIds = ref([]);
const selectedInboxIds = ref([]);
const isSaving = ref(false);
const isLoading = ref(false);

const populate = flow => {
  if (!flow) return;
  name.value = flow.name || '';
  requireReason.value = !!flow.require_reason;
  active.value = flow.active ?? true;
  selectedInboxIds.value = [...(flow.inbox_ids || [])];
  const reasons = flow.reasons || [];
  const byResult = result =>
    reasons
      .filter(r => r.result === result)
      .sort((a, b) => a.position - b.position)
      .map(r => ({ id: r.id, label: r.label }));
  wonReasons.value = byResult('won');
  lostReasons.value = byResult('lost');
};

onMounted(async () => {
  store.dispatch('inboxes/get');
  if (!isEdit.value) return;
  isLoading.value = true;
  try {
    await store.dispatch('operationalFlows/show', flowId.value);
    populate(getFlow.value(flowId.value));
  } finally {
    isLoading.value = false;
  }
});

const addReason = list => {
  list.push({ label: '' });
};

const removeReason = (list, index) => {
  const [removed] = list.splice(index, 1);
  if (removed?.id) removedReasonIds.value.push(removed.id);
};

const buildReasonsAttributes = () => {
  const rows = [];
  const append = (list, result) => {
    list.forEach((reason, position) => {
      if (!reason.label.trim()) return;
      rows.push({
        ...(reason.id ? { id: reason.id } : {}),
        result,
        label: reason.label.trim(),
        position,
        active: true,
      });
    });
  };
  append(wonReasons.value, 'won');
  append(lostReasons.value, 'lost');
  removedReasonIds.value.forEach(id => rows.push({ id, _destroy: true }));
  return rows;
};

const save = async () => {
  if (!name.value.trim()) return;
  isSaving.value = true;
  const payload = {
    name: name.value.trim(),
    require_reason: requireReason.value,
    active: active.value,
    inbox_ids: selectedInboxIds.value,
    reasons_attributes: buildReasonsAttributes(),
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
    router.push({ name: 'settings_operational_flows_list' });
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

      <div
        class="flex items-center justify-between py-2 px-3 rounded-lg bg-n-alpha-2"
      >
        <div class="flex flex-col">
          <span class="text-sm font-medium text-n-slate-12">
            {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIRE_REASON.LABEL') }}
          </span>
          <span class="text-xs text-n-slate-11">
            {{ $t('OPERATIONAL_FLOWS_SETTINGS.FORM.REQUIRE_REASON.HELP') }}
          </span>
        </div>
        <Switch v-model="requireReason" />
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
        v-for="group in [
          {
            key: 'won',
            list: wonReasons,
            label: $t('OPERATIONAL_FLOWS_SETTINGS.FORM.WON_REASONS'),
          },
          {
            key: 'lost',
            list: lostReasons,
            label: $t('OPERATIONAL_FLOWS_SETTINGS.FORM.LOST_REASONS'),
          },
        ]"
        :key="group.key"
        class="flex flex-col gap-2"
      >
        <label class="text-sm font-medium text-n-slate-12">{{
          group.label
        }}</label>
        <div
          v-for="(reason, index) in group.list"
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
            @click="removeReason(group.list, index)"
          />
        </div>
        <Button
          faded
          slate
          size="sm"
          icon="i-lucide-plus"
          :label="$t('OPERATIONAL_FLOWS_SETTINGS.FORM.ADD_REASON')"
          @click="addReason(group.list)"
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
          class="flex flex-col gap-1 border border-n-weak rounded-xl p-3 max-h-60 overflow-y-auto"
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
            !name.trim() || isSaving || uiFlags.isCreating || uiFlags.isUpdating
          "
          :is-loading="isSaving"
          @click="save"
        />
      </div>
    </template>
  </div>
</template>
