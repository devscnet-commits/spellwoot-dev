<script setup>
import { ref, computed, watch } from 'vue';
import Button from 'dashboard/components-next/button/Button.vue';
import {
  ATTRIBUTE_TYPES,
  SYSTEM_CONDITION_FIELDS,
  SYSTEM_OUTCOME_FIELD,
} from './constants';

const props = defineProps({
  attribute: { type: Object, required: true },
  allAttributes: { type: Array, default: () => [] },
});

const emit = defineEmits(['confirm', 'cancel']);

const rule = ref('always');
const conditionField = ref('');
const conditionValues = ref([]);

const systemFields = SYSTEM_CONDITION_FIELDS;

const customFieldOptions = computed(() =>
  props.allAttributes.filter(a =>
    [ATTRIBUTE_TYPES.LIST, ATTRIBUTE_TYPES.TEXT].includes(a.type)
  )
);

const allConditionFieldOptions = computed(() => [
  ...systemFields,
  ...customFieldOptions.value,
]);

const selectedConditionAttr = computed(() =>
  allConditionFieldOptions.value.find(a => a.value === conditionField.value)
);

const isMultiSelectMode = computed(
  () =>
    selectedConditionAttr.value?.type === ATTRIBUTE_TYPES.LIST ||
    selectedConditionAttr.value?.isSystem
);

const valueOptions = computed(() =>
  isMultiSelectMode.value
    ? selectedConditionAttr.value?.attributeValues || []
    : null
);

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
  return conditionValues.value.length > 0;
});

// Visual style per value (for system outcome field)
const valueStyle = val => {
  if (conditionField.value !== SYSTEM_OUTCOME_FIELD) return null;
  if (val === 'ganho') return 'teal';
  if (val === 'perdido') return 'ruby';
  return null;
};

const valueIcon = val => {
  if (conditionField.value !== SYSTEM_OUTCOME_FIELD) return null;
  if (val === 'ganho') return 'i-lucide-circle-check';
  if (val === 'perdido') return 'i-lucide-circle-x';
  return null;
};

const valueLabel = val => {
  if (conditionField.value !== SYSTEM_OUTCOME_FIELD) return val;
  if (val === 'ganho') return 'Ganho';
  if (val === 'perdido') return 'Perdido';
  return val;
};

