<script setup>
import { computed, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useStore, useStoreGetters } from 'dashboard/composables/store';
import { INBOX_TYPES } from 'dashboard/helper/inbox';

import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';
import Banner from 'dashboard/components-next/banner/Banner.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import CardLayout from 'dashboard/components-next/CardLayout.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import TemplateHeaderField from './TemplateHeaderField.vue';
import TemplateBodyField from './TemplateBodyField.vue';
import TemplateWhatsAppPreview from './TemplateWhatsAppPreview.vue';
import TemplateSubmitConfirmModal from './TemplateSubmitConfirmModal.vue';
import { CATEGORY_ICONS } from './templateCategoryIcons';

const MAX_BUTTONS = 10;
const AUTH_MAX_BUTTONS = 1;
const CATALOG_MAX_BUTTONS = 1;
const FLOW_MAX_BUTTONS = 1;
const ORDER_DETAILS_MAX_BUTTONS = 1;
const BUTTON_TYPES = ['QUICK_REPLY', 'URL', 'PHONE_NUMBER', 'COPY_CODE'];
const AUTH_BUTTON_TYPES = ['COPY_CODE'];
const CATALOG_BUTTON_TYPES = ['CATALOG'];
const FLOW_BUTTON_TYPES = ['FLOW'];
const ORDER_DETAILS_BUTTON_TYPES = ['ORDER_DETAILS'];
const AUTH_BODY_TEXT = '{{1}} é o seu código de verificação.';
const MARKETING_SUBTYPES = [
  'STANDARD',
  'CATALOG',
  'FLOWS',
  'ORDER_DETAILS',
  'CALL_PERMISSION_REQUEST',
];
const SELECTABLE_MARKETING_SUBTYPES = [
  'STANDARD',
  'CATALOG',
  'FLOWS',
  'ORDER_DETAILS',
  'CALL_PERMISSION_REQUEST',
];
// Meta only offers multiple template structures under Marketing — Utility and Authentication
// templates always use the standard header/body/footer/button layout, so their "type" section
// just shows Padrão, already selected, for visual consistency with the Marketing tab.
const SINGLE_STANDARD_SUBTYPE = ['STANDARD'];
const LANGUAGES = [
  { value: 'pt_BR', label: 'Português (Brasil)' },
  { value: 'en_US', label: 'English (US)' },
  { value: 'es_ES', label: 'Español (España)' },
  { value: 'es_MX', label: 'Español (México)' },
  { value: 'fr', label: 'Français' },
  { value: 'it', label: 'Italiano' },
  { value: 'de', label: 'Deutsch' },
];
const INBOX_AVATAR_CLASSES = [
  'bg-n-teal-9',
  'bg-n-blue-9',
  'bg-n-violet-9',
  'bg-n-amber-9',
];

const store = useStore();
const getters = useStoreGetters();
const route = useRoute();
const router = useRouter();
const { t } = useI18n();

const whatsAppCloudInboxes = computed(() =>
  (getters['inboxes/getInboxes'].value || []).filter(
    inbox =>
      inbox.channel_type === INBOX_TYPES.WHATSAPP &&
      inbox.provider === 'whatsapp_cloud'
  )
);

const queryInboxId = Number(route.query.inbox_id);
const inboxId = ref(
  whatsAppCloudInboxes.value.some(inbox => inbox.id === queryInboxId)
    ? queryInboxId
    : whatsAppCloudInboxes.value[0]?.id
);

const inboxAvatarClass = index =>
  INBOX_AVATAR_CLASSES[index % INBOX_AVATAR_CLASSES.length];

const currentStep = ref(1);
const isSubmitting = ref(false);
const submitError = ref('');
const showConfirmModal = ref(false);

