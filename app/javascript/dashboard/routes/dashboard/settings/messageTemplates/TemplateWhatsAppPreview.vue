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

const currentTime = new Date().toLocaleTimeString('pt-BR', {
  hour: '2-digit',
  minute: '2-digit',
});

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
    <div
      class="overflow-hidden border rounded-[28px] border-n-weak bg-n-solid-1"
    >
      <div
        class="flex items-center justify-between px-4 pt-2 pb-1 text-[10px] font-medium text-n-slate-12"
      >
        <span>{{ currentTime }}</span>
        <div class="flex items-center gap-1">
          <span class="i-lucide-signal-high size-3" />
          <span class="i-lucide-wifi size-3" />
          <span class="i-lucide-battery-full size-3" />
        </div>
      </div>

      <div
        class="flex items-center gap-2 px-4 py-2.5 text-white bg-n-teal-11 dark:bg-n-teal-9"
      >
        <span
          class="flex items-center justify-center flex-shrink-0 rounded-full bg-white/20 size-8"
        >
          <span class="i-lucide-store size-4" />
        </span>
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-1">
            <span class="text-sm font-medium truncate">
              {{
                t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.PREVIEW.BUSINESS_NAME')
              }}
            </span>
            <span class="i-lucide-badge-check flex-shrink-0 size-3.5" />
          </div>
          <p class="text-[11px] text-white/80 truncate">
            {{
              t(
                'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.PREVIEW.BUSINESS_SUBTITLE'
              )
            }}
          </p>
        </div>
        <span
          class="flex-shrink-0 px-2 py-0.5 text-[10px] border rounded-full border-white/30"
        >
          {{ t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.PREVIEW.WHATSAPP_BADGE') }}
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

          <div
            class="flex items-center justify-end gap-1 text-[10px] text-n-slate-10"
          >
            <span>{{ currentTime }}</span>
            <span class="i-lucide-check-check size-3 text-n-blue-9" />
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
