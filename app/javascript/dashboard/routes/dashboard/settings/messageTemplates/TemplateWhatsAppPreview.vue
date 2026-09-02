<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { renderWhatsAppMarkdown } from './whatsappMarkdown';

const props = defineProps({
  header: {
    type: Object,
    default: () => ({ type: 'NONE', text: '', fileName: '' }),
  },
  body: { type: String, default: '' },
  footer: { type: String, default: '' },
  buttons: { type: Array, default: () => [] },
  samples: { type: Object, default: () => ({}) },
});

const { t } = useI18n();

const HEADER_MEDIA_ICONS = {
  IMAGE: 'i-lucide-image',
  VIDEO: 'i-lucide-video',
  DOCUMENT: 'i-lucide-file-text',
};

const isMediaHeader = computed(() =>
  ['IMAGE', 'VIDEO', 'DOCUMENT'].includes(props.header?.type)
);

const renderedBody = computed(() =>
  renderWhatsAppMarkdown(props.body, props.samples)
);

const BUTTON_ICONS = {
  URL: 'i-lucide-external-link',
  PHONE_NUMBER: 'i-lucide-phone',
  COPY_CODE: 'i-lucide-copy',
  CATALOG: 'i-lucide-shopping-bag',
  FLOW: 'i-lucide-list',
  ORDER_DETAILS: 'i-lucide-receipt',
};
</script>

<template>
  <div class="space-y-2">
    <h3 class="font-semibold text-n-slate-12">
      {{ t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.PREVIEW.TITLE') }}
    </h3>
    <div class="overflow-hidden border rounded-2xl border-n-weak bg-n-solid-1">
      <div
        class="flex items-center gap-2 px-4 py-3 text-white bg-n-teal-11 dark:bg-n-teal-9"
      >
        <span class="i-lucide-message-circle flex-shrink-0 size-5" />
        <span class="text-sm font-medium truncate">
          {{ t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.PREVIEW.BUSINESS_NAME') }}
        </span>
      </div>

      <div class="p-4 space-y-3 bg-n-solid-2">
        <div class="max-w-[85%] p-3 space-y-2 rounded-xl bg-n-alpha-2">
          <div
            v-if="header.type === 'TEXT' && header.text"
            class="font-semibold text-n-slate-12"
          >
            {{ header.text }}
          </div>
          <div
            v-else-if="isMediaHeader"
            class="flex items-center gap-2 p-2 text-sm rounded-lg text-n-slate-11 bg-n-alpha-1"
          >
            <span
              class="flex-shrink-0 size-4"
              :class="[HEADER_MEDIA_ICONS[header.type]]"
            />
            <span class="truncate">
              {{
                header.fileName ||
                t(
                  'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.PREVIEW.MEDIA_PLACEHOLDER'
                )
              }}
            </span>
          </div>

          <span
            v-if="renderedBody"
            v-dompurify-html="renderedBody"
            class="prose prose-bubble text-n-slate-12"
          />
          <p v-else class="text-n-slate-10">
            {{
              t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.PREVIEW.BODY_PLACEHOLDER')
            }}
          </p>

          <div v-if="footer" class="text-xs text-n-slate-10">
            {{ footer }}
          </div>
        </div>

        <div v-if="buttons.length" class="max-w-[85%] space-y-1">
          <div
            v-for="(button, index) in buttons"
            :key="index"
            class="flex items-center justify-center gap-2 py-2 text-sm font-medium text-center rounded-lg text-n-teal-11 dark:text-n-teal-9 bg-n-alpha-2"
          >
            <span
              v-if="BUTTON_ICONS[button.type]"
              class="flex-shrink-0 size-4"
              :class="[BUTTON_ICONS[button.type]]"
            />
            <span class="truncate">
              {{
                button.text ||
                t(
                  'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.PREVIEW.BUTTON_PLACEHOLDER'
                )
              }}
            </span>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
