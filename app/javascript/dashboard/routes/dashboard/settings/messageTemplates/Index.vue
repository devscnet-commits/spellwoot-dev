<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useStoreGetters, useStore } from 'dashboard/composables/store';
import { INBOX_TYPES } from 'dashboard/helper/inbox';

import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import EditTemplateModal from './EditTemplateModal.vue';
import TemplateWhatsAppPreview from './TemplateWhatsAppPreview.vue';
import { CATEGORY_ICONS } from './templateCategoryIcons';
import { findComponent, templateToPreviewProps } from './templateComponents';
import {
  BaseTable,
  BaseTableRow,
  BaseTableCell,
} from 'dashboard/components-next/table';

const ALL = 'ALL';
const CATEGORY_IDS = ['MARKETING', 'UTILITY', 'AUTHENTICATION'];
const STATUS_IDS = ['APPROVED', 'PENDING', 'REJECTED', 'PAUSED', 'DISABLED'];
const STATUS_BADGE_CLASSES = {
  APPROVED: 'bg-n-teal-3 text-n-teal-11',
  PENDING: 'bg-n-amber-3 text-n-amber-11',
  REJECTED: 'bg-n-ruby-3 text-n-ruby-11',
  PAUSED: 'bg-n-slate-3 text-n-slate-11',
  DISABLED: 'bg-n-slate-3 text-n-slate-11',
};
const QUALITY_DOT_CLASSES = {
  GREEN: 'bg-n-teal-9',
  YELLOW: 'bg-n-amber-9',
  RED: 'bg-n-ruby-9',
  UNKNOWN: 'bg-n-slate-8',
};

const getters = useStoreGetters();
const store = useStore();
const route = useRoute();
const router = useRouter();
const { t } = useI18n();

const templates = ref([]);
const isFetchingTemplates = ref(false);
const isGuidelineDismissed = ref(false);

const searchQuery = ref('');
const inboxFilter = ref(ALL);
const categoryFilter = ref(ALL);
const languageFilter = ref(ALL);
const statusFilter = ref(ALL);

const showPreviewModal = ref(false);
const showEditModal = ref(false);
const showDeleteModal = ref(false);
const selectedTemplate = ref(null);
const isDeleting = ref(false);

const editableStatuses = ['APPROVED', 'REJECTED', 'PAUSED'];
const canEdit = template => editableStatuses.includes(template.status);

const whatsAppCloudInboxes = computed(() =>
  (getters['inboxes/getInboxes'].value || []).filter(
    inbox =>
      inbox.channel_type === INBOX_TYPES.WHATSAPP &&
      inbox.provider === 'whatsapp_cloud'
  )
);

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

const categoryLabels = computed(() => ({
  MARKETING: t(
    'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.CATEGORIES.MARKETING.LABEL'
  ),
  UTILITY: t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.CATEGORIES.UTILITY.LABEL'),
  AUTHENTICATION: t(
    'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.CATEGORIES.AUTHENTICATION.LABEL'
  ),
}));

const rejectedReasonLabels = computed(() => ({
  ABUSIVE_CONTENT: t(
    'MESSAGE_TEMPLATES_MGMT.LIST.REJECTED_REASON.ABUSIVE_CONTENT'
  ),
  INVALID_FORMAT: t(
    'MESSAGE_TEMPLATES_MGMT.LIST.REJECTED_REASON.INVALID_FORMAT'
  ),
  SCAM: t('MESSAGE_TEMPLATES_MGMT.LIST.REJECTED_REASON.SCAM'),
  TAG_CONTENT_MISMATCH: t(
    'MESSAGE_TEMPLATES_MGMT.LIST.REJECTED_REASON.TAG_CONTENT_MISMATCH'
  ),
  PROMOTIONAL: t('MESSAGE_TEMPLATES_MGMT.LIST.REJECTED_REASON.PROMOTIONAL'),
  INCORRECT_CATEGORY: t(
    'MESSAGE_TEMPLATES_MGMT.LIST.REJECTED_REASON.INCORRECT_CATEGORY'
  ),
}));

