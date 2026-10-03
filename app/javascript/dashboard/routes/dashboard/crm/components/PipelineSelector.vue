<script setup>
import FlowSelect from 'dashboard/routes/dashboard/settings/operationalFlows/FlowSelect.vue';

defineProps({
  pipelines: { type: Array, default: () => [] },
  label: { type: String, default: '' },
});

const model = defineModel({ type: [Number, String, null], default: null });
</script>

<template>
  <label class="flex items-center gap-2 text-sm text-n-slate-11">
    <span v-if="label" class="shrink-0">{{ label }}</span>
    <FlowSelect v-model="model" class="min-w-64" select-class="bg-n-solid-2">
      <option
        v-for="pipeline in pipelines"
        :key="pipeline.id"
        :value="pipeline.id"
      >
        {{ pipeline.name }}
      </option>
    </FlowSelect>
  </label>
</template>
