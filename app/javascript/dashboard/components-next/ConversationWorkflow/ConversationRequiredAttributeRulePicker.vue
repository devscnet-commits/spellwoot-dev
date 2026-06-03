<script setup>
import { ref, computed, watch } from 'vue';
import Button from 'dashboard/components-next/button/Button.vue';
import {
  ATTRIBUTE_TYPES,
  SYSTEM_CONDITION_FIELDS,
} from './constants';

const props = defineProps({
  attribute: { type: Object, required: true },
  allAttributes: { type: Array, default: () => [] },
});

const emit = defineEmits(['confirm', 'cancel']);

const rule = ref('always');
const conditionField = ref('');
const conditionValues = ref([]); // always array internally; serialized to string if single-value

// All available condition fields: system fields + LIST/TEXT custom attributes
const conditionFieldOptions = computed(() => [
  ...SYSTEM_CONDITION_FIELDS,
  ...props.allAttributes.filter(a =>
    [ATTRIBUTE_TYPES.LIST, ATTRIBUTE_TYPES.TEXT].includes(a.type)
  ),
]);

const selectedConditionAttr = computed(() =>
  conditionFieldOptions.value.find(a => a.value === conditionField.value)
);

// For LIST and system fields: multi-select checkboxes
// For TEXT fields: single text input
const isMultiSelectMode = computed(
  () =>
    selectedConditionAttr.value?.type === ATTRIBUTE_TYPES.LIST ||
    selectedConditionAttr.value?.isSystem
);

const valueOptions = computed(() => {
  if (isMultiSelectMode.value) {
    return selectedConditionAttr.value?.attributeValues || [];
  }
  return null;
});

// Reset values when the condition field changes
watch(conditionField, () => {
  conditionValues.value = [];
});

const toggleValue = val => {
  const idx = conditionValues.value.indexOf(val);
  if (idx === -1) conditionValues.value.push(val);
  else conditionValues.value.splice(idx, 1);
};

const isValid = computed(() => {
  if (rule.value === 'always') return true;
  if (!conditionField.value) return false;
  if (isMultiSelectMode.value) return conditionValues.value.length > 0;
  return conditionValues.value.length > 0;
});

const handleConfirm = () => {
  const config = { key: props.attribute.value, rule: rule.value };
  if (rule.value === 'conditional') {
    config.condition_field = conditionField.value;
    // Store as array for multi-values, string for single text value
    config.condition_value =
      isMultiSelectMode.value && conditionValues.value.length === 1
        ? conditionValues.value[0]
        : isMultiSelectMode.value
          ? [...conditionValues.value]
          : conditionValues.value[0] || '';
  }
  emit('confirm', config);
};
</script>

<template>
  <div class="px-4 py-3 bg-n-solid-1 border-t border-n-weak">
    <p class="text-body-small text-n-slate-11 mb-3">
      {{
        $t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.RULE.CONFIGURE_FOR', {
          name: attribute.label,
        })
      }}
    </p>

    <!-- Rule selection -->
    <div class="flex flex-col gap-2 mb-4">
      <label class="flex items-center gap-2 cursor-pointer">
        <input v-model="rule" type="radio" value="always" />
        <span class="text-body-para text-n-slate-12">
          {{ $t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.RULE.ALWAYS') }}
        </span>
      </label>
      <label class="flex items-center gap-2 cursor-pointer">
        <input v-model="rule" type="radio" value="conditional" />
        <span class="text-body-para text-n-slate-12">
          {{ $t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.RULE.CONDITIONAL') }}
        </span>
      </label>
    </div>

    <template v-if="rule === 'conditional'">
      <div class="flex flex-col gap-2 mb-4">
        <!-- Condition field selector -->
        <select
          v-model="conditionField"
          class="text-body-para text-n-slate-12 bg-n-solid-2 border border-n-weak rounded px-2 py-1.5 w-full"
        >
          <option value="" disabled>
            {{ $t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.RULE.SELECT_FIELD') }}
          </option>
          <optgroup
            v-if="conditionFieldOptions.some(a => a.isSystem)"
            label="Sistema"
          >
            <option
              v-for="attr in conditionFieldOptions.filter(a => a.isSystem)"
              :key="attr.value"
              :value="attr.value"
            >
              {{ attr.label }}
            </option>
          </optgroup>
          <optgroup label="Atributos personalizados">
            <option
              v-for="attr in conditionFieldOptions.filter(a => !a.isSystem)"
              :key="attr.value"
              :value="attr.value"
            >
              {{ attr.label }}
            </option>
          </optgroup>
        </select>

        <!-- Multi-select checkboxes (LIST / system fields) -->
        <div
          v-if="conditionField && isMultiSelectMode && valueOptions"
          class="flex flex-col gap-1.5 px-1"
        >
          <p class="text-xs text-n-slate-11 mb-1">
            Selecione um ou mais valores (OU):
          </p>
          <label
            v-for="val in valueOptions"
            :key="val"
            class="flex items-center gap-2 cursor-pointer"
          >
            <input
              type="checkbox"
              :checked="conditionValues.includes(val)"
              class="w-3.5 h-3.5 rounded accent-n-brand-9"
              @change="toggleValue(val)"
            />
            <span class="text-body-para text-n-slate-12">{{ val }}</span>
          </label>
        </div>

        <!-- Single text input (TEXT fields) -->
        <input
          v-else-if="conditionField && !isMultiSelectMode"
          :value="conditionValues[0] || ''"
          type="text"
          class="text-body-para text-n-slate-12 bg-n-solid-2 border border-n-weak rounded px-2 py-1.5 w-full"
          :placeholder="
            $t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.RULE.CONDITION_VALUE_PLACEHOLDER')
          "
          @input="conditionValues = [$event.target.value]"
        />
      </div>

      <!-- Preview of condition -->
      <p
        v-if="conditionField && conditionValues.length"
        class="text-xs text-n-slate-11 mb-3"
      >
        Obrigatório se
        <strong>{{ selectedConditionAttr?.label }}</strong>
        = {{ Array.isArray(conditionValues) && conditionValues.length > 1 ? conditionValues.join(' OU ') : conditionValues[0] }}
      </p>
    </template>

    <div class="flex gap-2 justify-end">
      <Button
        sm
        slate
        ghost
        :label="$t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.RULE.CANCEL')"
        @click="emit('cancel')"
      />
      <Button
        sm
        :label="$t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.RULE.CONFIRM')"
        :disabled="!isValid"
        @click="handleConfirm"
      />
    </div>
  </div>
</template>
