<script setup>
import { ref, computed } from 'vue';
import Button from 'dashboard/components-next/button/Button.vue';
import { ATTRIBUTE_TYPES } from './constants';

const props = defineProps({
  attribute: { type: Object, required: true },
  allAttributes: { type: Array, default: () => [] },
});

const emit = defineEmits(['confirm', 'cancel']);

const rule = ref('always');
const conditionField = ref('');
const conditionValue = ref('');

const conditionFieldOptions = computed(() =>
  props.allAttributes.filter(a =>
    [ATTRIBUTE_TYPES.LIST, ATTRIBUTE_TYPES.TEXT].includes(a.type)
  )
);

const selectedConditionAttr = computed(() =>
  conditionFieldOptions.value.find(a => a.value === conditionField.value)
);

const conditionValueOptions = computed(() => {
  if (selectedConditionAttr.value?.type === ATTRIBUTE_TYPES.LIST) {
    return selectedConditionAttr.value.attributeValues || [];
  }
  return null;
});

const isValid = computed(() => {
  if (rule.value === 'always') return true;
  return conditionField.value !== '' && conditionValue.value !== '';
});

const handleConfirm = () => {
  const config = { key: props.attribute.value, rule: rule.value };
  if (rule.value === 'conditional') {
    config.condition_field = conditionField.value;
    config.condition_value = conditionValue.value;
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
        <select
          v-model="conditionField"
          class="text-body-para text-n-slate-12 bg-n-solid-2 border border-n-weak rounded px-2 py-1.5 w-full"
        >
          <option value="" disabled>
            {{
              $t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.RULE.SELECT_FIELD')
            }}
          </option>
          <option
            v-for="attr in conditionFieldOptions"
            :key="attr.value"
            :value="attr.value"
          >
            {{ attr.label }}
          </option>
        </select>

        <select
          v-if="conditionValueOptions"
          v-model="conditionValue"
          class="text-body-para text-n-slate-12 bg-n-solid-2 border border-n-weak rounded px-2 py-1.5 w-full"
        >
          <option value="" disabled>
            {{
              $t('CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.RULE.SELECT_VALUE')
            }}
          </option>
          <option v-for="val in conditionValueOptions" :key="val" :value="val">
            {{ val }}
          </option>
        </select>

        <input
          v-else-if="conditionField"
          v-model="conditionValue"
          type="text"
          class="text-body-para text-n-slate-12 bg-n-solid-2 border border-n-weak rounded px-2 py-1.5 w-full"
          :placeholder="
            $t(
              'CONVERSATION_WORKFLOW.REQUIRED_ATTRIBUTES.RULE.CONDITION_VALUE_PLACEHOLDER'
            )
          "
        />
      </div>
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
