<script setup>
import { computed } from 'vue';
import { STAGE_DOT_CLASS, stageColor } from '../../helpers';

const props = defineProps({
  rows: { type: Array, default: () => [] },
});

// Full class names so Tailwind keeps them.
const FILL_CLASS = {
  blue: 'bg-n-blue-9/40',
  violet: 'bg-n-violet-9/40',
  amber: 'bg-n-amber-9/40',
  iris: 'bg-n-iris-9/40',
  teal: 'bg-n-teal-9/40',
  ruby: 'bg-n-ruby-9/40',
  slate: 'bg-n-slate-9/40',
};

// Bars are proportional to the first step: every card that entered the pipeline in the period.
const base = computed(() => props.rows[0]?.count || 0);
const widthOf = row =>
  base.value ? Math.round((row.count / base.value) * 100) : 0;
const conversionOf = row =>
  row.conversion === null ? '—' : `${row.conversion}%`;
</script>

<template>
  <div>
    <p
      v-if="!rows.length"
      class="py-6 mb-0 text-sm text-center text-n-slate-11"
    >
      {{ $t('CRM_PIPELINE_REPORTS.EMPTY.NO_DATA') }}
    </p>
    <div v-else class="flex flex-col gap-3">
      <div
        v-for="(row, index) in rows"
        :key="row.stage_id"
        class="grid items-center gap-3 grid-cols-[minmax(7rem,11rem)_1fr_auto]"
      >
        <div class="flex items-center gap-2 min-w-0 text-sm text-n-slate-12">
          <span
            class="size-2 rounded-full shrink-0"
            :class="STAGE_DOT_CLASS[stageColor(row, index)]"
          />
          <span class="truncate">{{ row.name }}</span>
        </div>
        <div class="h-7 overflow-hidden rounded-md bg-n-alpha-1">
          <!-- The width is data-driven, hence the style binding. -->
          <div
            class="h-full rounded-md"
            :class="FILL_CLASS[stageColor(row, index)]"
            :style="{ width: `${widthOf(row)}%` }"
          />
        </div>
        <div
          class="flex items-center justify-end gap-2 text-sm tabular-nums w-28"
        >
          <span class="font-semibold text-n-slate-12">{{ row.count }}</span>
          <span
            class="px-2 py-0.5 text-xs font-medium rounded-full bg-n-alpha-2 text-n-slate-11"
          >
            {{ conversionOf(row) }}
          </span>
        </div>
      </div>
    </div>
  </div>
</template>
