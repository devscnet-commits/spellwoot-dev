<script setup>
defineProps({
  placeholder: { type: String, default: '' },
});

const modelValue = defineModel({ type: String, default: '' });
</script>

<template>
  <div
    class="flex items-center gap-2 rounded-lg border border-n-weak bg-n-solid-2 px-3 py-2 focus-within:border-n-brand"
  >
    <span class="i-lucide-search size-4 text-n-slate-9 flex-shrink-0" />
    <input
      v-model="modelValue"
      type="search"
      class="flex-1 min-w-0 bg-transparent text-sm text-n-slate-12 focus:outline-none placeholder:text-n-slate-9"
      :placeholder="placeholder"
      v-bind="$attrs"
    />
  </div>
</template>