const statusLabel = status => statusLabels.value[status] || status;
const qualityLabel = quality => qualityLabels.value[quality] || '--';
const categoryLabel = category => categoryLabels.value[category] || category;
const statusBadgeClass = status =>
  STATUS_BADGE_CLASSES[status] || STATUS_BADGE_CLASSES.PAUSED;
const qualityDotClass = quality =>
  QUALITY_DOT_CLASSES[quality] || QUALITY_DOT_CLASSES.UNKNOWN;
const buttonCount = template =>
  (findComponent(template.components, 'BUTTONS')?.buttons || []).length;
const templateSubtitle = template => {
  const count = buttonCount(template);
  if (!count) return template.sourceInbox.name;

  return `${template.sourceInbox.name} · ${t(
    'MESSAGE_TEMPLATES_MGMT.LIST.BUTTON_COUNT',
    count
  )}`;
};
const rejectedReasonLabel = template =>
  template.rejected_reason
    ? rejectedReasonLabels.value[template.rejected_reason] ||
      template.rejected_reason
    : t('MESSAGE_TEMPLATES_MGMT.LIST.REJECTED_REASON.NONE');

const inboxOptions = computed(() => [
  { value: ALL, label: t('MESSAGE_TEMPLATES_MGMT.LIST.FILTERS.INBOX_ALL') },
  ...whatsAppCloudInboxes.value.map(inbox => ({
    value: inbox.id,
    label: inbox.name,
  })),
]);

const categoryOptions = computed(() => [
  { value: ALL, label: t('MESSAGE_TEMPLATES_MGMT.LIST.FILTERS.CATEGORY_ALL') },
  ...CATEGORY_IDS.map(id => ({ value: id, label: categoryLabel(id) })),
]);

const statusOptions = computed(() => [
  { value: ALL, label: t('MESSAGE_TEMPLATES_MGMT.LIST.FILTERS.STATUS_ALL') },
  ...STATUS_IDS.map(id => ({ value: id, label: statusLabel(id) })),
]);

const languageOptions = computed(() => {
  const languages = [
    ...new Set(templates.value.map(template => template.language)),
  ];
  return [
    {
      value: ALL,
      label: t('MESSAGE_TEMPLATES_MGMT.LIST.FILTERS.LANGUAGE_ALL'),
    },
    ...languages.sort().map(language => ({ value: language, label: language })),
  ];
});

const tableHeaders = computed(() => [
  t('MESSAGE_TEMPLATES_MGMT.LIST.TABLE_HEADER.NAME'),
  t('MESSAGE_TEMPLATES_MGMT.LIST.TABLE_HEADER.CATEGORY'),
  t('MESSAGE_TEMPLATES_MGMT.LIST.TABLE_HEADER.LANGUAGE'),
  t('MESSAGE_TEMPLATES_MGMT.LIST.TABLE_HEADER.STATUS_QUALITY'),
  t('MESSAGE_TEMPLATES_MGMT.LIST.TABLE_HEADER.BLOCK_REASON'),
  t('MESSAGE_TEMPLATES_MGMT.LIST.TABLE_HEADER.ACTIONS'),
]);

const stats = computed(() => ({
  total: templates.value.length,
  inboxCount: new Set(templates.value.map(template => template.sourceInbox.id))
    .size,
  approved: templates.value.filter(template => template.status === 'APPROVED')
    .length,
  pending: templates.value.filter(template => template.status === 'PENDING')
    .length,
}));

const filteredTemplates = computed(() => {
  const query = searchQuery.value.trim().toLowerCase();

  return templates.value.filter(template => {
    if (
      inboxFilter.value !== ALL &&
      template.sourceInbox.id !== inboxFilter.value
    ) {
      return false;
    }
    if (
      categoryFilter.value !== ALL &&
      template.category !== categoryFilter.value
    ) {
      return false;
    }
    if (
      languageFilter.value !== ALL &&
      template.language !== languageFilter.value
    ) {
      return false;
    }
    if (statusFilter.value !== ALL && template.status !== statusFilter.value) {
      return false;
    }
    if (!query) return true;

    const bodyText = findComponent(template.components, 'BODY')?.text || '';
    return (
      template.name.toLowerCase().includes(query) ||
      bodyText.toLowerCase().includes(query)
    );
  });
});

