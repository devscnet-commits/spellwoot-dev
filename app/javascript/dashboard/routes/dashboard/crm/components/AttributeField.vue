<script setup>
import { computed } from 'vue';
import FlowSelect from 'dashboard/routes/dashboard/settings/operationalFlows/FlowSelect.vue';

// One custom attribute input (conversation attribute definition, camelCased by the store), with the
// attribute description as the hint and R$ / % adornments for currency and percent attributes.
const props = defineProps({
  attribute: { type: Object, required: true },
  required: { type: Boolean, default: false },
  hasError: { type: Boolean, default: false },
});

const model = defineModel({ type: null, default: '' });

const type = computed(() => props.attribute.attributeDisplayType);

const inputType = computed(() => {
  if (['number', 'currency', 'percent'].includes(type.value)) return 'text';
  if (type.value === 'link') return 'url';
  if (type.value === 'date') return 'date';
  return 'text';
});

const inputMode = computed(() =>
  ['number', 'currency', 'percent'].includes(type.value) ? 'decimal' : 'text'
);

const prefix = computed(() => (type.value === 'currency' ? 'R$' : ''));
const suffix = computed(() => (type.value === 'percent' ? '%' : ''));
</script>

<template>
  <div class="flex flex-col gap-1.5">
    <div class="flex items-baseline justify-between gap-3">
      <label class="text-sm font-semibold text-n-slate-12 shrink-0">
        {{ attribute.attributeDisplayName }}
        <span v-if="required" class="text-n-ruby-11">
          {{ $t('CRM_PIPELINE.REQUIREMENTS.REQUIRED_MARK') }}
        </span>
      </label>
      <span
        v-if="attribute.attributeDescription"
        class="text-xs text-n-slate-11 text-right truncate"
      >
        {{ attribute.attributeDescription }}
      </span>
    </div>

    <FlowSelect
      v-if="type === 'list'"
      v-model="model"
      :select-class="
        hasError ? 'bg-n-solid-1 !border-n-ruby-8' : 'bg-n-solid-1'
      "
    >
      <option value="" disabled>
        {{ $t('CRM_PIPELINE.REQUIREMENTS.SELECT_PLACEHOLDER') }}
      </option>
      <option
        v-for="option in attribute.attributeValues || []"
        :key="option"
        :value="option"
      >
        {{ option }}
      </option>
    </FlowSelect>

    <label
      v-else-if="type === 'checkbox'"
      class="flex items-center gap-2 text-sm text-n-slate-12 cursor-pointer"
    >
      <input v-model="model" type="checkbox" class="m-0" />
      {{ $t('CRM_PIPELINE.REQUIREMENTS.CHECKBOX_YES') }}
    </label>

    <div
      v-else
      class="flex items-center gap-2 px-3 rounded-lg border bg-n-solid-1 focus-within:ring-2 focus-within:ring-n-brand"
      :class="hasError ? 'border-n-ruby-8' : 'border-n-weak'"
    >
      <span v-if="prefix" class="text-sm text-n-slate-11">{{ prefix }}</span>
      <input
        v-model="model"
        :type="inputType"
        :inputmode="inputMode"
        class="flex-1 min-w-0 py-2.5 bg-transparent border-0 text-sm text-n-slate-12 focus:outline-none"
      />
      <span v-if="suffix" class="text-sm text-n-slate-11">{{ suffix }}</span>
    </div>
  </div>
</template>
