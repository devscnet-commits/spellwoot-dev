<script setup>
// Native select with a proper chevron and breathing room before the edge —
// the bare <select> arrow rendered clipped/invisible on the dark theme.
defineProps({
  selectClass: { type: String, default: 'bg-n-solid-1' },
});

const model = defineModel({ type: null, default: '' });
</script>

<template>
  <div class="relative">
    <select
      v-model="model"
      class="w-full appearance-none px-3 ltr:pr-9 rtl:pl-9 py-2.5 rounded-lg border border-n-weak text-sm text-n-slate-12 focus:outline-none focus:ring-2 focus:ring-n-brand"
      :class="selectClass"
    >
      <slot />
    </select>
    <span
      class="i-lucide-chevron-down size-4 text-n-slate-11 absolute ltr:right-3 rtl:left-3 top-1/2 -translate-y-1/2 pointer-events-none"
    />
  </div>
</template>