const createTargetInboxId = computed(() =>
  inboxFilter.value !== ALL
    ? inboxFilter.value
    : whatsAppCloudInboxes.value[0]?.id
);

const fetchAllTemplates = async () => {
  if (!whatsAppCloudInboxes.value.length) {
    templates.value = [];
    return;
  }

  isFetchingTemplates.value = true;

  const results = await Promise.allSettled(
    whatsAppCloudInboxes.value.map(async inbox => {
      const response = await store.dispatch('inboxes/getMessageTemplates', {
        inboxId: inbox.id,
      });
      return (response.templates || []).map(template => ({
        ...template,
        sourceInbox: inbox,
      }));
    })
  );

  templates.value = results
    .filter(result => result.status === 'fulfilled')
    .flatMap(result => result.value);

  if (results.some(result => result.status === 'rejected')) {
    useAlert(t('MESSAGE_TEMPLATES_MGMT.FETCH_ERROR'));
  }

  isFetchingTemplates.value = false;
};

const goToCreateTemplate = () => {
  router.push({
    name: 'message_templates_new',
    query: { inbox_id: createTargetInboxId.value },
  });
};

const openPreviewModal = template => {
  selectedTemplate.value = template;
  showPreviewModal.value = true;
};

const closePreviewModal = () => {
  showPreviewModal.value = false;
  selectedTemplate.value = null;
};

const previewProps = computed(() =>
  selectedTemplate.value
    ? templateToPreviewProps(selectedTemplate.value.components)
    : null
);

const openEditModal = template => {
  selectedTemplate.value = template;
  showEditModal.value = true;
};

const closeEditModal = () => {
  showEditModal.value = false;
  selectedTemplate.value = null;
};

const openDeleteModal = template => {
  selectedTemplate.value = template;
  showDeleteModal.value = true;
};

const closeDeleteModal = () => {
  showDeleteModal.value = false;
  selectedTemplate.value = null;
};

const confirmDelete = async () => {
  isDeleting.value = true;
  try {
    await store.dispatch('inboxes/deleteMessageTemplate', {
      inboxId: selectedTemplate.value.sourceInbox.id,
      templateName: selectedTemplate.value.name,
    });
    useAlert(t('MESSAGE_TEMPLATES_MGMT.DELETE.SUCCESS_MESSAGE'));
    closeDeleteModal();
    fetchAllTemplates();
  } catch (error) {
    useAlert(t('MESSAGE_TEMPLATES_MGMT.DELETE.ERROR_MESSAGE'));
  } finally {
    isDeleting.value = false;
  }
};

onMounted(() => {
  const queryInboxId = Number(route.query.inbox_id);
  const isValidQueryInbox = whatsAppCloudInboxes.value.some(
    inbox => inbox.id === queryInboxId
  );
  if (isValidQueryInbox) inboxFilter.value = queryInboxId;

  fetchAllTemplates();
});
</script>

