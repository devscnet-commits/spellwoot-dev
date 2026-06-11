<script setup>
import { computed, onMounted, ref } from 'vue';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useAdmin } from 'dashboard/composables/useAdmin';
import { useI18n } from 'vue-i18n';

import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import FlowSelect from './FlowSelect.vue';

const store = useStore();
const { t } = useI18n();
const { isAdmin } = useAdmin();

const inboxes = useMapGetter('inboxes/getInboxes');
const flows = useMapGetter('operationalFlows/getFlows');
const uiFlags = useMapGetter('inboxes/getUIFlags');

const savingInboxId = ref(null);

onMounted(() => {
  store.dispatch('inboxes/get');
  store.dispatch('operationalFlows/get');
});

const sortedInboxes = computed(() =>
  [...(inboxes.value || [])].sort((a, b) => a.name.localeCompare(b.name))
);

const flowLabel = flow =>
  flow.active
    ? flow.name
    : `${flow.name} (${t('OPERATIONAL_FLOWS_SETTINGS.CAIXA_FLOWS.INACTIVE')})`;

const updateFlow = async (inbox, value) => {
  savingInboxId.value = inbox.id;
  try {
    await store.dispatch('inboxes/updateInbox', {
      id: inbox.id,
      formData: false,
      operational_flow_id: value || null,
    });
    useAlert(t('OPERATIONAL_FLOWS_SETTINGS.CAIXA_FLOWS.SAVE_SUCCESS'));
  } catch (error) {
    useAlert(t('OPERATIONAL_FLOWS_SETTINGS.CAIXA_FLOWS.SAVE_ERROR'));
  } finally {
    savingInboxId.value = null;
  }
};
</script>

<template>
  <div
    class="flex flex-col gap-4 outline-1 outline outline-n-container rounded-xl bg-n-solid-2 p-5"
  >
    <div class="flex flex-col gap-1">
      <h3 class="text-base font-medium text-n-slate-12">
        {{ $t('OPERATIONAL_FLOWS_SETTINGS.CAIXA_FLOWS.HEADER') }}
      </h3>
      <p class="text-sm text-n-slate-11">
        {{ $t('OPERATIONAL_FLOWS_SETTINGS.CAIXA_FLOWS.DESCRIPTION') }}
      </p>
    </div>

    <div v-if="uiFlags.isFetching" class="flex justify-center py-6">
      <Spinner class="text-n-brand" />
    </div>

    <p
      v-else-if="!sortedInboxes.length"
      class="py-6 text-sm text-center text-n-slate-11"
    >
      {{ $t('OPERATIONAL_FLOWS_SETTINGS.CAIXA_FLOWS.EMPTY') }}
    </p>

    <div v-else class="divide-y divide-n-weak border-t border-n-weak">
      <div
        v-for="inbox in sortedInboxes"
        :key="inbox.id"
        class="flex items-center justify-between gap-4 py-2.5"
      >
        <span class="text-sm text-n-slate-12 min-w-0 truncate">
          {{ inbox.name }}
        </span>
        <div class="flex items-center gap-2 w-64 shrink-0">
          <FlowSelect
            v-if="isAdmin"
            :model-value="inbox.operational_flow_id || ''"
            class="w-full"
            @update:model-value="updateFlow(inbox, $event)"
          >
            <option value="">
              {{ $t('OPERATIONAL_FLOWS_SETTINGS.CAIXA_FLOWS.NONE') }}
            </option>
            <option v-for="flow in flows" :key="flow.id" :value="flow.id">
              {{ flowLabel(flow) }}
            </option>
          </FlowSelect>
          <span v-else class="text-sm text-n-slate-11">
            {{
              flows.find(f => f.id === inbox.operational_flow_id)?.name ||
              $t('OPERATIONAL_FLOWS_SETTINGS.CAIXA_FLOWS.NONE')
            }}
          </span>
          <Spinner v-if="savingInboxId === inbox.id" class="text-n-brand" />
        </div>
      </div>
    </div>
  </div>
</template>
