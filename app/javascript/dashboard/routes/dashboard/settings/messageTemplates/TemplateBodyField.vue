<script setup>
import { computed, defineAsyncComponent, nextTick, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { vOnClickOutside } from '@vueuse/components';

import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import { wrapSelection, insertAtCursor } from './whatsappMarkdown';

const EmojiInput = defineAsyncComponent(
  () => import('shared/components/emoji/EmojiInput.vue')
);

const MAX_BODY_LENGTH = 1024;
const MARKERS = { BOLD: '*', ITALIC: '_', STRIKETHROUGH: '~', CODE: '```' };

const { t } = useI18n();

const body = defineModel({ type: String, default: '' });
const samples = defineModel('samples', { type: Object, default: () => ({}) });

const textAreaRef = ref(null);
const isEmojiPickerOpen = ref(false);

const detectedVariables = computed(() => {
  const matches = body.value.matchAll(/\{\{(\d+)\}\}/g);
  const numbers = [...new Set([...matches].map(match => Number(match[1])))];
  return numbers.sort((a, b) => a - b);
});

const setCursorAfterEdit = (cursorStart, cursorEnd) => {
  nextTick(() => {
    const el = textAreaRef.value?.getEl();
    if (!el) return;
    el.focus();
    el.setSelectionRange(cursorStart, cursorEnd);
  });
};

const applyMarker = marker => {
  const el = textAreaRef.value?.getEl();
  if (!el) return;

  const { text, cursorStart, cursorEnd } = wrapSelection(
    body.value,
    el.selectionStart,
    el.selectionEnd,
    marker
  );
  body.value = text;
  setCursorAfterEdit(cursorStart, cursorEnd);
};

const insertVariable = () => {
  const el = textAreaRef.value?.getEl();
  if (!el) return;

  const nextNumber =
    detectedVariables.value.length > 0
      ? Math.max(...detectedVariables.value) + 1
      : 1;

  const { text, cursorStart, cursorEnd } = insertAtCursor(
    body.value,
    el.selectionStart,
    el.selectionEnd,
    `{{${nextNumber}}}`
  );
  body.value = text;
  setCursorAfterEdit(cursorStart, cursorEnd);
};

const insertEmoji = emoji => {
  const el = textAreaRef.value?.getEl();
  if (!el) return;

  const { text, cursorStart, cursorEnd } = insertAtCursor(
    body.value,
    el.selectionStart,
    el.selectionEnd,
    emoji
  );
  body.value = text;
  isEmojiPickerOpen.value = false;
  setCursorAfterEdit(cursorStart, cursorEnd);
};
</script>

<template>
  <div class="space-y-2">
    <TextArea
      ref="textAreaRef"
      v-model="body"
      :label="$t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BODY.LABEL')"
      :placeholder="$t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BODY.PLACEHOLDER')"
      :max-length="MAX_BODY_LENGTH"
      show-character-count
    >
      <div class="flex items-center gap-1 pb-2 border-b border-n-weak">
        <Button
          v-tooltip="
            $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BODY.TOOLBAR.BOLD')
          "
          icon="i-lucide-bold"
          variant="ghost"
          color="slate"
          size="xs"
          @click="applyMarker(MARKERS.BOLD)"
        />
        <Button
          v-tooltip="
            $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BODY.TOOLBAR.ITALIC')
          "
          icon="i-lucide-italic"
          variant="ghost"
          color="slate"
          size="xs"
          @click="applyMarker(MARKERS.ITALIC)"
        />
        <Button
          v-tooltip="
            $t(
              'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BODY.TOOLBAR.STRIKETHROUGH'
            )
          "
          icon="i-lucide-strikethrough"
          variant="ghost"
          color="slate"
          size="xs"
          @click="applyMarker(MARKERS.STRIKETHROUGH)"
        />
        <Button
          v-tooltip="
            $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BODY.TOOLBAR.CODE')
          "
          icon="i-lucide-code"
          variant="ghost"
          color="slate"
          size="xs"
          @click="applyMarker(MARKERS.CODE)"
        />
        <div
          v-on-click-outside="() => (isEmojiPickerOpen = false)"
          class="relative"
        >
          <Button
            v-tooltip="
              $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BODY.TOOLBAR.EMOJI')
            "
            icon="i-lucide-smile-plus"
            variant="ghost"
            color="slate"
            size="xs"
            @click="isEmojiPickerOpen = !isEmojiPickerOpen"
          />
          <EmojiInput
            v-if="isEmojiPickerOpen"
            class="top-full mt-1.5 ltr:left-0 rtl:right-0"
            :on-click="insertEmoji"
          />
        </div>
        <div class="w-px h-4 mx-1 bg-n-weak" />
        <Button
          :label="$t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BODY.ADD_VARIABLE')"
          icon="i-lucide-plus"
          variant="ghost"
          color="slate"
          size="xs"
          @click="insertVariable"
        />
      </div>
    </TextArea>

    <div v-if="detectedVariables.length" class="space-y-2">
      <h3 class="font-semibold text-n-slate-12">
        {{ t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.VARIABLES.TITLE') }}
      </h3>
      <p class="text-body-main text-n-slate-11">
        {{ t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.VARIABLES.DESCRIPTION') }}
      </p>
      <Input
        v-for="number in detectedVariables"
        :key="number"
        v-model="samples[number]"
        :label="`{{${number}}}`"
        :placeholder="
          t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.VARIABLES.PLACEHOLDER', {
            variable: number,
          })
        "
      />
    </div>
  </div>
</template>