<template>
  <SettingsLayout
    :is-loading="isFetchingTemplates"
    :loading-message="$t('MESSAGE_TEMPLATES_MGMT.LOADING')"
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
            :disabled="!whatsAppCloudInboxes.length"
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

      <div v-else class="p-4 space-y-4">
        <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
          <div class="p-4 border rounded-xl border-n-weak bg-n-solid-2">
            <p class="font-medium uppercase text-caption text-n-slate-10">
              {{ $t('MESSAGE_TEMPLATES_MGMT.LIST.STATS.TOTAL') }}
            </p>
            <p class="mt-1 text-2xl font-semibold text-n-slate-12">
              {{ stats.total }}
            </p>
            <p class="mt-1 text-xs text-n-slate-10">
              {{
                $t(
                  'MESSAGE_TEMPLATES_MGMT.LIST.STATS.TOTAL_SUBTITLE',
                  stats.inboxCount
                )
              }}
            </p>
          </div>
          <div class="p-4 border rounded-xl border-n-teal-4 bg-n-teal-2">
            <p class="font-medium uppercase text-caption text-n-teal-11">
              {{ $t('MESSAGE_TEMPLATES_MGMT.LIST.STATS.APPROVED') }}
            </p>
            <p class="mt-1 text-2xl font-semibold text-n-teal-11">
              {{ stats.approved }}
            </p>
            <p class="mt-1 text-xs text-n-teal-11">
              {{ $t('MESSAGE_TEMPLATES_MGMT.LIST.STATS.APPROVED_SUBTITLE') }}
            </p>
          </div>
          <div class="p-4 border rounded-xl border-n-amber-4 bg-n-amber-2">
            <p class="font-medium uppercase text-caption text-n-amber-11">
              {{ $t('MESSAGE_TEMPLATES_MGMT.LIST.STATS.PENDING') }}
            </p>
            <p class="mt-1 text-2xl font-semibold text-n-amber-11">
              {{ stats.pending }}
            </p>
            <p class="mt-1 text-xs text-n-amber-11">
              {{ $t('MESSAGE_TEMPLATES_MGMT.LIST.STATS.PENDING_SUBTITLE') }}
            </p>
          </div>
        </div>

        <div
          v-if="!isGuidelineDismissed"
          class="flex items-start justify-between gap-3 p-3 border rounded-xl bg-n-blue-2 border-n-blue-4"
        >
          <div class="flex items-start gap-2">
            <Icon
              icon="i-lucide-info"
              class="flex-shrink-0 mt-0.5 size-4 text-n-blue-11"
            />
            <div>
              <p class="font-medium text-n-blue-11">
                {{ $t('MESSAGE_TEMPLATES_MGMT.LIST.GUIDELINE.TITLE') }}
              </p>
              <p class="text-xs text-n-blue-11">
                {{ $t('MESSAGE_TEMPLATES_MGMT.LIST.GUIDELINE.DESCRIPTION') }}
              </p>
            </div>
          </div>
          <Button
            icon="i-lucide-x"
            variant="ghost"
            color="blue"
            size="xs"
            @click="isGuidelineDismissed = true"
          />
        </div>

        <div class="flex flex-col gap-3 lg:flex-row lg:items-center">
          <Input
            v-model="searchQuery"
            class="lg:max-w-xs"
            :placeholder="$t('MESSAGE_TEMPLATES_MGMT.LIST.SEARCH_PLACEHOLDER')"
          />
          <ComboBox
            v-model="inboxFilter"
            class="lg:w-48"
            :options="inboxOptions"
          />
          <ComboBox
            v-model="categoryFilter"
            class="lg:w-40"
            :options="categoryOptions"
          />
          <ComboBox
            v-model="languageFilter"
            class="lg:w-36"
            :options="languageOptions"
          />
          <ComboBox
            v-model="statusFilter"
            class="lg:w-36"
            :options="statusOptions"
          />
        </div>

        <div class="flex items-center justify-between text-xs text-n-slate-10">
          <span>
            {{
              $t(
                'MESSAGE_TEMPLATES_MGMT.LIST.RESULTS_COUNT',
                filteredTemplates.length
              )
            }}
          </span>
          <span class="flex items-center gap-1">
            <span class="i-lucide-refresh-cw size-3" />
            {{ $t('MESSAGE_TEMPLATES_MGMT.LIST.SYNCED_WITH_META') }}
          </span>
        </div>

        <BaseTable
          :headers="tableHeaders"
          :items="filteredTemplates"
          :no-data-message="$t('MESSAGE_TEMPLATES_MGMT.LIST.404')"
        >
          <template #row="{ items }">
            <BaseTableRow
              v-for="template in items"
              :key="`${template.sourceInbox.id}-${template.id}`"
              :item="template"
            >
              <template #default>
                <BaseTableCell>
                  <p class="font-medium text-n-slate-12">{{ template.name }}</p>
                  <p class="text-xs text-n-slate-10">
                    {{ templateSubtitle(template) }}
                  </p>
                </BaseTableCell>
                <BaseTableCell>
                  <span
                    class="flex items-center gap-1.5 text-body-main text-n-slate-11"
                  >
                    <Icon
                      :icon="CATEGORY_ICONS[template.category]"
                      class="flex-shrink-0 size-4"
                    />
                    {{ categoryLabel(template.category) }}
                  </span>
                </BaseTableCell>
                <BaseTableCell>
                  <span class="text-body-main text-n-slate-11">
                    {{ template.language }}
                  </span>
                </BaseTableCell>
                <BaseTableCell>
                  <span
                    class="inline-flex px-2 py-0.5 text-xs font-medium rounded-full"
                    :class="statusBadgeClass(template.status)"
                  >
                    {{ statusLabel(template.status) }}
                  </span>
                  <div
                    class="flex items-center gap-1 mt-1 text-xs text-n-slate-10"
                  >
                    <span
                      class="rounded-full size-1.5"
                      :class="qualityDotClass(template.quality)"
                    />
                    {{ qualityLabel(template.quality) }}
                  </div>
                </BaseTableCell>
                <BaseTableCell>
                  <span class="text-body-main text-n-slate-11">
                    {{ rejectedReasonLabel(template) }}
                  </span>
                </BaseTableCell>
                <BaseTableCell align="end">
                  <div class="flex justify-end flex-shrink-0 gap-2">
                    <Button
                      v-tooltip.top="
                        $t('MESSAGE_TEMPLATES_MGMT.LIST.PREVIEW_TITLE')
                      "
                      icon="i-lucide-eye"
                      variant="ghost"
                      color="slate"
                      size="xs"
                      @click="openPreviewModal(template)"
                    />
                    <Button
                      v-tooltip.top="
                        canEdit(template)
                          ? $t('MESSAGE_TEMPLATES_MGMT.EDIT.TITLE', {
                              name: template.name,
                            })
                          : $t('MESSAGE_TEMPLATES_MGMT.EDIT.NOT_EDITABLE')
                      "
                      icon="i-lucide-pencil"
                      variant="ghost"
                      color="slate"
                      size="xs"
                      :disabled="!canEdit(template)"
                      @click="openEditModal(template)"
                    />
                    <Button
                      v-tooltip.top="$t('MESSAGE_TEMPLATES_MGMT.DELETE.TITLE')"
                      icon="i-lucide-trash-2"
                      variant="ghost"
                      color="ruby"
                      size="xs"
                      @click="openDeleteModal(template)"
                    />
                  </div>
                </BaseTableCell>
              </template>
            </BaseTableRow>
          </template>
        </BaseTable>
      </div>
    </template>

    <woot-modal v-model:show="showPreviewModal" :on-close="closePreviewModal">
      <div v-if="previewProps" class="p-6">
        <TemplateWhatsAppPreview v-bind="previewProps" />
      </div>
    </woot-modal>

    <woot-modal v-model:show="showEditModal" :on-close="closeEditModal">
      <EditTemplateModal
        v-if="selectedTemplate"
        :inbox-id="selectedTemplate.sourceInbox.id"
        :template="selectedTemplate"
        @close="closeEditModal"
        @updated="fetchAllTemplates"
      />
    </woot-modal>

    <woot-delete-modal
      v-model:show="showDeleteModal"
      :on-close="closeDeleteModal"
      :on-confirm="confirmDelete"
      :title="$t('MESSAGE_TEMPLATES_MGMT.DELETE.CONFIRM.TITLE')"
      :message="$t('MESSAGE_TEMPLATES_MGMT.DELETE.CONFIRM.MESSAGE')"
      :message-value="selectedTemplate ? ` ${selectedTemplate.name}?` : ''"
      :confirm-text="$t('MESSAGE_TEMPLATES_MGMT.DELETE.CONFIRM.YES')"
      :reject-text="$t('MESSAGE_TEMPLATES_MGMT.DELETE.CONFIRM.NO')"
    />
  </SettingsLayout>
</template>