const form = reactive({
  category: 'MARKETING',
  subtype: 'STANDARD',
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
    icon: CATEGORY_ICONS.MARKETING,
    label: t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.CATEGORIES.MARKETING.LABEL'),
    description: t(
      'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.CATEGORIES.MARKETING.DESCRIPTION'
    ),
  },
  {
    id: 'UTILITY',
    icon: CATEGORY_ICONS.UTILITY,
    label: t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.CATEGORIES.UTILITY.LABEL'),
    description: t(
      'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.CATEGORIES.UTILITY.DESCRIPTION'
    ),
  },
  {
    id: 'AUTHENTICATION',
    icon: CATEGORY_ICONS.AUTHENTICATION,
    label: t(
      'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.CATEGORIES.AUTHENTICATION.LABEL'
    ),
    description: t(
      'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.CATEGORIES.AUTHENTICATION.DESCRIPTION'
    ),
  },
]);

const isMarketing = computed(() => form.category === 'MARKETING');

const subtypeLabels = computed(() => ({
  STANDARD: t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.STANDARD.LABEL'),
  CATALOG: t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.CATALOG.LABEL'),
  FLOWS: t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.FLOWS.LABEL'),
  ORDER_DETAILS: t(
    'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.ORDER_DETAILS.LABEL'
  ),
  CALL_PERMISSION_REQUEST: t(
    'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.CALL_PERMISSION_REQUEST.LABEL'
  ),
}));

const subtypeDescriptions = computed(() => ({
  STANDARD: t(
    'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.STANDARD.DESCRIPTION'
  ),
  CATALOG: t(
    'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.CATALOG.DESCRIPTION'
  ),
  FLOWS: t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.FLOWS.DESCRIPTION'),
  ORDER_DETAILS: t(
    'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.ORDER_DETAILS.DESCRIPTION'
  ),
  CALL_PERMISSION_REQUEST: t(
    'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.CALL_PERMISSION_REQUEST.DESCRIPTION'
  ),
}));

const categorySubtypeIds = computed(() =>
  isMarketing.value ? MARKETING_SUBTYPES : SINGLE_STANDARD_SUBTYPE
);

const subtypes = computed(() =>
  categorySubtypeIds.value.map(id => ({
    id,
    label: subtypeLabels.value[id],
    description: subtypeDescriptions.value[id],
    comingSoon: !SELECTABLE_MARKETING_SUBTYPES.includes(id),
  }))
);

const currentCategoryLabel = computed(
  () => categories.value.find(category => category.id === form.category)?.label
);

const currentLanguageLabel = computed(
  () => LANGUAGES.find(language => language.value === form.language)?.label
);

const currentInbox = computed(() =>
  getters['inboxes/getInbox'].value(inboxId.value)
);

const currentInboxSummary = computed(() => {
  if (!currentInbox.value?.name) return '';
  if (!currentInbox.value.phone_number) return currentInbox.value.name;

  return `${currentInbox.value.name} · ${currentInbox.value.phone_number}`;
});

const currentCategorySubtypeSummary = computed(
  () => `${currentCategoryLabel.value} · ${subtypeLabels.value[form.subtype]}`
);

const subtypesSectionTitle = computed(() =>
  t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.TITLE', {
    category: currentCategoryLabel.value,
  })
);

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

const isAuthentication = computed(() => form.category === 'AUTHENTICATION');
const isCatalog = computed(
  () => isMarketing.value && form.subtype === 'CATALOG'
);
const isFlow = computed(() => isMarketing.value && form.subtype === 'FLOWS');
const isOrderDetails = computed(
  () => isMarketing.value && form.subtype === 'ORDER_DETAILS'
);
// CALL_PERMISSION_REQUEST is its own template component (a sibling of HEADER/BODY/FOOTER),
// not a button — it has no BUTTONS section and only allows a TEXT (or no) header.
const isCallPermissionRequest = computed(
  () => isMarketing.value && form.subtype === 'CALL_PERMISSION_REQUEST'
);

const maxButtons = computed(() => {
  if (isAuthentication.value) return AUTH_MAX_BUTTONS;
  if (isCatalog.value) return CATALOG_MAX_BUTTONS;
  if (isFlow.value) return FLOW_MAX_BUTTONS;
  if (isOrderDetails.value) return ORDER_DETAILS_MAX_BUTTONS;
  return MAX_BUTTONS;
});

