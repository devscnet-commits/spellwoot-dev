<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import FlowSelect from 'dashboard/routes/dashboard/settings/operationalFlows/FlowSelect.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import {
  CONDITION_ATTRIBUTES,
  OPERATORS,
  VALUELESS_OPERATORS,
  PRIORITIES,
  SLA_STATUSES,
  TEMPERATURE_VALUES,
  CONVERSATION_STATUSES,
} from './automationForm';

// One condition of the rule: attribute, operator and a value control that depends on the attribute.
const props = defineProps({
  labels: { type: Array, default: () => [] },
  teams: { type: Array, default: () => [] },
  agents: { type: Array, default: () => [] },
  attributes: { type: Array, default: () => [] },
  error: { type: String, default: '' },
});

const emit = defineEmits(['remove']);

const model = defineModel({ type: Object, required: true });
const { t } = useI18n();

const set = patch => {
  model.value = { ...model.value, ...patch };
};

// Changing the attribute resets what depends on it.
const onAttributeChange = attribute =>
  set({ attribute, attribute_key: '', value: '' });

const onOperatorChange = operator =>
  set({
    operator,
    value: VALUELESS_OPERATORS.includes(operator) ? '' : model.value.value,
  });

const needsValue = computed(
  () => !VALUELESS_OPERATORS.includes(model.value.operator)
);

const customAttribute = computed(() =>
  props.attributes.find(
    attribute => attribute.attributeKey === model.value.attribute_key
  )
);

const translated = (values, group) =>
  values.map(value => ({
    value,
    label: t(`CRM_AUTOMATIONS.CONDITIONS.VALUES.${group}.${value}`),
  }));

// Options of the value select; null means a free text input.
const valueOptions = computed(() => {
  switch (model.value.attribute) {
    case 'label':
      return props.labels.map(label => ({
        value: label.title,
        label: label.title,
      }));
    case 'priority':
      return translated(PRIORITIES, 'PRIORITY');
    case 'team_id':
      return props.teams.map(team => ({ value: team.id, label: team.name }));
    case 'assignee_id':
      return props.agents.map(agent => ({
        value: agent.id,
        label: agent.name,
      }));
    case 'sla':
      return translated(SLA_STATUSES, 'SLA');
    case 'temperature':
      return translated(TEMPERATURE_VALUES, 'TEMPERATURE');
    case 'status':
      return translated(CONVERSATION_STATUSES, 'STATUS');
    case 'custom_attribute':
      return customAttribute.value?.attributeDisplayType === 'list'
        ? (customAttribute.value.attributeValues || []).map(value => ({
            value,
            label: value,
          }))
        : null;
    default:
      return null;
  }
});
</script>

<template>
  <div class="flex flex-col gap-1">
    <div class="flex flex-wrap items-center gap-2">
      <FlowSelect
        :model-value="model.attribute"
        class="w-48"
        select-class="bg-n-solid-2"
        @update:model-value="onAttributeChange"
      >
        <option
          v-for="attribute in CONDITION_ATTRIBUTES"
          :key="attribute"
          :value="attribute"
        >
          {{ $t(`CRM_AUTOMATIONS.CONDITIONS.ATTRIBUTES.${attribute}`) }}
        </option>
      </FlowSelect>

      <FlowSelect
        v-if="model.attribute === 'custom_attribute'"
        :model-value="model.attribute_key"
        class="w-48"
        select-class="bg-n-solid-2"
        @update:model-value="set({ attribute_key: $event, value: '' })"
      >
        <option value="" disabled>
          {{ $t('CRM_AUTOMATIONS.CONDITIONS.CUSTOM_ATTRIBUTE_PLACEHOLDER') }}
        </option>
        <option
          v-for="attribute in attributes"
          :key="attribute.attributeKey"
          :value="attribute.attributeKey"
        >
          {{ attribute.attributeDisplayName }}
        </option>
      </FlowSelect>

      <FlowSelect
        :model-value="model.operator"
        class="w-40"
        select-class="bg-n-solid-2"
        @update:model-value="onOperatorChange"
      >
        <option v-for="operator in OPERATORS" :key="operator" :value="operator">
          {{ $t(`CRM_AUTOMATIONS.CONDITIONS.OPERATORS.${operator}`) }}
        </option>
      </FlowSelect>

      <template v-if="needsValue">
        <FlowSelect
          v-if="valueOptions"
          :model-value="model.value"
          class="flex-1 min-w-40"
          select-class="bg-n-solid-2"
          @update:model-value="set({ value: $event })"
        >
          <option value="" disabled>
            {{ $t('CRM_AUTOMATIONS.CONDITIONS.SELECT_PLACEHOLDER') }}
          </option>
          <option
            v-for="option in valueOptions"
            :key="option.value"
            :value="option.value"
          >
            {{ option.label }}
          </option>
        </FlowSelect>
        <Input
          v-else
          :model-value="model.value"
          class="flex-1 min-w-40"
          :placeholder="$t('CRM_AUTOMATIONS.CONDITIONS.VALUE_PLACEHOLDER')"
          @update:model-value="set({ value: $event })"
        />
      </template>

      <Button
        v-tooltip.top="$t('CRM_AUTOMATIONS.CONDITIONS.REMOVE')"
        type="button"
        variant="ghost"
        color="ruby"
        size="sm"
        icon="i-lucide-trash-2"
        @click="emit('remove')"
      />
    </div>
    <p v-if="error" class="mb-0 text-xs text-n-ruby-9">
      {{ $t(`CRM_AUTOMATIONS.CONDITIONS.ERRORS.${error}`) }}
    </p>
  </div>
</template>
