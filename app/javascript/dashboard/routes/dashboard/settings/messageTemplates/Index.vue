<script setup>
import { computed, onMounted, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useStoreGetters, useStore } from 'dashboard/composables/store';
import { INBOX_TYPES } from 'dashboard/helper/inbox';

import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import {
  BaseTable,
  BaseTableRow,
  BaseTableCell,
} from 'dashboard/components-next/table';

const getters = useStoreGetters();
const store = useStore();
const route = useRoute();
const router = useRouter();
const { t } = useI18n();

const selectedInboxId = ref(null);
const templates = ref([]);
const isFetchingTemplates = ref(false);
const fetchError = ref('');

const whatsAppCloudInboxes = computed(() =>
  (getters['inboxes/getInboxes'].value || []).filter(
    inbox =>
      inbox.channel_type === INBOX_TYPES.WHATSAPP &&
      inbox.provider === 'whatsapp_cloud'
  )
);

const inboxOptions = computed(() =>
  whatsAppCloudInboxes.value.map(inbox => ({
    label: `${inbox.name} (${inbox.phone_number || inbox.name})`,
    value: inbox.id,
  }))
);

const tableHeaders = computed(() => [
  t('MESSAGE_TEMPLATES_MGMT.LIST.TABLE_HEADER.NAME'),
  t('MESSAGE_TEMPLATES_MGMT.LIST.TABLE_HEADER.CATEGORY'),
  t('MESSAGE_TEMPLATES_MGMT.LIST.TABLE_HEADER.STATUS'),
  t('MESSAGE_TEMPLATES_MGMT.LIST.TABLE_HEADER.LANGUAGE'),
  t('MESSAGE_TEMPLATES_MGMT.LIST.TABLE_HEADER.QUALITY'),
]);

const statusLabels = computed(() => ({
  APPROVED: t('MESSAGE_TEMPLATES_MGMT.STATUS.APPROVED'),
  PENDING: t('MESSAGE_TEMPLATES_MGMT.STATUS.PENDING'),
  REJECTED: t('MESSAGE_TEMPLATES_MGMT.STATUS.REJECTED'),
  PAUSED: t('MESSAGE_TEMPLATES_MGMT.STATUS.PAUSED'),
  DISABLED: t('MESSAGE_TEMPLATES_MGMT.STATUS.DISABLED'),
}));

const qualityLabels = computed(() => ({
  GREEN: t('MESSAGE_TEMPLATES_MGMT.QUALITY.GREEN'),
  YELLOW: t('MESSAGE_TEMPLATES_MGMT.QUALITY.YELLOW'),
  RED: t('MESSAGE_TEMPLATES_MGMT.QUALITY.RED'),
  UNKNOWN: t('MESSAGE_TEMPLATES_MGMT.QUALITY.UNKNOWN'),
}));

const statusLabel = status => statusLabels.value[status] || status;
const qualityLabel = quality => qualityLabels.value[quality] || '--';

const fetchTemplates = async () => {
  if (!selectedInboxId.value) {
    templates.value = [];
    return;
  }

  isFetchingTemplates.value = true;
  fetchError.value = '';

  try {
    const response = await store.dispatch('inboxes/getMessageTemplates', {
      inboxId: selectedInboxId.value,
    });
    templates.value = response.templates || [];
  } catch (error) {
    fetchError.value = t('MESSAGE_TEMPLATES_MGMT.FETCH_ERROR');
    useAlert(fetchError.value);
  } finally {
    isFetchingTemplates.value = false;
  }
};

const goToCreateTemplate = () => {
  router.push({
    name: 'message_templates_new',
    query: { inbox_id: selectedInboxId.value },
  });
};

watch(selectedInboxId, fetchTemplates);

onMounted(() => {
  if (!inboxOptions.value.length) return;

  const queryInboxId = Number(route.query.inbox_id);
  const isValidQueryInbox = inboxOptions.value.some(
    option => option.value === queryInboxId
  );

  selectedInboxId.value = isValidQueryInbox
    ? queryInboxId
    : inboxOptions.value[0].value;
});
</script>

<template>
  <SettingsLayout
    :is-loading="isFetchingTemplates"
    :loading-message="$t('MESSAGE_TEMPLATES_MGMT.LOADING')"
    :no-records-found="
      !!selectedInboxId && !isFetchingTemplates && !templates.length
    "
    :no-records-message="$t('MESSAGE_TEMPLATES_MGMT.LIST.404')"
  >
    <template #header>
      <BaseSettingsHeader
        :title="$t('MESSAGE_TEMPLATES_MGMT.HEADER')"
        :description="$t('MESSAGE_TEMPLATES_MGMT.DESCRIPTION')"
        feature-name="message-templates"
      >
        <template #actions>
          <Button
            :label="$t('MESSAGE_TEMPLATES_MGMT.HEADER_BTN_TXT')"
            size="sm"
            :disabled="!selectedInboxId"
            @click="goToCreateTemplate"
          />
        </template>
      </BaseSettingsHeader>
    </template>
    <template #body>
      <div v-if="!whatsAppCloudInboxes.length" class="p-4">
        <p class="text-n-slate-11 text-body-main">
          {{ $t('MESSAGE_TEMPLATES_MGMT.NO_WHATSAPP_INBOX') }}
        </p>
      </div>
      <template v-else>
        <div class="max-w-sm p-4 pb-0">
          <label class="text-body-main text-n-slate-11">
            {{ $t('MESSAGE_TEMPLATES_MGMT.SELECT_INBOX.LABEL') }}
          </label>
          <ComboBox
            v-model="selectedInboxId"
            :options="inboxOptions"
            :placeholder="$t('MESSAGE_TEMPLATES_MGMT.SELECT_INBOX.PLACEHOLDER')"
          />
        </div>

        <BaseTable
          v-if="selectedInboxId"
          :headers="tableHeaders"
          :items="templates"
          :no-data-message="$t('MESSAGE_TEMPLATES_MGMT.LIST.404')"
        >
          <template #row="{ items }">
            <BaseTableRow
              v-for="template in items"
              :key="template.id"
              :item="template"
            >
              <template #default>
                <BaseTableCell>
                  <span class="text-body-main text-n-slate-12">
                    {{ template.name }}
                  </span>
                </BaseTableCell>
                <BaseTableCell>
                  <span class="text-body-main text-n-slate-11">
                    {{ template.category }}
                  </span>
                </BaseTableCell>
                <BaseTableCell>
                  <span class="text-body-main text-n-slate-11">
                    {{ statusLabel(template.status) }}
                  </span>
                </BaseTableCell>
                <BaseTableCell>
                  <span class="text-body-main text-n-slate-11">
                    {{ template.language }}
                  </span>
                </BaseTableCell>
                <BaseTableCell>
                  <span class="text-body-main text-n-slate-11">
                    {{ qualityLabel(template.quality) }}
                  </span>
                </BaseTableCell>
              </template>
            </BaseTableRow>
          </template>
        </BaseTable>
        <div v-else class="p-4">
          <p class="text-n-slate-11 text-body-main">
            {{ $t('MESSAGE_TEMPLATES_MGMT.NO_INBOX_SELECTED') }}
          </p>
        </div>
      </template>
    </template>
  </SettingsLayout>
</template>
