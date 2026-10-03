<script setup>
defineProps({
  title: { type: String, required: true },
  description: { type: String, default: '' },
  icon: { type: String, default: '' },
  // Tables bleed to the card edges; everything else keeps the card padding.
  flush: { type: Boolean, default: false },
});
</script>

<template>
  <section class="overflow-hidden border rounded-xl bg-n-solid-2 border-n-weak">
    <div class="flex flex-col gap-0.5 px-5 pt-5 pb-4">
      <h2
        class="flex items-center gap-1.5 mb-0 text-sm font-semibold text-n-slate-12"
      >
        <span
          v-if="icon"
          class="size-4 shrink-0 text-n-blue-11"
          :class="icon"
        />
        {{ title }}
      </h2>
      <p v-if="description" class="mb-0 text-xs text-n-slate-11">
        {{ description }}
      </p>
    </div>
    <div :class="flush ? '' : 'px-5 pb-5'">
      <slot />
    </div>
  </section>
</template>
