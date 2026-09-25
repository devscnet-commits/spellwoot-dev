<script setup>
import { computed, reactive, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';

import Button from 'dashboard/components-next/button/Button.vue';
import CardLayout from 'dashboard/components-next/CardLayout.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import TemplateHeaderField from './TemplateHeaderField.vue';
import TemplateBodyField from './TemplateBodyField.vue';
import TemplateButtonsField from './TemplateButtonsField.vue';
import TemplateWhatsAppPreview from './TemplateWhatsAppPreview.vue';
import {
  findComponent,
  normalizeTemplateHeader,
  normalizeTemplateButton,
  bodySamplesFromComponent,
} from './templateComponents';
import { PARAMETER_FORMATS, detectVariables } from './templateVariables';

const props = defineProps({
  inboxId: { type: Number, required: true },
  template: { type: Object, required: true },
});
const emit = defineEmits(['close', 'updated']);
const MAX_BUTTONS = 10;
const BUTTON_TYPES = ['QUICK_REPLY', 'URL', 'PHONE_NUMBER', 'COPY_CODE'];

const store = useStore();
const { t } = useI18n();

const headerComponent = findComponent(props.template.components, 'HEADER');
const bodyComponent = findComponent(props.template.components, 'BODY');
const footerComponent = findComponent(props.template.components, 'FOOTER');
const buttonsComponent = findComponent(props.template.components, 'BUTTONS');
const isCallPermissionRequest = !!findComponent(
  props.template.components,
  'CALL_PERMISSION_REQUEST'
);

const isSubmitting = ref(false);
const submitError = ref('');

const form = reactive({
  header: normalizeTemplateHeader(headerComponent),
  body: bodyComponent?.text || '',
  footer: footerComponent?.text || '',
  buttons: (buttonsComponent?.buttons || []).map(normalizeTemplateButton),
});

const bodySamples = reactive(bodySamplesFromComponent(bodyComponent));
const parameterFormat =
  props.template.parameter_format === PARAMETER_FORMATS.NAMED
    ? PARAMETER_FORMATS.NAMED
    : PARAMETER_FORMATS.POSITIONAL;

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
  ORDER_DETAILS: t(
    'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.TYPES.ORDER_DETAILS'
  ),
}));

const buttonTypeOptions = computed(() =>
  BUTTON_TYPES.map(type => ({
    value: type,
    label: buttonTypeLabels.value[type],
  }))
);

const detectedVariables = computed(() =>
  detectVariables(form.body, parameterFormat)
);

const buildTemplatePayload = () => ({
  category: props.template.category,
  call_permission_request: isCallPermissionRequest || undefined,
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
  parameter_format:
    parameterFormat === PARAMETER_FORMATS.NAMED ? 'NAMED' : undefined,
  body_variable_names:
    parameterFormat === PARAMETER_FORMATS.NAMED
      ? detectedVariables.value
      : undefined,
  body_sample_values: detectedVariables.value.map(
    key => bodySamples[key] || ''
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

const templateBodyFieldRef = ref(null);

const submit = async () => {
  if (templateBodyFieldRef.value?.hasDanglingVariable) {
    submitError.value = t(
      'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.VALIDATION.BODY_DANGLING_VARIABLE'
    );
    useAlert(submitError.value);
    return;
  }

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

    <div class="flex flex-col items-start gap-6 lg:flex-row">
      <div class="w-full space-y-6 lg:max-w-2xl">
        <CardLayout>
          <TemplateHeaderField
            v-model="form.header"
            :inbox-id="inboxId"
            :text-only="isCallPermissionRequest"
          />

          <TemplateBodyField
            ref="templateBodyFieldRef"
            v-model="form.body"
            v-model:samples="bodySamples"
            :parameter-format="parameterFormat"
          />

          <TextArea
            v-model="form.footer"
            :label="$t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.FOOTER.LABEL')"
            :placeholder="
              $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.FOOTER.PLACEHOLDER')
            "
            :max-length="60"
            show-character-count
          />
        </CardLayout>

        <CardLayout v-if="!isCallPermissionRequest">
          <TemplateButtonsField
            v-model="form.buttons"
            :button-type-options="buttonTypeOptions"
            :button-type-labels="buttonTypeLabels"
            :max-buttons="MAX_BUTTONS"
            :inbox-id="inboxId"
          />
        </CardLayout>

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
            :disabled="isSubmitting"
            @click="submit"
          />
        </div>
      </div>

      <div class="sticky hidden w-full space-y-3 top-4 lg:block lg:max-w-sm">
        <TemplateWhatsAppPreview
          :header="form.header"
          :body="form.body"
          :footer="form.footer"
          :buttons="isCallPermissionRequest ? [] : form.buttons"
          :samples="bodySamples"
        />
        <div
          class="flex items-start gap-2 p-3 border rounded-lg border-n-teal-6 bg-n-teal-2 dark:bg-n-teal-3"
        >
          <span
            class="flex-shrink-0 mt-0.5 size-4 i-lucide-check-circle-2 text-n-teal-11"
          />
          <p class="text-body-main text-n-teal-12">
            <span class="font-semibold">
              {{
                $t(
                  'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.PREVIEW.LIVE_NOTE_TITLE'
                )
              }}:
            </span>
            {{
              $t(
                'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.PREVIEW.LIVE_NOTE_DESCRIPTION'
              )
            }}
          </p>
        </div>
      </div>
    </div>
  </div>
</template>
