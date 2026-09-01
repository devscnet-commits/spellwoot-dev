<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useStore } from 'dashboard/composables/store';

import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import TemplateHeaderField from './TemplateHeaderField.vue';

const MAX_BUTTONS = 10;
const AUTH_MAX_BUTTONS = 1;
const BUTTON_TYPES = ['QUICK_REPLY', 'URL', 'PHONE_NUMBER', 'COPY_CODE'];
const AUTH_BUTTON_TYPES = ['COPY_CODE'];
const AUTH_BODY_TEXT = '{{1}} é o seu código de verificação.';
const LANGUAGES = [
  { value: 'pt_BR', label: 'Português (Brasil)' },
  { value: 'en_US', label: 'English (US)' },
  { value: 'es_ES', label: 'Español (España)' },
  { value: 'es_MX', label: 'Español (México)' },
  { value: 'fr', label: 'Français' },
  { value: 'it', label: 'Italiano' },
  { value: 'de', label: 'Deutsch' },
];

const store = useStore();
const route = useRoute();
const router = useRouter();
const { t } = useI18n();

const inboxId = Number(route.query.inbox_id);

const currentStep = ref(1);
const isSubmitting = ref(false);
const submitError = ref('');

const form = reactive({
  category: 'MARKETING',
  name: '',
  language: 'pt_BR',
  header: { type: 'NONE', text: '', handle: '', fileName: '' },
  body: '',
  footer: '',
  buttons: [],
});

const bodySamples = reactive({});

const categories = computed(() => [
  {
    id: 'MARKETING',
    label: t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.CATEGORIES.MARKETING.LABEL'),
    description: t(
      'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.CATEGORIES.MARKETING.DESCRIPTION'
    ),
  },
  {
    id: 'UTILITY',
    label: t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.CATEGORIES.UTILITY.LABEL'),
    description: t(
      'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.CATEGORIES.UTILITY.DESCRIPTION'
    ),
  },
  {
    id: 'AUTHENTICATION',
    label: t(
      'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.CATEGORIES.AUTHENTICATION.LABEL'
    ),
    description: t(
      'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.CATEGORIES.AUTHENTICATION.DESCRIPTION'
    ),
  },
]);

const buttonTypeLabels = computed(() => ({
  QUICK_REPLY: t(
    'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.TYPES.QUICK_REPLY'
  ),
  URL: t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.TYPES.URL'),
  PHONE_NUMBER: t(
    'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.TYPES.PHONE_NUMBER'
  ),
  COPY_CODE: t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.TYPES.COPY_CODE'),
}));

const isAuthentication = computed(() => form.category === 'AUTHENTICATION');

const maxButtons = computed(() =>
  isAuthentication.value ? AUTH_MAX_BUTTONS : MAX_BUTTONS
);

const buttonTypeOptions = computed(() =>
  (isAuthentication.value ? AUTH_BUTTON_TYPES : BUTTON_TYPES).map(type => ({
    value: type,
    label: buttonTypeLabels.value[type],
  }))
);

const detectedVariables = computed(() => {
  const matches = form.body.matchAll(/\{\{(\d+)\}\}/g);
  const numbers = [...new Set([...matches].map(match => Number(match[1])))];
  return numbers.sort((a, b) => a - b);
});

watch(
  () => form.category,
  newCategory => {
    if (newCategory !== 'AUTHENTICATION') return;

    form.header = { type: 'NONE', text: '', handle: '', fileName: '' };
    form.body = AUTH_BODY_TEXT;
    form.footer = '';
    form.buttons = form.buttons
      .filter(button => button.type === 'COPY_CODE')
      .slice(0, AUTH_MAX_BUTTONS);
  }
);

const goToStep2 = () => {
  currentStep.value = 2;
};

const goToStep1 = () => {
  currentStep.value = 1;
};

const addButton = type => {
  if (form.buttons.length >= maxButtons.value) return;

  form.buttons.push({
    type,
    text: '',
    url: '',
    phone_number: '',
    example: '',
  });
};

const removeButton = index => {
  form.buttons.splice(index, 1);
};

const buildTemplatePayload = () => ({
  name: form.name,
  category: form.category,
  language: form.language,
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
  })),
});

