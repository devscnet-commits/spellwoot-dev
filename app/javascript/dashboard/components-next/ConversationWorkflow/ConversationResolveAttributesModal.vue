<script setup>
import { ref, computed, reactive, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVuelidate } from '@vuelidate/core';
import { required, url, helpers } from '@vuelidate/validators';
import { getRegexp } from 'shared/helpers/Validators';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import TextArea from 'next/textarea/TextArea.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import ChoiceToggle from 'dashboard/components-next/input/ChoiceToggle.vue';
import { ATTRIBUTE_TYPES, SYSTEM_OUTCOME_FIELD, OUTCOME_TO_SYSTEM_VALUE, isAttrVisible } from './constants';

const emit = defineEmits(['submit']);

const { t } = useI18n();

const dialogRef = ref(null);
// All required attributes (always + conditional)
const allRequiredAttributes = ref([]);
const formValues = reactive({});
const conversationContext = ref(null);

const placeholders = computed(() => ({
  text: t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.MODAL.PLACEHOLDERS.TEXT'),
  number: t(
    'CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.MODAL.PLACEHOLDERS.NUMBER'
  ),
  link: t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.MODAL.PLACEHOLDERS.LINK'),
  date: t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.MODAL.PLACEHOLDERS.DATE'),
  list: t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.MODAL.PLACEHOLDERS.LIST'),
}));

const getPlaceholder = type => placeholders.value[type] || '';

// Compute which attributes should be visible given current form state
// formValues may include __resultado_conversa__ injected from context
const visibleAttributes = computed(() =>
  allRequiredAttributes.value.filter(attr => isAttrVisible(attr, formValues))
);

// When a conditional field disappears, clear its value so it doesn't linger
watch(visibleAttributes, (newVisible, oldVisible) => {
  if (!oldVisible) return;
  const newKeys = new Set(newVisible.map(a => a.value));
  oldVisible.forEach(attr => {
    if (!newKeys.has(attr.value) && attr.rule === 'conditional') {
      formValues[attr.value] =
        attr.type === ATTRIBUTE_TYPES.CHECKBOX ? null : '';
    }
  });
});

const validationRules = computed(() => {
  const rules = {};
  visibleAttributes.value.forEach(attribute => {
    if (attribute.type === ATTRIBUTE_TYPES.LINK) {
      rules[attribute.value] = { required, url };
    } else if (attribute.type === ATTRIBUTE_TYPES.CHECKBOX) {
      rules[attribute.value] = {};
    } else {
      rules[attribute.value] = { required };
      if (attribute.regexPattern) {
        rules[attribute.value].regexValidation = helpers.withParams(
          { regexCue: attribute.regexCue },
          value => !value || getRegexp(attribute.regexPattern).test(value)
        );
      }
    }
  });
  return rules;
});

const v$ = useVuelidate(validationRules, formValues);

const getErrorMessage = attributeKey => {
  const field = v$.value[attributeKey];
  if (!field || !field.$error) return '';

  if (field.url && field.url.$invalid) {
    return t('CUSTOM_ATTRIBUTES.VALIDATIONS.INVALID_URL');
  }
  if (field.regexValidation && field.regexValidation.$invalid) {
    return (
      field.regexValidation.$params?.regexCue ||
      t('CUSTOM_ATTRIBUTES.VALIDATIONS.INVALID_INPUT')
    );
  }
  if (field.required && field.required.$invalid) {
    return t('CUSTOM_ATTRIBUTES.VALIDATIONS.REQUIRED');
  }
  return '';
};

const isFormComplete = computed(() =>
  visibleAttributes.value.every(attribute => {
    const value = formValues[attribute.value];

    if (attribute.type === ATTRIBUTE_TYPES.CHECKBOX) {
      return formValues[attribute.value] !== null;
    }

    return value !== undefined && value !== null && String(value).trim() !== '';
  })
);

const comboBoxOptions = computed(() => {
  const options = {};
  visibleAttributes.value.forEach(attribute => {
    if (attribute.type === ATTRIBUTE_TYPES.LIST) {
      options[attribute.value] = (attribute.attributeValues || []).map(
        option => ({
          value: option,
          label: option,
        })
      );
    }
  });
  return options;
});

const close = () => {
  dialogRef.value?.close();
  conversationContext.value = null;
  v$.value.$reset();
};

// attributes: all required attributes (with rule/condition info merged)
// initialValues: current conversation custom_attributes
const open = (attributes = [], initialValues = {}, context = null) => {
  allRequiredAttributes.value = attributes;
  conversationContext.value = context;

  Object.keys(formValues).forEach(key => {
    delete formValues[key];
  });

  // Inject system outcome field if context carries an outcome
  if (context?.outcome) {
    formValues[SYSTEM_OUTCOME_FIELD] =
      OUTCOME_TO_SYSTEM_VALUE[context.outcome] ?? null;
  }

  // Seed all conversation attributes so condition_field values are available
  // for the visibleAttributes filter (conditional rules check formValues)
  Object.entries(initialValues).forEach(([key, value]) => {
    formValues[key] = value;
  });

  attributes.forEach(attribute => {
    const presetValue = initialValues[attribute.value];
    if (presetValue !== undefined && presetValue !== null) {
      formValues[attribute.value] = presetValue;
    } else {
      formValues[attribute.value] =
        attribute.type === ATTRIBUTE_TYPES.CHECKBOX ? null : '';
    }
  });

  v$.value.$reset();
  dialogRef.value?.open();
};

