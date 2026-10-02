<script setup>
import { computed, reactive, ref } from 'vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import AttributeField from './AttributeField.vue';
import { isBlank, requirementConditionMet } from '../helpers';

// "Campos obrigatórios da etapa": asks for the attributes the target stage requires before the card
// can move there. Conditional requirements ("obrigatório SE atributo = valor") show up as soon as
// the trigger value is picked in the form itself.
const props = defineProps({
  attributes: { type: Array, default: () => [] },
});

const emit = defineEmits(['submit', 'cancel']);

const dialogRef = ref(null);
const stage = ref(null);
const requirements = ref([]);
const baseValues = ref({});
const values = reactive({});
const showErrors = ref(false);
const isSaving = ref(false);
// The Dialog emits close for any reason; only a close without a successful save is a cancel.
const settled = ref(false);

const definitionFor = key =>
  props.attributes.find(attribute => attribute.attributeKey === key) || {
    attributeKey: key,
    attributeDisplayName: key,
    attributeDisplayType: 'text',
  };

const visibleRequirements = computed(() =>
  requirements.value.filter(requirement =>
    requirementConditionMet(requirement, { ...baseValues.value, ...values })
  )
);

const isMissing = requirement => {
  const value = values[requirement.attribute_key];
  if (
    definitionFor(requirement.attribute_key).attributeDisplayType === 'checkbox'
  ) {
    return value !== true;
  }
  return isBlank(value);
};

const isComplete = computed(() => !visibleRequirements.value.some(isMissing));

// requirementsList: [{ attribute_key, condition }] still blank for the card; currentValues: the
// card's custom attributes (conditions are evaluated against them plus what is typed here).
const open = ({ targetStage, requirementsList, currentValues }) => {
  stage.value = targetStage;
  requirements.value = requirementsList;
  baseValues.value = currentValues || {};
  Object.keys(values).forEach(key => delete values[key]);
  requirementsList.forEach(requirement => {
    values[requirement.attribute_key] =
      currentValues?.[requirement.attribute_key] ?? '';
  });
  showErrors.value = false;
  isSaving.value = false;
  settled.value = false;
  dialogRef.value?.open();
};

const onClose = () => {
  if (settled.value) return;
  settled.value = true;
  emit('cancel');
};

const cancel = () => dialogRef.value?.close();

const submit = () => {
  showErrors.value = true;
  if (!isComplete.value) return;
  isSaving.value = true;
  const filled = {};
  visibleRequirements.value.forEach(requirement => {
    filled[requirement.attribute_key] = values[requirement.attribute_key];
  });
  emit('submit', filled);
};

const finish = () => {
  isSaving.value = false;
  settled.value = true;
  dialogRef.value?.close();
};

const stopLoading = () => {
  isSaving.value = false;
};

defineExpose({ open, close: finish, stopLoading });
</script>

<template>
  <Dialog ref="dialogRef" width="xl" @close="onClose">
    <div class="flex items-start gap-3 -mt-2">
      <span
        class="flex items-center justify-center size-10 shrink-0 rounded-xl border border-n-amber-7 bg-n-amber-3 text-n-amber-11"
      >
        <span class="i-lucide-shield-alert size-5" />
      </span>
      <div class="flex flex-col">
        <h3 class="text-base font-semibold text-n-slate-12 mb-0">
          {{ $t('CRM_PIPELINE.REQUIREMENTS.TITLE') }}
        </h3>
        <p class="text-sm text-n-slate-11 mb-0">
          {{ $t('CRM_PIPELINE.REQUIREMENTS.MOVING_TO') }}
          <span class="font-semibold text-n-blue-11">
            {{ stage?.display_label }}
          </span>
        </p>
      </div>
    </div>

    <div class="flex flex-col gap-5 pt-2">
      <AttributeField
        v-for="requirement in visibleRequirements"
        :key="requirement.attribute_key"
        v-model="values[requirement.attribute_key]"
        :attribute="definitionFor(requirement.attribute_key)"
        :has-error="showErrors && isMissing(requirement)"
        required
      />
    </div>

    <template #footer>
      <div
        class="flex items-center justify-end w-full gap-3 pt-4 border-t border-n-weak"
      >
        <Button
          variant="ghost"
          color="slate"
          :label="$t('CRM_PIPELINE.REQUIREMENTS.CANCEL')"
          @click="cancel"
        />
        <Button
          icon="i-lucide-arrow-right"
          trailing-icon
          :label="$t('CRM_PIPELINE.REQUIREMENTS.SAVE_AND_MOVE')"
          :is-loading="isSaving"
          @click="submit"
        />
      </div>
    </template>
  </Dialog>
</template>
