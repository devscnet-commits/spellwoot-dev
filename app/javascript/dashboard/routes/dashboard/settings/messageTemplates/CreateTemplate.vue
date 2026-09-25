<script setup>
import { computed, onActivated, reactive, ref, watch } from 'vue';
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
import TemplateButtonsField from './TemplateButtonsField.vue';
import TemplatePreviewSidebar from './TemplatePreviewSidebar.vue';
import TemplateSubmitConfirmModal from './TemplateSubmitConfirmModal.vue';
import { CATEGORY_ICONS } from './templateCategoryIcons';

const MAX_BUTTONS = 10;
const AUTH_MAX_BUTTONS = 1;
const CATALOG_MAX_BUTTONS = 1;
const FLOW_MAX_BUTTONS = 1;
const ORDER_DETAILS_MAX_BUTTONS = 1;
// VOICE_CALL is the "Call request" button Meta lists among the types Utility templates accept: the
// customer taps it and calls the business inside WhatsApp. Not to be confused with PHONE_NUMBER
// (regular dialer) nor with the CALL_PERMISSION_REQUEST component, which is the opposite direction
// — the business asking permission to call the customer. Unlike CATALOG/FLOW/ORDER_DETAILS it isn't
// exclusive: Meta's own example combines it with a URL button in the same template.
const BUTTON_TYPES = [
  'QUICK_REPLY',
  'URL',
  'PHONE_NUMBER',
  'COPY_CODE',
  'VOICE_CALL',
];
const AUTH_BUTTON_TYPES = ['COPY_CODE'];
const CATALOG_BUTTON_TYPES = ['CATALOG'];
const FLOW_BUTTON_TYPES = ['FLOW'];
const ORDER_DETAILS_BUTTON_TYPES = ['ORDER_DETAILS'];
const AUTH_BODY_TEXT = '{{1}} é o seu código de verificação.';
// Mirrors the "Selecione o tipo" list WhatsApp Manager shows for each category. The previous
// version assumed only Marketing had multiple structures and hardcoded Padrão for the other two —
// Utility actually offers the same list minus Catalog (which is inherently promotional), so its
// tab only ever showed one of the five types Meta accepts. Authentication really does have a
// single type, but Meta labels it "Código de acesso de uso único", not "Padrão".
const SUBTYPES_BY_CATEGORY = {
  MARKETING: [
    'STANDARD',
    'CATALOG',
    'FLOWS',
    'ORDER_DETAILS',
    'CALL_PERMISSION_REQUEST',
  ],
  UTILITY: [
    'STANDARD',
    'FLOWS',
    'ORDER_STATUS',
    'ORDER_DETAILS',
    'CALL_PERMISSION_REQUEST',
  ],
  AUTHENTICATION: ['STANDARD'],
};
// Everything listed above is implemented; the flag stays so an unreleased type can be shown as
// "Em breve" instead of being hidden (Utility's "Status do pedido" is the next one).
const SELECTABLE_SUBTYPES = [
  'STANDARD',
  'CATALOG',
  'FLOWS',
  'ORDER_STATUS',
  'ORDER_DETAILS',
  'CALL_PERMISSION_REQUEST',
];
// Meta words the same type differently per category (Padrão and Flows), so the copy is keyed by
// "<CATEGORY>_<SUBTYPE>" when it differs and falls back to the shared key when it doesn't. Using
// Marketing's promotional wording under Utility was actively misleading: Utility forbids
// promotional content, and Meta silently recategorises templates that contain it.
const SUBTYPE_TEXT_OVERRIDES = {
  UTILITY: { STANDARD: 'UTILITY_STANDARD', FLOWS: 'UTILITY_FLOWS' },
  AUTHENTICATION: { STANDARD: 'AUTHENTICATION_STANDARD' },
};
const LANGUAGES = [
  { value: 'pt_BR', label: 'Português (Brasil)' },
  { value: 'en_US', label: 'English (US)' },
  { value: 'es_ES', label: 'Español (España)' },
  { value: 'es_MX', label: 'Español (México)' },
  { value: 'fr', label: 'Français' },
  { value: 'it', label: 'Italiano' },
  { value: 'de', label: 'Deutsch' },
];
// Mirrors Whatsapp::MessageTemplateValidator#name_error / #body_error — the two required-field
// checks worth catching client-side so the user isn't sent through the confirm modal only to
// bounce back to the same form. The rest of the backend's validation stays server-side only.
const NAME_REGEX = /^[a-z0-9_]+$/;
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