// resolve: true closes the conversation after saving; false only saves the
// attributes (and fires whatever the result triggers, e.g. Meta), keeping it open.
const submitWith = resolve => {
  v$.value.$touch();
  if (v$.value.$invalid) {
    return;
  }

  // Only emit values for currently visible attributes
  const visibleValues = {};
  visibleAttributes.value.forEach(attr => {
    visibleValues[attr.value] = formValues[attr.value];
  });

  emit('submit', {
    attributes: visibleValues,
    context: conversationContext.value,
    resolve,
  });
  close();
};

const handleConfirm = () => submitWith(true);
const handleSaveOnly = () => submitWith(false);

defineExpose({ open, close });
</script>

<template>
  <Dialog
    ref="dialogRef"
    width="lg"
    :title="t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.MODAL.TITLE')"
    :description="
      t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.MODAL.DESCRIPTION')
    "
    :disable-confirm-button="!isFormComplete"
    @confirm="handleSaveOnly"
  >
    <template #footer>
      <div class="flex items-center justify-between w-full gap-3">
        <Button
          variant="faded"
          color="slate"
          :label="
            t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.MODAL.ACTIONS.CANCEL')
          "
          class="w-full"
          type="button"
          @click="close"
        />
        <Button
          variant="outline"
          color="blue"
          :label="
            t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.MODAL.ACTIONS.RESOLVE')
          "
          class="w-full"
          type="button"
          :disabled="!isFormComplete"
          @click="handleConfirm"
        />
        <Button
          color="blue"
          :label="
            t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.MODAL.ACTIONS.SAVE')
          "
          class="w-full"
          :disabled="!isFormComplete"
          type="submit"
        />
      </div>
    </template>
    <div class="flex flex-col gap-4">
      <div
        v-for="attribute in visibleAttributes"
        :key="attribute.value"
        class="flex flex-col gap-2"
      >
        <div class="flex justify-between items-center">
          <label class="mb-0.5 text-sm font-medium text-n-slate-12">
            {{ attribute.label }}
          </label>
        </div>

        <template v-if="attribute.type === ATTRIBUTE_TYPES.TEXT">
          <TextArea
            v-model="formValues[attribute.value]"
            class="w-full"
            :placeholder="getPlaceholder(ATTRIBUTE_TYPES.TEXT)"
            :message="getErrorMessage(attribute.value)"
            :message-type="v$[attribute.value].$error ? 'error' : 'info'"
            @blur="v$[attribute.value].$touch"
          />
        </template>

        <template v-else-if="attribute.type === ATTRIBUTE_TYPES.NUMBER">
          <Input
            v-model="formValues[attribute.value]"
            type="number"
            size="md"
            :placeholder="getPlaceholder(ATTRIBUTE_TYPES.NUMBER)"
            :message="getErrorMessage(attribute.value)"
            :message-type="v$[attribute.value].$error ? 'error' : 'info'"
            @blur="v$[attribute.value].$touch"
          />
        </template>

        <template v-else-if="attribute.type === ATTRIBUTE_TYPES.LINK">
          <Input
            v-model="formValues[attribute.value]"
            type="url"
            size="md"
            :placeholder="getPlaceholder(ATTRIBUTE_TYPES.LINK)"
            :message="getErrorMessage(attribute.value)"
            :message-type="v$[attribute.value].$error ? 'error' : 'info'"
            @blur="v$[attribute.value].$touch"
          />
        </template>

        <template v-else-if="attribute.type === ATTRIBUTE_TYPES.DATE">
          <Input
            v-model="formValues[attribute.value]"
            type="date"
            size="md"
            :placeholder="getPlaceholder(ATTRIBUTE_TYPES.DATE)"
            :message="getErrorMessage(attribute.value)"
            :message-type="v$[attribute.value].$error ? 'error' : 'info'"
            @blur="v$[attribute.value].$touch"
          />
        </template>

        <template v-else-if="attribute.type === ATTRIBUTE_TYPES.LIST">
          <ComboBox
            v-model="formValues[attribute.value]"
            :options="comboBoxOptions[attribute.value]"
            :placeholder="getPlaceholder(ATTRIBUTE_TYPES.LIST)"
            :message="getErrorMessage(attribute.value)"
            :message-type="v$[attribute.value].$error ? 'error' : 'info'"
            :has-error="v$[attribute.value].$error"
            class="w-full"
          />
        </template>

        <template v-else-if="attribute.type === ATTRIBUTE_TYPES.CHECKBOX">
          <ChoiceToggle v-model="formValues[attribute.value]" />
        </template>
      </div>
    </div>
  </Dialog>
</template>
