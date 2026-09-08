<script setup>
import { useI18n } from 'vue-i18n';
import TemplateWhatsAppPreview from './TemplateWhatsAppPreview.vue';

defineProps({
  inboxSummary: { type: String, default: '' },
  categorySubtypeSummary: { type: String, default: '' },
  header: {
    type: Object,
    default: () => ({ type: 'NONE', text: '', fileName: '' }),
  },
  body: { type: String, default: '' },
  footer: { type: String, default: '' },
  buttons: { type: Array, default: () => [] },
  samples: { type: Object, default: () => ({}) },
  idealForDescription: { type: String, default: '' },
  customizableAreas: { type: String, default: '' },
  showLivePreviewNote: { type: Boolean, default: false },
});

const { t } = useI18n();
</script>

<template>
  <div class="sticky hidden w-full space-y-3 top-4 lg:block lg:max-w-sm">
    <div class="flex items-center justify-between gap-2">
      <span class="text-xs truncate text-n-slate-10">{{ inboxSummary }}</span>
      <span
        class="flex-shrink-0 px-2 py-0.5 text-xs font-medium rounded-full bg-n-blue-3 text-n-blue-11"
      >
        {{ categorySubtypeSummary }}
      </span>
    </div>

    <TemplateWhatsAppPreview
      :header="header"
      :body="body"
      :footer="footer"
      :buttons="buttons"
      :samples="samples"
    />

    <div
      v-if="showLivePreviewNote"
      class="flex items-start gap-2 p-3 border rounded-lg border-n-teal-6 bg-n-teal-2 dark:bg-n-teal-3"
    >
      <span
        class="flex-shrink-0 mt-0.5 size-4 i-lucide-check-circle-2 text-n-teal-11"
      />
      <p class="text-body-main text-n-teal-12">
        <span class="font-semibold">
          {{
            t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.PREVIEW.LIVE_NOTE_TITLE')
          }}:
        </span>
        {{
          t(
            'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.PREVIEW.LIVE_NOTE_DESCRIPTION'
          )
        }}
      </p>
    </div>

    <div class="p-4 space-y-2 border rounded-xl border-n-weak bg-n-solid-2">
      <h3 class="flex items-center gap-2 font-semibold text-n-slate-12">
        <span class="i-lucide-sparkles size-4 text-n-blue-9" />
        {{ t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.IDEAL_FOR_TITLE') }}
      </h3>
      <p class="text-body-main text-n-slate-11">{{ idealForDescription }}</p>

      <div class="pt-2 mt-2 border-t border-n-weak">
        <p class="mb-1 text-xs font-medium uppercase text-n-slate-10">
          {{
            t(
              'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.CUSTOMIZABLE_AREAS_TITLE'
            )
          }}
        </p>
        <p class="text-xs text-n-slate-11">{{ customizableAreas }}</p>
      </div>
    </div>
  </div>
</template>
