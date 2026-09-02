<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import { renderWhatsAppMarkdown } from './whatsappMarkdown';
import { BUTTON_ICONS } from './templateButtonIcons';

const props = defineProps({
  inboxName: { type: String, default: '' },
  inboxPhoneNumber: { type: String, default: '' },
  name: { type: String, default: '' },
  categoryLabel: { type: String, default: '' },
  languageLabel: { type: String, default: '' },
  body: { type: String, default: '' },
  footer: { type: String, default: '' },
  samples: { type: Object, default: () => ({}) },
  buttons: { type: Array, default: () => [] },
  buttonTypeLabels: { type: Object, default: () => ({}) },
  isSubmitting: { type: Boolean, default: false },
});

const emit = defineEmits(['confirm', 'cancel']);

const { t } = useI18n();

const renderedBody = computed(() =>
  renderWhatsAppMarkdown(props.body, props.samples)
);

const buttonDetail = button => {
  if (button.type === 'URL') {
    return t('MESSAGE_TEMPLATES_MGMT.CREATE.CONFIRM.BUTTON_URL_DETAIL', {
      url: button.url,
    });
  }
  if (button.type === 'PHONE_NUMBER') {
    return t('MESSAGE_TEMPLATES_MGMT.CREATE.CONFIRM.BUTTON_PHONE_DETAIL', {
      phone: button.phone_number,
    });
  }
  if (button.type === 'COPY_CODE') {
    return t('MESSAGE_TEMPLATES_MGMT.CREATE.CONFIRM.BUTTON_CODE_DETAIL', {
      code: button.example,
    });
  }
  return props.buttonTypeLabels[button.type];
};
</script>

<template>
  <div class="p-6 space-y-5 max-h-[85vh] overflow-y-auto">
    <div class="flex items-start gap-3">
      <span
        class="flex items-center justify-center flex-shrink-0 rounded-full bg-n-blue-3 size-10"
      >
        <span class="i-lucide-send size-5 text-n-blue-9" />
      </span>
      <div>
        <h2 class="text-heading-2 text-n-slate-12">
          {{ t('MESSAGE_TEMPLATES_MGMT.CREATE.CONFIRM.TITLE') }}
        </h2>
        <p class="text-body-main text-n-slate-11">
          {{ t('MESSAGE_TEMPLATES_MGMT.CREATE.CONFIRM.SUBTITLE') }}
        </p>
      </div>
    </div>

    <div
      class="flex items-center justify-between gap-3 p-3 border rounded-xl bg-n-blue-2 border-n-blue-4"
    >
      <div class="flex items-center min-w-0 gap-3">
        <span
          class="flex items-center justify-center flex-shrink-0 rounded-lg bg-n-blue-9 size-9"
        >
          <span class="text-white i-lucide-inbox size-4" />
        </span>
        <div class="min-w-0">
          <p class="font-medium uppercase text-caption text-n-blue-11">
            {{ t('MESSAGE_TEMPLATES_MGMT.CREATE.CONFIRM.DESTINATION_INBOX') }}
          </p>
          <p class="font-semibold truncate text-n-slate-12">
            {{ inboxName }}
          </p>
        </div>
      </div>
      <span
        v-if="inboxPhoneNumber"
        class="flex-shrink-0 px-2 py-1 text-xs font-medium border rounded-full border-n-weak text-n-slate-11"
      >
        {{ inboxPhoneNumber }}
      </span>
    </div>

    <div class="grid grid-cols-2 gap-3">
      <div class="p-3 border rounded-xl border-n-weak">
        <p class="font-medium uppercase text-caption text-n-slate-10">
          {{ t('MESSAGE_TEMPLATES_MGMT.CREATE.CONFIRM.NAME_LABEL') }}
        </p>
        <p class="font-semibold truncate text-n-slate-12">{{ name }}</p>
      </div>
      <div class="p-3 border rounded-xl border-n-weak">
        <p class="font-medium uppercase text-caption text-n-slate-10">
          {{
            t('MESSAGE_TEMPLATES_MGMT.CREATE.CONFIRM.CATEGORY_LANGUAGE_LABEL')
          }}
        </p>
        <div class="flex items-center gap-2 mt-1">
          <span
            class="px-2 py-0.5 text-xs font-medium rounded-full bg-n-blue-3 text-n-blue-11"
          >
            {{ categoryLabel }}
          </span>
          <span class="flex items-center gap-1 text-xs text-n-slate-11">
            <span class="i-lucide-globe size-3" />
            {{ languageLabel }}
          </span>
        </div>
      </div>
    </div>

    <div class="space-y-2">
      <h3 class="flex items-center gap-2 font-semibold text-n-slate-12">
        <span class="i-lucide-file-text size-4" />
        {{ t('MESSAGE_TEMPLATES_MGMT.CREATE.CONFIRM.MESSAGE_TEXT_LABEL') }}
      </h3>
      <div class="p-4 space-y-2 border rounded-xl border-n-weak bg-n-solid-2">
        <span
          v-dompurify-html="renderedBody"
          class="prose prose-bubble text-n-slate-12"
        />
        <div
          v-if="footer"
          class="pt-2 mt-2 text-xs border-t text-n-slate-10 border-n-weak"
        >
          {{ footer }}
        </div>
      </div>
    </div>

    <div v-if="buttons.length" class="space-y-2">
      <h3 class="flex items-center gap-2 font-semibold text-n-slate-12">
        <span class="i-lucide-mouse-pointer-click size-4" />
        {{
          t('MESSAGE_TEMPLATES_MGMT.CREATE.CONFIRM.BUTTONS_LABEL', {
            count: buttons.length,
          })
        }}
      </h3>
      <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div
          v-for="(button, index) in buttons"
          :key="index"
          class="flex items-start gap-2 p-3 border rounded-xl border-n-weak"
        >
          <span
            class="flex items-center justify-center flex-shrink-0 text-xs font-semibold text-white rounded-full bg-n-blue-9 size-5"
          >
            {{ index + 1 }}
          </span>
          <div class="flex-1 min-w-0">
            <p class="font-medium truncate text-n-slate-12">
              {{ button.text }}
            </p>
            <p class="text-xs truncate text-n-slate-10">
              {{ buttonDetail(button) }}
            </p>
          </div>
          <span
            v-if="BUTTON_ICONS[button.type]"
            class="flex-shrink-0 mt-0.5 size-4 text-n-slate-10"
            :class="[BUTTON_ICONS[button.type]]"
          />
        </div>
      </div>
    </div>

    <div class="flex items-center justify-end gap-3 pt-2">
      <Button
        :label="t('MESSAGE_TEMPLATES_MGMT.CREATE.CONFIRM.BACK_BUTTON')"
        icon="i-lucide-arrow-left"
        variant="outline"
        color="slate"
        @click="emit('cancel')"
      />
      <Button
        :label="t('MESSAGE_TEMPLATES_MGMT.CREATE.CONFIRM.CONFIRM_BUTTON')"
        icon="i-lucide-check-circle-2"
        :is-loading="isSubmitting"
        @click="emit('confirm')"
      />
    </div>
  </div>
</template>
