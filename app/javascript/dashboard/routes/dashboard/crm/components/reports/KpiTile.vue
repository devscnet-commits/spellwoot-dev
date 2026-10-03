<script setup>
defineProps({
  label: { type: String, required: true },
  value: { type: [String, Number], required: true },
  hint: { type: String, default: '' },
  icon: { type: String, default: '' },
  tone: { type: String, default: 'slate' },
});

// Full class names so Tailwind keeps them.
const TONES = {
  slate: {
    card: 'bg-n-solid-2 border-n-weak',
    icon: 'text-n-slate-9',
    label: 'text-n-slate-11',
    value: 'text-n-slate-12',
  },
  blue: {
    card: 'bg-n-blue-2 border-n-blue-4',
    icon: 'text-n-blue-11',
    label: 'text-n-blue-11',
    value: 'text-n-blue-11',
  },
  teal: {
    card: 'bg-n-teal-2 border-n-teal-4',
    icon: 'text-n-teal-11',
    label: 'text-n-teal-11',
    value: 'text-n-teal-11',
  },
  ruby: {
    card: 'bg-n-ruby-2 border-n-ruby-4',
    icon: 'text-n-ruby-11',
    label: 'text-n-ruby-11',
    value: 'text-n-ruby-11',
  },
  amber: {
    card: 'bg-n-amber-2 border-n-amber-4',
    icon: 'text-n-amber-11',
    label: 'text-n-amber-11',
    value: 'text-n-amber-11',
  },
};
</script>

<template>
  <div
    class="flex flex-col gap-1.5 p-4 border rounded-xl min-w-0"
    :class="TONES[tone].card"
  >
    <div class="flex items-center gap-1.5 min-w-0">
      <span
        v-if="icon"
        class="size-4 shrink-0"
        :class="[icon, TONES[tone].icon]"
      />
      <span
        class="text-xs font-medium tracking-wide uppercase truncate"
        :class="TONES[tone].label"
      >
        {{ label }}
      </span>
    </div>
    <span class="text-2xl font-bold leading-tight" :class="TONES[tone].value">
      {{ value }}
    </span>
    <span v-if="hint" class="text-xs text-n-slate-10 truncate">{{ hint }}</span>
  </div>
</template>
