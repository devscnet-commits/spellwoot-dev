<script setup>
import { ref, computed, reactive, watch } from 'vue';
import { useVuelidate } from '@vuelidate/core';
import { required } from '@vuelidate/validators';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'next/textarea/TextArea.vue';
import ChoiceToggle from 'dashboard/components-next/input/ChoiceToggle.vue';
import { ATTRIBUTE_TYPES } from './constants';

const emit = defineEmits(['confirm']);

const dialogRef = ref(null);
const pendingOutcome = ref(null);
const allAttributes = ref([]);
const formValues = reactive({});

const title = computed(() => pendingOutcome.value?.label || '');

// Dynamically show attributes based on current form state (same engine as ConversationResolveAttributesModal)
const visibleAttributes = computed(() =>
  allAttributes.value.filter(attr => {
    if (attr.rule === 'conditional') {
      return formValues[attr.condition_field] === attr.condition_value;
    }
    return true;
  })
);

// When a conditional field disappears, clear its value
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
  visibleAttributes.value.forEach(attr => {
    if (attr.type !== ATTRIBUTE_TYPES.CHECKBOX) {
      rules[attr.value] = { required };
    }
  });
  return rules;
});

const v$ = useVuelidate(validationRules, formValues);

const isFormComplete = computed(() =>
  visibleAttributes.value.every(attr => {
    const val = formValues[attr.value];
    if (attr.type === ATTRIBUTE_TYPES.CHECKBOX) return val !== null;
    return val !== undefined && val !== null && String(val).trim() !== '';
  })
);

const comboOptions = computed(() => {
  const opts = {};
  visibleAttributes.value.forEach(attr => {
    if (attr.type === ATTRIBUTE_TYPES.LIST) {
      opts[attr.value] = (attr.attributeValues || []).map(v => ({
        value: v,
        label: v,
      }));
    }
  });
  return opts;
});

const open = ({ outcome, label, statusValue, attributes, initialValues }) => {
  pendingOutcome.value = { outcome, label, statusValue };
  allAttributes.value = attributes;

  Object.keys(formValues).forEach(k => delete formValues[k]);

  // Seed ALL conversation attributes so conditional rules evaluate correctly
  Object.entries(initialValues).forEach(([key, value]) => {
    formValues[key] = value;
  });

  // Seed required attribute fields (don't override initialValues)
  attributes.forEach(attr => {
    if (!(attr.value in formValues)) {
      formValues[attr.value] =
        attr.type === ATTRIBUTE_TYPES.CHECKBOX ? null : '';
    }
  });

  v$.value.$reset();
  dialogRef.value?.open();
};

const handleConfirm = async () => {
  v$.value.$touch();
  if (v$.value.$invalid) return;

  // Only emit values for visible required attributes
  const customAttributes = {};
  visibleAttributes.value.forEach(attr => {
    customAttributes[attr.value] = formValues[attr.value];
  });

  emit('confirm', {
    outcome: pendingOutcome.value.outcome,
    customAttributes,
  });
  dialogRef.value?.close();
};

defineExpose({ open });
</script>

<template>
  <Dialog
    ref="dialogRef"
    width="lg"
    :title="title"
    :description="$t('CONVERSATION_WORKFLOW.OUTCOME.MODAL_DESCRIPTION')"
    :confirm-button-label="$t('CONVERSATION_WORKFLOW.OUTCOME.CONFIRM')"
    :cancel-button-label="$t('CONVERSATION_WORKFLOW.OUTCOME.CANCEL')"
    :disable-confirm-button="!isFormComplete"
    @confirm="handleConfirm"
  >
    <div v-if="visibleAttributes.length" class="flex flex-col gap-4">
      <div
        v-for="attr in visibleAttributes"
        :key="attr.value"
        class="flex flex-col gap-2"
      >
        <label class="mb-0.5 text-sm font-medium text-n-slate-12">
          {{ attr.label }}
        </label>

        <ComboBox
          v-if="attr.type === ATTRIBUTE_TYPES.LIST"
          v-model="formValues[attr.value]"
          :options="comboOptions[attr.value]"
          :placeholder="
            $t(
              'CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.MODAL.PLACEHOLDERS.LIST'
            )
          "
          class="w-full"
        />
        <Input
          v-else-if="attr.type === ATTRIBUTE_TYPES.NUMBER"
          v-model="formValues[attr.value]"
          type="number"
          size="md"
          :placeholder="
            $t(
              'CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.MODAL.PLACEHOLDERS.NUMBER'
            )
          "
        />
        <Input
          v-else-if="attr.type === ATTRIBUTE_TYPES.DATE"
          v-model="formValues[attr.value]"
          type="date"
          size="md"
        />
        <ChoiceToggle
          v-else-if="attr.type === ATTRIBUTE_TYPES.CHECKBOX"
          v-model="formValues[attr.value]"
        />
        <TextArea
          v-else
          v-model="formValues[attr.value]"
          class="w-full"
          :placeholder="
            $t(
              'CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.MODAL.PLACEHOLDERS.TEXT'
            )
          "
        />
      </div>
    </div>
    <p v-else class="text-body-para text-n-slate-11">
      {{ $t('CONVERSATION_WORKFLOW.OUTCOME.NO_FIELDS') }}
    </p>
  </Dialog>
</template>