const resolveInboxId = () => {
  const queryInboxId = Number(route.query.inbox_id);
  return whatsAppCloudInboxes.value.some(inbox => inbox.id === queryInboxId)
    ? queryInboxId
    : whatsAppCloudInboxes.value[0]?.id;
};

const inboxId = ref(resolveInboxId());

// The inbox list is fetched by the dashboard, so on a hard refresh straight onto this route it is
// still empty when setup runs: resolveInboxId finds no match for ?inbox_id and no first inbox to
// fall back to, leaving inboxId undefined and the submit URL as .../inboxes/undefined/... (404).
// Nothing re-resolved it afterwards, so the form stayed broken until the user navigated away.
watch(whatsAppCloudInboxes, () => {
  if (inboxId.value === undefined) inboxId.value = resolveInboxId();
});

const inboxAvatarClass = index =>
  INBOX_AVATAR_CLASSES[index % INBOX_AVATAR_CLASSES.length];

const currentStep = ref(1);
const isSubmitting = ref(false);
const submitError = ref('');
const showConfirmModal = ref(false);
const templateBodyFieldRef = ref(null);

const initialFormState = () => ({
  category: 'MARKETING',
  subtype: 'STANDARD',
  name: '',
  language: 'pt_BR',
  header: { type: 'NONE', text: '', handle: '', fileName: '' },
  body: '',
  footer: '',
  buttons: [],
});

const form = reactive(initialFormState());
const bodySamples = reactive({});

// SettingsWrapper keeps this route's component instance alive (keep-alive keyed by the
// unparameterized path), so leaving mid-wizard and clicking "New template" again would
// otherwise resume the previous, unfinished draft instead of starting a blank one.
onActivated(() => {
  inboxId.value = resolveInboxId();
  currentStep.value = 1;
  Object.assign(form, initialFormState());
  Object.keys(bodySamples).forEach(key => delete bodySamples[key]);
  submitError.value = '';
  showConfirmModal.value = false;
});

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

const subtypeTextKey = id => SUBTYPE_TEXT_OVERRIDES[form.category]?.[id] || id;

const subtypeText = (id, field) =>
  t(
    `MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.${subtypeTextKey(id)}.${field}`
  );

const categorySubtypeIds = computed(
  () => SUBTYPES_BY_CATEGORY[form.category] || ['STANDARD']
);

const subtypes = computed(() =>
  categorySubtypeIds.value.map(id => ({
    id,
    label: subtypeText(id, 'LABEL'),
    description: subtypeText(id, 'DESCRIPTION'),
    comingSoon: !SELECTABLE_SUBTYPES.includes(id),
  }))
);

// Kept as maps (rather than a single "current subtype" string) because the preview sidebar and the
// confirmation modal both index them by form.subtype. Built from the current category's list, so
// the copy shown always matches the tab the user is on.
const subtypeLabels = computed(() =>
  Object.fromEntries(
    categorySubtypeIds.value.map(id => [id, subtypeText(id, 'LABEL')])
  )
);

const subtypeDescriptions = computed(() =>
  Object.fromEntries(
    categorySubtypeIds.value.map(id => [id, subtypeText(id, 'DESCRIPTION')])
  )
);

const currentCategoryLabel = computed(
  () => categories.value.find(category => category.id === form.category)?.label
);

const currentCategoryDescription = computed(
  () =>
    categories.value.find(category => category.id === form.category)
      ?.description
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
  VOICE_CALL: t(
    'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.TYPES.VOICE_CALL'
  ),
}));

const isAuthentication = computed(() => form.category === 'AUTHENTICATION');
// Catalog stays Marketing-only — it's inherently promotional and Meta doesn't offer it under
// Utility. The other three are offered under both, so they key off the subtype alone;
// SUBTYPES_BY_CATEGORY is what decides where each one can be picked.
const isCatalog = computed(
  () => isMarketing.value && form.subtype === 'CATALOG'
);
const isFlow = computed(() => form.subtype === 'FLOWS');
const isOrderDetails = computed(() => form.subtype === 'ORDER_DETAILS');
// Meta's order status template is the leanest shape there is: BODY and an optional FOOTER, no
// header and no buttons at all. It's also the only subtype identified by `sub_category` on the
// creation payload rather than by its components.
const isOrderStatus = computed(() => form.subtype === 'ORDER_STATUS');
// CALL_PERMISSION_REQUEST is its own template component (a sibling of HEADER/BODY/FOOTER),
// not a button — it has no BUTTONS section and only allows a TEXT (or no) header.
const isCallPermissionRequest = computed(
  () => form.subtype === 'CALL_PERMISSION_REQUEST'
);