const submitTemplate = async () => {
  isSubmitting.value = true;
  submitError.value = '';

  try {
    await store.dispatch('inboxes/createMessageTemplate', {
      inboxId,
      template: buildTemplatePayload(),
    });
    useAlert(t('MESSAGE_TEMPLATES_MGMT.CREATE.SUCCESS_MESSAGE'));
    router.push({
      name: 'message_templates_list',
      query: { inbox_id: inboxId },
    });
  } catch (error) {
    submitError.value =
      error?.response?.data?.error ||
      t('MESSAGE_TEMPLATES_MGMT.CREATE.ERROR_MESSAGE');
    useAlert(submitError.value);
  } finally {
    isSubmitting.value = false;
  }
};
</script>

<template>
  <SettingsLayout>
    <template #header>
      <BaseSettingsHeader
        :title="$t('MESSAGE_TEMPLATES_MGMT.CREATE.HEADER')"
        :back-button-label="
          $t('MESSAGE_TEMPLATES_MGMT.CREATE.BACK_BUTTON_LABEL')
        "
        feature-name="message-templates"
      />
    </template>
    <template #body>
      <div v-if="currentStep === 1" class="p-4 max-w-2xl space-y-4">
        <div>
          <h2 class="text-heading-2 text-n-slate-12">
            {{ $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.TITLE') }}
          </h2>
          <p class="text-body-main text-n-slate-11">
            {{ $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.DESCRIPTION') }}
          </p>
        </div>

        <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
          <button
            v-for="category in categories"
            :key="category.id"
            type="button"
            class="text-left p-4 rounded-xl border transition-all"
            :class="
              form.category === category.id
                ? 'border-n-brand bg-n-alpha-2'
                : 'border-n-weak hover:border-n-slate-6'
            "
            @click="form.category = category.id"
          >
            <span class="block font-semibold text-n-slate-12">
              {{ category.label }}
            </span>
            <span class="block text-body-main text-n-slate-11 mt-1">
              {{ category.description }}
            </span>
          </button>
        </div>

        <Button
          :label="$t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.NEXT_BUTTON')"
          @click="goToStep2"
        />
      </div>

      <div v-else class="p-4 max-w-2xl space-y-6">
        <h2 class="text-heading-2 text-n-slate-12">
          {{ $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.TITLE') }}
        </h2>

        <Input
          v-model="form.name"
          :label="$t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.NAME.LABEL')"
          :placeholder="
            $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.NAME.PLACEHOLDER')
          "
          :message="$t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.NAME.HINT')"
        />

        <div>
          <label class="text-body-main text-n-slate-11">
            {{ $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.LANGUAGE.LABEL') }}
          </label>
          <ComboBox
            v-model="form.language"
            :options="LANGUAGES"
            :placeholder="
              $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.LANGUAGE.PLACEHOLDER')
            "
          />
        </div>

        <TemplateHeaderField
          v-if="!isAuthentication"
          v-model="form.header"
          :inbox-id="inboxId"
        />

        <TextArea
          v-model="form.body"
          :label="$t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BODY.LABEL')"
          :placeholder="
            $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BODY.PLACEHOLDER')
          "
          :message="
            isAuthentication
              ? $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BODY.AUTH_HINT')
              : ''
          "
          :disabled="isAuthentication"
          :max-length="1024"
          show-character-count
        />

        <div v-if="detectedVariables.length" class="space-y-2">
          <h3 class="font-semibold text-n-slate-12">
            {{ $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.VARIABLES.TITLE') }}
          </h3>
          <p class="text-body-main text-n-slate-11">
            {{
              $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.VARIABLES.DESCRIPTION')
            }}
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
          v-if="!isAuthentication"
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
                  $t(
                    'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.REMOVE_BUTTON'
                  )
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
              :label="
                $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.URL')
              "
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
          </div>

          <p
            v-if="form.buttons.length >= maxButtons"
            class="text-body-main text-n-slate-11"
          >
            {{
              $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.MAX_REACHED', {
                count: maxButtons,
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

        <div class="flex items-center gap-3">
          <Button
            :label="$t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BACK_BUTTON')"
            variant="outline"
            color="slate"
            @click="goToStep1"
          />
          <Button
            :label="$t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.SUBMIT_BUTTON')"
            :is-loading="isSubmitting"
            @click="submitTemplate"
          />
        </div>
      </div>
    </template>
  </SettingsLayout>
</template>