// Derived from the same category/subtype rules that drive the form itself,
// rather than hand-written per subtype, so it can't drift from what's
// actually editable.
const customizableAreas = computed(() => {
  const areas = [];
  if (isAuthentication.value) {
    areas.push(
      t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.AREA_CODE_SAMPLE')
    );
  } else {
    areas.push(t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.AREA_HEADER'));
    areas.push(t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.AREA_BODY'));
    areas.push(t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.AREA_FOOTER'));
  }
  if (!isCallPermissionRequest.value) {
    areas.push(
      t(
        'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.AREA_BUTTONS',
        maxButtons.value
      )
    );
  }
  return areas.join(', ');
});

const buttonTypeOptions = computed(() => {
  let types = BUTTON_TYPES;
  if (isAuthentication.value) types = AUTH_BUTTON_TYPES;
  else if (isCatalog.value) types = CATALOG_BUTTON_TYPES;
  else if (isFlow.value) types = FLOW_BUTTON_TYPES;
  else if (isOrderDetails.value) types = ORDER_DETAILS_BUTTON_TYPES;

  return types.map(type => ({
    value: type,
    label: buttonTypeLabels.value[type],
  }));
});

const detectedVariables = computed(() => {
  const matches = form.body.matchAll(/\{\{(\d+)\}\}/g);
  const numbers = [...new Set([...matches].map(match => Number(match[1])))];
  return numbers.sort((a, b) => a - b);
});

watch(
  () => form.category,
  newCategory => {
    if (newCategory !== 'MARKETING') form.subtype = 'STANDARD';

    if (newCategory !== 'AUTHENTICATION') return;

    form.header = { type: 'NONE', text: '', handle: '', fileName: '' };
    form.body = AUTH_BODY_TEXT;
    form.footer = '';
    form.buttons = form.buttons
      .filter(button => button.type === 'COPY_CODE')
      .slice(0, AUTH_MAX_BUTTONS);
  }
);

watch(isCatalog, newIsCatalog => {
  form.buttons = newIsCatalog
    ? form.buttons
        .filter(button => button.type === 'CATALOG')
        .slice(0, CATALOG_MAX_BUTTONS)
    : form.buttons.filter(button => button.type !== 'CATALOG');
});

watch(isFlow, newIsFlow => {
  form.buttons = newIsFlow
    ? form.buttons
        .filter(button => button.type === 'FLOW')
        .slice(0, FLOW_MAX_BUTTONS)
    : form.buttons.filter(button => button.type !== 'FLOW');
});

watch(isOrderDetails, newIsOrderDetails => {
  form.buttons = newIsOrderDetails
    ? form.buttons
        .filter(button => button.type === 'ORDER_DETAILS')
        .slice(0, ORDER_DETAILS_MAX_BUTTONS)
    : form.buttons.filter(button => button.type !== 'ORDER_DETAILS');
});

watch(isCallPermissionRequest, newIsCallPermissionRequest => {
  if (!newIsCallPermissionRequest) return;

  form.buttons = [];
  if (!['NONE', 'TEXT'].includes(form.header.type)) {
    form.header = { type: 'NONE', text: '', handle: '', fileName: '' };
  }
});

const selectSubtype = subtype => {
  if (subtype.comingSoon) return;
  form.subtype = subtype.id;
};

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
    flow_id: '',
    navigate_screen: '',
  });
};

const removeButton = index => {
  form.buttons.splice(index, 1);
};

