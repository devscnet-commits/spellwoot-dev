<script setup>
import { computed, onMounted, ref } from 'vue';
import {
  useStore,
  useMapGetter,
  useStoreGetters,
} from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useAdmin } from 'dashboard/composables/useAdmin';
import { useI18n } from 'vue-i18n';

import Icon from 'dashboard/components-next/icon/Icon.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

const store = useStore();
const { t } = useI18n();
const getters = useStoreGetters();
const { isAdmin } = useAdmin();

const loading = ref({});
const flowsList = useMapGetter('operationalFlows/getFlows');
const uiFlags = computed(() => getters['operationalFlows/getUIFlags'].value);

onMounted(() => {
  store.dispatch('operationalFlows/get');
});

const reasonsCount = flow => (flow.reasons || []).length;

const showDeletePopup = ref(false);
const selectedFlow = ref({});

const openDelete = flow => {
  showDeletePopup.value = true;
  selectedFlow.value = flow;
};

const closeDelete = () => {
  showDeletePopup.value = false;
  selectedFlow.value = {};
};

const deleteFlow = async ({ id }) => {
  try {
    loading.value[id] = true;
    await store.dispatch('operationalFlows/delete', id);
    useAlert(t('OPERATIONAL_FLOWS_SETTINGS.DELETE.API.SUCCESS_MESSAGE'));
  } catch (error) {
    useAlert(t('OPERATIONAL_FLOWS_SETTINGS.DELETE.API.ERROR_MESSAGE'));
  } finally {
    loading.value[id] = false;
  }
};

const confirmDeletion = () => {
  deleteFlow(selectedFlow.value);
  closeDelete();
};

const deleteConfirmText = computed(
  () =>
    `${t('OPERATIONAL_FLOWS_SETTINGS.DELETE.CONFIRM.YES')} ${selectedFlow.value.name}`
);
const deleteRejectText = computed(() =>
  t('OPERATIONAL_FLOWS_SETTINGS.DELETE.CONFIRM.NO')
);
const confirmDeleteTitle = computed(() =>
  t('OPERATIONAL_FLOWS_SETTINGS.DELETE.CONFIRM.TITLE', {
    flowName: selectedFlow.value.name,
  })
);
</script>

<template>
  <div
    class="flex flex-col gap-4 outline-1 outline outline-n-container rounded-xl bg-n-solid-2 p-5"
  >
    <div class="flex items-start justify-between gap-4">
      <div class="flex flex-col gap-1">
        <h3 class="text-base font-medium text-n-slate-12">
          {{ $t('OPERATIONAL_FLOWS_SETTINGS.HEADER') }}
        </h3>
        <p class="text-sm text-n-slate-11">
          {{ $t('OPERATIONAL_FLOWS_SETTINGS.DESCRIPTION') }}
        </p>
      </div>
      <router-link
        v-if="isAdmin"
        :to="{ name: 'settings_operational_flows_new' }"
      >
        <Button :label="$t('OPERATIONAL_FLOWS_SETTINGS.NEW_FLOW')" size="sm" />
      </router-link>
    </div>

    <div v-if="uiFlags.isFetching" class="flex justify-center py-6">
      <Spinner class="text-n-brand" />
    </div>

    <p
      v-else-if="!flowsList.length"
      class="py-6 text-sm text-center text-n-slate-11"
    >
      {{ $t('OPERATIONAL_FLOWS_SETTINGS.LIST.404') }}
    </p>

    <div v-else class="divide-y divide-n-weak border-t border-n-weak">
      <div
        v-for="flow in flowsList"
        :key="flow.id"
        class="flex justify-between flex-row items-start gap-4 py-4"
      >
        <div class="flex items-start gap-4">
          <div
            class="flex items-center flex-shrink-0 size-10 justify-center rounded-xl outline outline-1 outline-n-weak -outline-offset-1"
          >
            <Icon icon="i-lucide-workflow" class="size-4 text-n-slate-11" />
          </div>
          <div class="flex flex-col items-start gap-1">
            <span class="block text-heading-3 text-n-slate-12">
              {{ flow.name }}
            </span>
            <div class="flex items-center gap-3 mt-1">
              <span class="flex items-center gap-1 text-xs text-n-slate-11">
                <span class="i-lucide-list size-3" />
                {{
                  $t('OPERATIONAL_FLOWS_SETTINGS.LIST.REASONS_COUNT', {
                    count: reasonsCount(flow),
                  })
                }}
              </span>
              <span
                v-if="flow.require_reason"
                class="text-xs px-1.5 py-0.5 rounded-full font-medium bg-n-amber-3 text-n-amber-11"
              >
                {{ $t('OPERATIONAL_FLOWS_SETTINGS.LIST.REASON_REQUIRED') }}
              </span>
              <span
                v-if="flow.meta_enabled"
                class="text-xs px-1.5 py-0.5 rounded-full font-medium bg-n-blue-3 text-n-blue-11"
              >
                {{ $t('OPERATIONAL_FLOWS_SETTINGS.LIST.META_ON') }}
              </span>
              <span
                class="text-xs px-1.5 py-0.5 rounded-full font-medium"
                :class="[
                  flow.active
                    ? 'bg-n-teal-3 text-n-teal-11'
                    : 'bg-n-slate-3 text-n-slate-11',
                ]"
              >
                {{
                  flow.active
                    ? $t('OPERATIONAL_FLOWS_SETTINGS.LIST.ACTIVE')
                    : $t('OPERATIONAL_FLOWS_SETTINGS.LIST.INACTIVE')
                }}
              </span>
            </div>
          </div>
        </div>
        <div class="flex justify-end gap-3">
          <router-link
            :to="{
              name: 'settings_operational_flows_edit',
              params: { flowId: flow.id },
            }"
          >
            <Button
              v-if="isAdmin"
              v-tooltip.top="$t('OPERATIONAL_FLOWS_SETTINGS.LIST.EDIT_FLOW')"
              icon="i-woot-settings"
              slate
              sm
            />
          </router-link>
          <Button
            v-if="isAdmin"
            v-tooltip.top="$t('OPERATIONAL_FLOWS_SETTINGS.DELETE.BUTTON_TEXT')"
            icon="i-woot-bin"
            slate
            sm
            class="hover:enabled:text-n-ruby-11 hover:enabled:bg-n-ruby-2"
            :is-loading="loading[flow.id]"
            @click="openDelete(flow)"
          />
        </div>
      </div>
    </div>

    <woot-confirm-delete-modal
      v-if="showDeletePopup"
      v-model:show="showDeletePopup"
      :title="confirmDeleteTitle"
      :message="$t('OPERATIONAL_FLOWS_SETTINGS.DELETE.CONFIRM.MESSAGE')"
      :confirm-text="deleteConfirmText"
      :reject-text="deleteRejectText"
      :confirm-value="selectedFlow.name"
      @on-confirm="confirmDeletion"
      @on-close="closeDelete"
    />
  </div>
</template>