const handleConfirm = () => {
  const config = { key: props.attribute.value, rule: rule.value };
  if (rule.value === 'conditional') {
    config.condition_field = conditionField.value;
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
  <div class="px-4 py-4 bg-n-solid-1 border-t border-n-weak flex flex-col gap-4">
    <!-- Header -->
    <p class="text-body-small text-n-slate-11">
      {{
        $t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.RULE.CONFIGURE_FOR', {
          name: attribute.label,
        })
      }}
    </p>

    <!-- Rule selection -->
    <div class="flex flex-col gap-3">
      <label class="flex items-start gap-3 cursor-pointer">
        <input v-model="rule" type="radio" value="always" class="mt-0.5" />
        <div>
          <p class="text-body-para font-medium text-n-slate-12">
            {{ $t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.RULE.ALWAYS') }}
          </p>
          <p class="text-xs text-n-slate-11">Sempre exigido ao resolver</p>
        </div>
      </label>

      <label class="flex items-start gap-3 cursor-pointer">
        <input v-model="rule" type="radio" value="conditional" class="mt-0.5" />
        <div>
          <p class="text-body-para font-medium text-n-slate-12">
            {{ $t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.RULE.CONDITIONAL') }}
          </p>
          <p class="text-xs text-n-slate-11">Exigido apenas quando uma condição for atendida</p>
        </div>
      </label>
    </div>

    <!-- Condition config -->
    <template v-if="rule === 'conditional'">
      <!-- Field selector -->
      <div class="flex flex-col gap-1.5">
        <p class="text-xs font-medium text-n-slate-11 uppercase tracking-wide">Quando o campo</p>
        <select
          v-model="conditionField"
          class="text-body-para text-n-slate-12 bg-n-solid-2 border border-n-weak rounded-lg px-3 py-2 w-full focus:outline-none focus:ring-2 focus:ring-n-brand-9"
        >
          <option value="" disabled>
            {{ $t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.RULE.SELECT_FIELD') }}
          </option>
          <optgroup v-if="systemFields.length" label="— Sistema —">
            <option
              v-for="attr in systemFields"
              :key="attr.value"
              :value="attr.value"
            >
              {{ attr.label }}
            </option>
          </optgroup>
          <optgroup v-if="customFieldOptions.length" label="— Atributos personalizados —">
            <option
              v-for="attr in customFieldOptions"
              :key="attr.value"
              :value="attr.value"
            >
              {{ attr.label }}
            </option>
          </optgroup>
        </select>
      </div>

      <!-- Value selection -->
      <div v-if="conditionField" class="flex flex-col gap-2">
        <p class="text-xs font-medium text-n-slate-11 uppercase tracking-wide">
          For igual a
          <span v-if="isMultiSelectMode" class="normal-case font-normal">(selecione um ou mais)</span>
        </p>

        <!-- Styled chips for LIST / system fields -->
        <div v-if="isMultiSelectMode && valueOptions" class="flex flex-wrap gap-2">
          <button
            v-for="val in valueOptions"
            :key="val"
            type="button"
            class="flex items-center gap-1.5 px-3 py-1.5 rounded-full border text-body-small font-medium transition-all"
            :class="{
              // Outcome system field — colored
              'border-n-teal-9 bg-n-teal-3 text-n-teal-11':
                conditionValues.includes(val) && valueStyle(val) === 'teal',
              'border-n-teal-5 bg-n-solid-2 text-n-slate-11 hover:border-n-teal-7 hover:bg-n-teal-2':
                !conditionValues.includes(val) && valueStyle(val) === 'teal',
              'border-n-ruby-9 bg-n-ruby-3 text-n-ruby-11':
                conditionValues.includes(val) && valueStyle(val) === 'ruby',
              'border-n-ruby-5 bg-n-solid-2 text-n-slate-11 hover:border-n-ruby-7 hover:bg-n-ruby-2':
                !conditionValues.includes(val) && valueStyle(val) === 'ruby',
              // Generic LIST field
              'border-n-brand-9 bg-n-brand-3 text-n-brand-11':
                conditionValues.includes(val) && !valueStyle(val),
              'border-n-weak bg-n-solid-2 text-n-slate-11 hover:border-n-slate-6 hover:bg-n-slate-2':
                !conditionValues.includes(val) && !valueStyle(val),
            }"
            @click="toggleValue(val)"
          >
            <span
              v-if="valueIcon(val)"
              :class="[valueIcon(val), 'w-3.5 h-3.5']"
            />
            <span
              v-else-if="conditionValues.includes(val)"
              class="i-lucide-check w-3.5 h-3.5"
            />
            {{ valueLabel(val) }}
          </button>
        </div>

        <!-- Text input for TEXT fields -->
        <input
          v-else-if="!isMultiSelectMode"
          :value="conditionValues[0] || ''"
          type="text"
          class="text-body-para text-n-slate-12 bg-n-solid-2 border border-n-weak rounded-lg px-3 py-2 w-full focus:outline-none focus:ring-2 focus:ring-n-brand-9"
          :placeholder="
            $t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.RULE.CONDITION_VALUE_PLACEHOLDER')
          "
          @input="conditionValues = [$event.target.value]"
        />
      </div>

      <!-- Summary preview -->
      <div
        v-if="conditionField && conditionValues.length"
        class="flex items-start gap-2 px-3 py-2 rounded-lg bg-n-slate-2 text-xs text-n-slate-11"
      >
        <span class="i-lucide-info w-3.5 h-3.5 mt-0.5 shrink-0 text-n-slate-9" />
        <span>
          Obrigatório quando
          <strong class="text-n-slate-12">{{ selectedConditionAttr?.label }}</strong>
          for
          <strong class="text-n-slate-12">
            {{ conditionValues.map(v => valueLabel(v)).join(' ou ') }}
          </strong>
        </span>
      </div>
    </template>

    <!-- Actions -->
    <div class="flex gap-2 justify-end pt-1 border-t border-n-weak/50">
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
