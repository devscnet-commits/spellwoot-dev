<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';

import Input from 'dashboard/components-next/input/Input.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  inboxId: { type: Number, required: true },
  textOnly: { type: Boolean, default: false },
});
const HEADER_TYPES = ['NONE', 'TEXT', 'IMAGE', 'VIDEO', 'DOCUMENT'];
const TEXT_ONLY_HEADER_TYPES = ['NONE', 'TEXT'];
const ACCEPT_BY_TYPE = {
  IMAGE: 'image/jpeg,image/png',
  VIDEO: 'video/mp4',
  DOCUMENT: 'application/pdf',
};

const header = defineModel({
  type: Object,
  default: () => ({ type: 'NONE', text: '', handle: '', fileName: '' }),
});

const store = useStore();
const { t } = useI18n();

const isUploading = ref(false);
const uploadError = ref('');
const fileInput = ref(null);

const headerTypeLabels = computed(() => ({
  NONE: t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.HEADER.TYPES.NONE'),
  TEXT: t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.HEADER.TYPES.TEXT'),
  IMAGE: t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.HEADER.TYPES.IMAGE'),
  VIDEO: t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.HEADER.TYPES.VIDEO'),
  DOCUMENT: t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.HEADER.TYPES.DOCUMENT'),
}));

const headerTypeOptions = computed(() =>
  (props.textOnly ? TEXT_ONLY_HEADER_TYPES : HEADER_TYPES).map(type => ({
    value: type,
    label: headerTypeLabels.value[type],
  }))
);

const isMediaType = computed(() =>
  ['IMAGE', 'VIDEO', 'DOCUMENT'].includes(header.value.type)
);

const acceptAttribute = computed(() => ACCEPT_BY_TYPE[header.value.type] || '');

const setType = type => {
  header.value = { type, text: '', handle: '', fileName: '' };
};

const openFilePicker = () => {
  fileInput.value?.click();
};

const onFileSelected = async event => {
  const file = event.target.files[0];
  event.target.value = '';
  if (!file) return;

  isUploading.value = true;
  uploadError.value = '';

  try {
    const response = await store.dispatch('inboxes/uploadTemplateMedia', {
      inboxId: props.inboxId,
      file,
    });
    header.value = {
      ...header.value,
      handle: response.handle,
      fileName: file.name,
    };
  } catch (error) {
    uploadError.value = t(
      'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.HEADER.UPLOAD_ERROR'
    );
    useAlert(uploadError.value);
  } finally {
    isUploading.value = false;
  }
};
</script>

<template>
  <div class="space-y-2">
    <h3 class="font-semibold text-n-slate-12">
      {{ $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.HEADER.TITLE') }}
    </h3>

    <ComboBox
      :model-value="header.type"
      :options="headerTypeOptions"
      :placeholder="
        $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.HEADER.TYPE_LABEL')
      "
      @update:model-value="setType"
    />

    <Input
      v-if="header.type === 'TEXT'"
      :model-value="header.text"
      :label="$t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.HEADER.TEXT_LABEL')"
      :placeholder="
        $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.HEADER.TEXT_PLACEHOLDER')
      "
      @update:model-value="value => (header = { ...header, text: value })"
    />

    <div v-if="isMediaType" class="flex items-center gap-3">
      <input
        ref="fileInput"
        type="file"
        class="hidden"
        :accept="acceptAttribute"
        @change="onFileSelected"
      />
      <Button
        :label="
          header.fileName
            ? $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.HEADER.REPLACE_LABEL')
            : $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.HEADER.UPLOAD_LABEL')
        "
        variant="outline"
        color="slate"
        size="sm"
        :is-loading="isUploading"
        @click="openFilePicker"
      />
      <span v-if="header.fileName" class="text-body-main text-n-slate-11">
        {{
          $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.HEADER.UPLOADED', {
            name: header.fileName,
          })
        }}
      </span>
    </div>
  </div>
</template>