const maxButtons = computed(() => {
  if (isAuthentication.value) return AUTH_MAX_BUTTONS;
  if (isCatalog.value) return CATALOG_MAX_BUTTONS;
  if (isFlow.value) return FLOW_MAX_BUTTONS;
  if (isOrderDetails.value) return ORDER_DETAILS_MAX_BUTTONS;
  return MAX_BUTTONS;
});

// The generic "até N botões de ação ou resposta rápida" was a lie for the exclusive subtypes:
// Catalog/Flows/Order details each allow exactly one button, of one fixed type, and
// Authentication's is Meta's OTP button — none of them accept a quick reply. Naming the actual
// button keeps this panel honest about what the form will let the user build.
const fixedButtonAreaKey = computed(() => {
  if (isAuthentication.value) return 'AREA_BUTTON_COPY_CODE';
  if (isCatalog.value) return 'AREA_BUTTON_CATALOG';
  if (isFlow.value) return 'AREA_BUTTON_FLOW';
  if (isOrderDetails.value) return 'AREA_BUTTON_ORDER_DETAILS';
  return null;
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
    if (!isOrderStatus.value) {
      areas.push(
        t(
          isCallPermissionRequest.value
            ? 'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.AREA_HEADER_TEXT_ONLY'
            : 'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.AREA_HEADER'
        )
      );
    }
    areas.push(t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.AREA_BODY'));
    areas.push(t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.AREA_FOOTER'));
  }
  if (!isCallPermissionRequest.value && !isOrderStatus.value) {
    areas.push(
      fixedButtonAreaKey.value
        ? t(
            `MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.${fixedButtonAreaKey.value}`
          )
        : t(
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
  (newCategory, oldCategory) => {
    // Marketing and Utility share four of the five types, so switching between them used to throw
    // the user's choice away. Only reset when the current type doesn't exist in the new category.
    const allowed = SUBTYPES_BY_CATEGORY[newCategory] || ['STANDARD'];
    if (!allowed.includes(form.subtype)) form.subtype = 'STANDARD';

    if (newCategory === 'AUTHENTICATION') {
      form.header = { type: 'NONE', text: '', handle: '', fileName: '' };
      form.body = AUTH_BODY_TEXT;
      form.footer = '';
      form.buttons = form.buttons
        .filter(button => button.type === 'COPY_CODE')
        .slice(0, AUTH_MAX_BUTTONS);
    } else if (oldCategory === 'AUTHENTICATION') {
      // Leaving Authentication: clear the fields it auto-filled (and disabled editing
      // of) so they don't silently carry stale auth content into Marketing/Utility.
      form.header = { type: 'NONE', text: '', handle: '', fileName: '' };
      form.body = '';
      form.footer = '';
      form.buttons = [];
    }
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

watch(isOrderStatus, newIsOrderStatus => {
  if (!newIsOrderStatus) return;

  form.buttons = [];
  form.header = { type: 'NONE', text: '', handle: '', fileName: '' };
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

const buildTemplatePayload = () => ({
  name: form.name,
  category: form.category,
  language: form.language,
  sub_category: isOrderStatus.value ? 'ORDER_STATUS' : undefined,
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

const requiredFieldErrors = () => {
  const errors = [];
  if (!form.name.trim()) {
    errors.push(
      t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.VALIDATION.NAME_REQUIRED')
    );
  } else if (!NAME_REGEX.test(form.name)) {
    errors.push(
      t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.VALIDATION.NAME_FORMAT')
    );
  }
  if (!isAuthentication.value && !form.body.trim()) {
    errors.push(
      t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.VALIDATION.BODY_REQUIRED')
    );
  } else if (
    !isAuthentication.value &&
    templateBodyFieldRef.value?.hasDanglingVariable
  ) {
    errors.push(
      t(
        'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.VALIDATION.BODY_DANGLING_VARIABLE'
      )
    );
  }
  return errors;
};

const openConfirmModal = () => {
  const errors = requiredFieldErrors();
  if (errors.length) {
    submitError.value = errors.join('; ');
    useAlert(submitError.value);
    return;
  }
  submitError.value = '';
  showConfirmModal.value = true;
};

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
      <div v-if="currentStep === 1" class="p-4">
        <div class="mb-4">
          <h2 class="text-heading-2 text-n-slate-12">
            {{ $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.TITLE') }}
          </h2>
          <p class="text-body-main text-n-slate-11">
            {{ $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.DESCRIPTION') }}
          </p>
        </div>

        <div class="flex flex-col items-start gap-6 lg:flex-row">
          <div class="w-full space-y-4 lg:max-w-2xl">
            <CardLayout v-if="whatsAppCloudInboxes.length">
              <div class="flex items-center justify-between w-full">
                <div>
                  <h3
                    class="flex items-center gap-2 font-semibold text-n-slate-12"
                  >
                    <Icon icon="i-lucide-inbox" class="flex-shrink-0 size-4" />
                    {{ $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.INBOX.TITLE') }}
                  </h3>
                  <p class="mt-1 text-body-main text-n-slate-11">
                    {{
                      $t(
                        'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.INBOX.DESCRIPTION'
                      )
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

            <div>
              <h3 class="mb-1 font-semibold text-n-slate-12">
                {{ $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.CATEGORY_TITLE') }}
              </h3>
              <p class="mb-2 text-body-main text-n-slate-11">
                {{
                  $t(
                    'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.CATEGORY_DESCRIPTION'
                  )
                }}
              </p>
              <div class="flex gap-1 border-b border-n-weak">
                <button
                  v-for="category in categories"
                  :key="category.id"
                  type="button"
                  class="flex items-center gap-2 px-4 py-2 text-sm font-medium border-b-2 -mb-px transition-colors"
                  :class="[
                    form.category === category.id
                      ? 'border-n-brand text-n-brand'
                      : 'border-transparent text-n-slate-11 hover:text-n-slate-12',
                  ]"
                  @click="form.category = category.id"
                >
                  <Icon :icon="category.icon" class="flex-shrink-0 size-4" />
                  {{ category.label }}
                </button>
              </div>
              <p class="mt-2 text-body-main text-n-slate-11">
                {{ currentCategoryDescription }}
              </p>
            </div>

            <Banner color="amber">
              <div class="flex items-center gap-2">
                <Icon icon="i-lucide-info" class="flex-shrink-0 size-4" />
                <span>
                  {{
                    $t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.META_GUIDELINE')
                  }}
                </span>
              </div>
            </Banner>

            <div class="space-y-2">
              <h3 class="font-semibold text-n-slate-12">
                {{ subtypesSectionTitle }}
              </h3>
              <p class="text-body-main text-n-slate-11">
                {{
                  $t(
                    'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_1.SUBTYPES.DESCRIPTION'
                  )
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

          <TemplatePreviewSidebar
            :inbox-summary="currentInboxSummary"
            :category-subtype-summary="currentCategorySubtypeSummary"
            :header="form.header"
            :body="form.body"
            :footer="isAuthentication ? '' : form.footer"
            :buttons="isCallPermissionRequest ? [] : form.buttons"
            :samples="bodySamples"
            :ideal-for-description="subtypeDescriptions[form.subtype]"
            :customizable-areas="customizableAreas"
          />
        </div>
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
                v-if="!isAuthentication && !isOrderStatus"
                v-model="form.header"
                :inbox-id="inboxId"
                :text-only="isCallPermissionRequest"
              />

              <TemplateBodyField
                v-if="!isAuthentication"
                ref="templateBodyFieldRef"
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

            <CardLayout v-if="!isCallPermissionRequest && !isOrderStatus">
              <TemplateButtonsField
                v-model="form.buttons"
                :button-type-options="buttonTypeOptions"
                :button-type-labels="buttonTypeLabels"
                :max-buttons="maxButtons"
                :is-authentication="isAuthentication"
                :inbox-id="inboxId"
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
                @click="openConfirmModal"
              />
            </div>
          </div>

          <TemplatePreviewSidebar
            :inbox-summary="currentInboxSummary"
            :category-subtype-summary="currentCategorySubtypeSummary"
            :header="form.header"
            :body="form.body"
            :footer="isAuthentication ? '' : form.footer"
            :buttons="isCallPermissionRequest ? [] : form.buttons"
            :samples="bodySamples"
            :ideal-for-description="subtypeDescriptions[form.subtype]"
            :customizable-areas="customizableAreas"
            show-live-preview-note
          />
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
