<script setup>
import { computed, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';

import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import TemplateHeaderField from './TemplateHeaderField.vue';

const props = defineProps({
  inboxId: { type: Number, required: true },
  template: { type: Object, required: true },
});
const emit = defineEmits(['close', 'updated']);
const MAX_BUTTONS = 10;
const BUTTON_TYPES = ['QUICK_REPLY', 'URL', 'PHONE_NUMBER', 'COPY_CODE'];

const store = useStore();
const { t } = useI18n();

const findComponent = type =>
  (props.template.components || []).find(component => component.type === type);

const buttonExample = button => {
  if (button.type === 'COPY_CODE') return button.example || '';
  if (button.type === 'URL' && button.example?.length) return button.example[0];
  return '';
};

const normalizeButton = button => ({
  type: button.type,
  text: button.text || '',
  url: button.type === 'URL' ? button.url || '' : '',
  phone_number: button.type === 'PHONE_NUMBER' ? button.phone_number || '' : '',
  example: buttonExample(button),
  flow_id: button.type === 'FLOW' ? button.flow_id || '' : '',
  navigate_screen: button.type === 'FLOW' ? button.navigate_screen || '' : '',
});

const normalizeHeader = component => {
  if (!component) return { type: 'NONE', text: '', handle: '', fileName: '' };
  if (component.format === 'TEXT') {
    return {
      type: 'TEXT',
      text: component.text || '',
      handle: '',
      fileName: '',
    };
  }
  return {
    type: component.format,
    text: '',
    handle: component.example?.header_handle?.[0] || '',
    fileName: '',
  };
};

const headerComponent = findComponent('HEADER');
const bodyComponent = findComponent('BODY');
const footerComponent = findComponent('FOOTER');
const buttonsComponent = findComponent('BUTTONS');

const isSubmitting = ref(false);
const submitError = ref('');

const form = reactive({
  header: normalizeHeader(headerComponent),
  body: bodyComponent?.text || '',
  footer: footerComponent?.text || '',
  buttons: (buttonsComponent?.buttons || []).map(normalizeButton),
});

const bodySamples = reactive({});

const buttonTypeLabels = computed(() => ({
  QUICK_REPLY: t(
    'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.TYPES.QUICK_REPLY'
  ),
  URL: t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.TYPES.URL'),
  PHONE_NUMBER: t(
    'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.TYPES.PHONE_NUMBER'
  ),
  COPY_CODE: t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.TYPES.COPY_CODE'),
  CATALOG: t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.TYPES.CATALOG'),
  FLOW: t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.TYPES.FLOW'),
}));

const buttonTypeOptions = computed(() =>
  BUTTON_TYPES.map(type => ({
    value: type,
    label: buttonTypeLabels.value[type],
  }))
);

const detectedVariables = computed(() => {
  const matches = form.body.matchAll(/\{\{(\d+)\}\}/g);
  const numbers = [...new Set([...matches].map(match => Number(match[1])))];
  return numbers.sort((a, b) => a - b);
});

const addButton = type => {
  if (form.buttons.length >= MAX_BUTTONS) return;
  form.buttons.push({ type, text: '', url: '', phone_number: '', example: '' });
};

const removeButton = index => {
  form.buttons.splice(index, 1);
};

const buildTemplatePayload = () => ({
  category: props.template.category,
  header:
    form.header.type === 'NONE'
      ? undefined
      : {
          type: form.header.type,
          text: form.header.type === 'TEXT' ? form.header.text : undefined,
          handle: form.header.type !== 'TEXT' ? form.header.handle : undefined,
        },
  body: form.body,
  footer: form.footer || undefined,
  body_sample_values: detectedVariables.value.map(
    number => bodySamples[number] || ''
  ),
  buttons: form.buttons.map(button => ({
    type: button.type,
    text: button.text,
    url: button.type === 'URL' ? button.url : undefined,
    phone_number:
      button.type === 'PHONE_NUMBER' ? button.phone_number : undefined,
    example: ['COPY_CODE', 'URL'].includes(button.type)
      ? button.example || undefined
      : undefined,
    flow_id: button.type === 'FLOW' ? button.flow_id : undefined,
    navigate_screen:
      button.type === 'FLOW' ? button.navigate_screen || undefined : undefined,
  })),
});

const submit = async () => {
  isSubmitting.value = true;
  submitError.value = '';

  try {
    await store.dispatch('inboxes/updateMessageTemplate', {
      inboxId: props.inboxId,
      templateId: props.template.id,
      template: buildTemplatePayload(),
    });
    useAlert(t('MESSAGE_TEMPLATES_MGMT.EDIT.SUCCESS_MESSAGE'));
    emit('updated');
    emit('close');
  } catch (error) {
    submitError.value =
      error?.response?.data?.error ||
      t('MESSAGE_TEMPLATES_MGMT.EDIT.ERROR_MESSAGE');
    useAlert(submitError.value);
  } finally {
    isSubmitting.value = false;
  }
};
</script>

<template>
  <div class="p-6 space-y-4 max-h-[80vh] overflow-y-auto">
    <div>
      <h2 class="text-heading-2 text-n-slate-12">
        {{ $t('MESSAGE_TEMPLATES_MGMT.EDIT.TITLE', { name: template.name }) }}
      </h2>
      <p class="text-body-main text-n-slate-11">
        {{ $t('MESSAGE_TEMPLATES_MGMT.EDIT.DESCRIPTION') }}
      </p>
    </div>

    <TemplateHeaderField v-model="form.header" :inbox-id="inboxId" />

    <TextArea
      v-model="form.body"
      :label="$t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BODY.LABEL')"
      :placeholder="$t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BODY.PLACEHOLDER')"
      :max-length="1024"
      show-character-count
    />

    <div v-if="detectedVariables.length" class="space-y-2">
      <h3 class="font-semibold text-n-slate-12">
        {{ $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.VARIABLES.TITLE') }}
      </h3>
      <p class="text-body-main text-n-slate-11">
        {{ $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.VARIABLES.DESCRIPTION') }}
      </p>
      <Input
        v-for="number in detectedVariables"
        :key="number"
        v-model="bodySamples[number]"
        :label="`{{${number}}}`"
        :placeholder="
          $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.VARIABLES.PLACEHOLDER', {
            variable: number,
          })
        "
      />
    </div>

    <TextArea
      v-model="form.footer"
      :label="$t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.FOOTER.LABEL')"
      :placeholder="
        $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.FOOTER.PLACEHOLDER')
      "
      :max-length="60"
      show-character-count
    />

    <div class="space-y-3">
      <h3 class="font-semibold text-n-slate-12">
        {{ $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.TITLE') }}
      </h3>

      <div
        v-for="(button, index) in form.buttons"
        :key="index"
        class="p-3 rounded-lg border border-n-weak space-y-2"
      >
        <div class="flex items-center justify-between">
          <span class="text-body-main font-medium text-n-slate-12">
            {{ buttonTypeLabels[button.type] }}
          </span>
          <Button
            icon="i-lucide-trash-2"
            variant="ghost"
            color="ruby"
            size="xs"
            :label="
              $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.REMOVE_BUTTON')
            "
            @click="removeButton(index)"
          />
        </div>

        <Input
          v-model="button.text"
          :label="
            $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.TEXT')
          "
        />
        <Input
          v-if="button.type === 'URL'"
          v-model="button.url"
          :label="$t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.URL')"
        />
        <Input
          v-if="button.type === 'PHONE_NUMBER'"
          v-model="button.phone_number"
          :label="
            $t(
              'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.PHONE_NUMBER'
            )
          "
        />
        <Input
          v-if="button.type === 'COPY_CODE'"
          v-model="button.example"
          :label="
            $t(
              'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.EXAMPLE_CODE'
            )
          "
        />
        <Input
          v-if="button.type === 'FLOW'"
          v-model="button.flow_id"
          :label="
            $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.FLOW_ID')
          "
          :message="
            $t(
              'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.FLOW_ID_HINT'
            )
          "
        />
        <Input
          v-if="button.type === 'FLOW'"
          v-model="button.navigate_screen"
          :label="
            $t(
              'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.NAVIGATE_SCREEN'
            )
          "
        />
      </div>

      <p
        v-if="form.buttons.length >= MAX_BUTTONS"
        class="text-body-main text-n-slate-11"
      >
        {{
          $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.MAX_REACHED', {
            count: MAX_BUTTONS,
          })
        }}
      </p>
      <ComboBox
        v-else
        :options="buttonTypeOptions"
        :placeholder="
          $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.ADD_BUTTON')
        "
        @update:model-value="addButton"
      />
    </div>

    <p v-if="submitError" class="text-body-main text-n-ruby-9">
      {{ submitError }}
    </p>

    <div class="flex items-center gap-3 justify-end">
      <Button
        :label="$t('MESSAGE_TEMPLATES_MGMT.EDIT.CANCEL_BUTTON')"
        variant="outline"
        color="slate"
        @click="emit('close')"
      />
      <Button
        :label="$t('MESSAGE_TEMPLATES_MGMT.EDIT.SUBMIT_BUTTON')"
        :is-loading="isSubmitting"
        @click="submit"
      />
    </div>
  </div>
</template>