const buildTemplatePayload = () => ({
  name: form.name,
  category: form.category,
  language: form.language,
  call_permission_request: isCallPermissionRequest.value || undefined,
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

const submitTemplate = async () => {
  isSubmitting.value = true;
  submitError.value = '';

  try {
    await store.dispatch('inboxes/createMessageTemplate', {
      inboxId: inboxId.value,
      template: buildTemplatePayload(),
    });
    useAlert(t('MESSAGE_TEMPLATES_MGMT.CREATE.SUCCESS_MESSAGE'));
    router.push({
      name: 'message_templates_list',
      query: { inbox_id: inboxId.value },
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

        <CardLayout v-if="whatsAppCloudInboxes.length">
          <div class="flex items-center justify-between w-full">
            <div>
              <h3 class="flex items-center gap-2 font-semibold text-n-slate-12">
                <Icon icon="i-lucide-inbox" class="flex-shrink-0 size-4" />
                {{ $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.INBOX.TITLE') }}
              </h3>
              <p class="mt-1 text-body-main text-n-slate-11">
                {{
                  $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.INBOX.DESCRIPTION')
                }}
              </p>
            </div>
            <span
              class="flex-shrink-0 px-2 py-0.5 text-xs font-medium rounded-full bg-n-slate-3 text-n-slate-11"
            >
              {{
                $t(
                  'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.INBOX.ACTIVE_COUNT',
                  whatsAppCloudInboxes.length
                )
              }}
            </span>
          </div>

          <div class="grid w-full grid-cols-1 gap-3 sm:grid-cols-2">
            <button
              v-for="(inbox, index) in whatsAppCloudInboxes"
              :key="inbox.id"
              type="button"
              class="flex items-start gap-3 p-3 text-left border rounded-xl transition-all"
              :class="
                inboxId === inbox.id
                  ? 'border-n-brand bg-n-alpha-2'
                  : 'border-n-weak hover:border-n-slate-6'
              "
              @click="inboxId = inbox.id"
            >
              <span
                class="flex items-center justify-center flex-shrink-0 text-sm font-semibold text-white rounded-full size-8"
                :class="inboxAvatarClass(index)"
              >
                {{ inbox.name.charAt(0).toUpperCase() }}
              </span>
              <span class="min-w-0">
                <span class="block font-medium truncate text-n-slate-12">
                  {{ inbox.name }}
                </span>
                <span
                  v-if="inbox.phone_number"
                  class="block text-xs text-n-slate-10"
                >
                  {{ inbox.phone_number }}
                </span>
              </span>
            </button>
          </div>
        </CardLayout>

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
            <span class="flex items-center gap-2 font-semibold text-n-slate-12">
              <Icon :icon="category.icon" class="flex-shrink-0 size-4" />
              {{ category.label }}
            </span>
            <span class="block text-body-main text-n-slate-11 mt-1">
              {{ category.description }}
            </span>
          </button>
        </div>

        <Banner color="amber">
          <div class="flex items-center gap-2">
            <Icon icon="i-lucide-info" class="flex-shrink-0 size-4" />
            <span>
              {{ $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.META_GUIDELINE') }}
            </span>
          </div>
        </Banner>

        <div class="space-y-2">
          <h3 class="font-semibold text-n-slate-12">
            {{ subtypesSectionTitle }}
          </h3>
          <p class="text-body-main text-n-slate-11">
            {{
              $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.DESCRIPTION')
            }}
          </p>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <button
              v-for="subtype in subtypes"
              :key="subtype.id"
              type="button"
              class="text-left p-4 rounded-xl border transition-all"
              :class="[
                subtype.comingSoon
                  ? 'opacity-50 cursor-not-allowed border-n-weak'
                  : 'cursor-pointer',
                !subtype.comingSoon && form.subtype === subtype.id
                  ? 'border-n-brand bg-n-alpha-2'
                  : 'border-n-weak hover:border-n-slate-6',
              ]"
              @click="selectSubtype(subtype)"
            >
              <span class="flex items-center gap-2">
                <span class="font-semibold text-n-slate-12">
                  {{ subtype.label }}
                </span>
                <span
                  v-if="subtype.comingSoon"
                  class="text-caption px-1.5 py-0.5 rounded-full bg-n-slate-3 text-n-slate-11"
                >
                  {{
                    $t(
                      'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.COMING_SOON'
                    )
                  }}
                </span>
              </span>
              <span class="block text-body-main text-n-slate-11 mt-1">
                {{ subtype.description }}
              </span>
            </button>
          </div>
        </div>

        <Button
          :label="$t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.NEXT_BUTTON')"
          @click="goToStep2"
        />
      </div>

      <div v-else class="p-4">
        <h2 class="mb-6 text-heading-2 text-n-slate-12">
          {{ $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.TITLE') }}
        </h2>

        <div class="flex flex-col items-start gap-6 lg:flex-row">
          <div class="w-full space-y-6 lg:max-w-2xl">
            <CardLayout>
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
                  {{
                    $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.LANGUAGE.LABEL')
                  }}
                </label>
                <ComboBox
                  v-model="form.language"
                  :options="LANGUAGES"
                  :placeholder="
                    $t(
                      'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.LANGUAGE.PLACEHOLDER'
                    )
                  "
                />
              </div>
            </CardLayout>

            <CardLayout>
              <TemplateHeaderField
                v-if="!isAuthentication"
                v-model="form.header"
                :inbox-id="inboxId"
                :text-only="isCallPermissionRequest"
              />

              <TemplateBodyField
                v-if="!isAuthentication"
                v-model="form.body"
                v-model:samples="bodySamples"
              />
              <TextArea
                v-else
                v-model="form.body"
                :label="$t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BODY.LABEL')"
                :message="
                  $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BODY.AUTH_HINT')
                "
                disabled
                :max-length="1024"
                show-character-count
              />

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
            </CardLayout>

            <CardLayout v-if="!isCallPermissionRequest">
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
                    $t(
                      'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.TEXT'
                    )
                  "
                />

                <Input
                  v-if="button.type === 'URL'"
                  v-model="button.url"
                  :label="
                    $t(
                      'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.URL'
                    )
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

                <Input
                  v-if="button.type === 'FLOW'"
                  v-model="button.flow_id"
                  :label="
                    $t(
                      'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.FLOW_ID'
                    )
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
                v-if="form.buttons.length >= maxButtons"
                class="text-body-main text-n-slate-11"
              >
                {{
                  $t(
                    'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.MAX_REACHED',
                    {
                      count: maxButtons,
                    }
                  )
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
            </CardLayout>

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
                :label="
                  $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.SUBMIT_BUTTON')
                "
                @click="showConfirmModal = true"
              />
            </div>
          </div>

          <div
            class="sticky hidden w-full space-y-3 top-4 lg:block lg:max-w-sm"
          >
            <div class="flex items-center justify-between gap-2">
              <span class="text-xs truncate text-n-slate-10">
                {{ currentInboxSummary }}
              </span>
              <span
                class="flex-shrink-0 px-2 py-0.5 text-xs font-medium rounded-full bg-n-blue-3 text-n-blue-11"
              >
                {{ currentCategorySubtypeSummary }}
              </span>
            </div>

            <TemplateWhatsAppPreview
              :header="form.header"
              :body="form.body"
              :footer="isAuthentication ? '' : form.footer"
              :buttons="isCallPermissionRequest ? [] : form.buttons"
              :samples="bodySamples"
            />

            <div
              class="p-4 space-y-2 border rounded-xl border-n-weak bg-n-solid-2"
            >
              <h3 class="flex items-center gap-2 font-semibold text-n-slate-12">
                <span class="i-lucide-sparkles size-4 text-n-blue-9" />
                {{
                  $t(
                    'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.IDEAL_FOR_TITLE'
                  )
                }}
              </h3>
              <p class="text-body-main text-n-slate-11">
                {{ subtypeDescriptions[form.subtype] }}
              </p>

              <div class="pt-2 mt-2 border-t border-n-weak">
                <p class="mb-1 text-xs font-medium uppercase text-n-slate-10">
                  {{
                    $t(
                      'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.CUSTOMIZABLE_AREAS_TITLE'
                    )
                  }}
                </p>
                <p class="text-xs text-n-slate-11">{{ customizableAreas }}</p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </template>

    <woot-modal
      v-model:show="showConfirmModal"
      :on-close="() => (showConfirmModal = false)"
    >
      <TemplateSubmitConfirmModal
        :inbox-name="currentInbox?.name"
        :inbox-phone-number="currentInbox?.phone_number"
        :name="form.name"
        :category-label="currentCategoryLabel"
        :language-label="currentLanguageLabel"
        :body="form.body"
        :footer="isAuthentication ? '' : form.footer"
        :samples="bodySamples"
        :buttons="isCallPermissionRequest ? [] : form.buttons"
        :button-type-labels="buttonTypeLabels"
        :is-submitting="isSubmitting"
        @cancel="showConfirmModal = false"
        @confirm="submitTemplate"
      />
    </woot-modal>
  </SettingsLayout>
</template>
