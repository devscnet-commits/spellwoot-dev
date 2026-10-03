<script setup>
import { computed } from 'vue';
import { formatMoney } from '../../helpers';

const props = defineProps({
  rows: { type: Array, default: () => [] },
});

// Bars are proportional to the stage with the most losses.
const max = computed(() => Math.max(0, ...props.rows.map(row => row.count)));
const widthOf = row =>
  max.value ? Math.round((row.count / max.value) * 100) : 0;
</script>

<template>
  <div>
    <p
      v-if="!rows.length"
      class="py-6 mb-0 text-sm text-center text-n-slate-11"
    >
      {{ $t('CRM_PIPELINE_REPORTS.LOSSES.EMPTY') }}
    </p>
    <ul v-else class="flex flex-col gap-3 mb-0 list-none">
      <li
        v-for="row in rows"
        :key="row.stage_id ?? 'none'"
        class="flex flex-col gap-1.5"
      >
        <div class="flex items-center justify-between gap-3 text-sm">
          <span class="font-medium truncate text-n-slate-12">
            {{ row.name || $t('CRM_PIPELINE_REPORTS.LOSSES.UNKNOWN_STAGE') }}
          </span>
          <div class="flex items-center gap-3 shrink-0 tabular-nums">
            <span class="font-semibold text-n-ruby-11">
              {{
                $t('CRM_PIPELINE_REPORTS.LOSSES.COUNT', { count: row.count })
              }}
            </span>
            <span class="text-n-slate-11">{{ formatMoney(row.value) }}</span>
          </div>
        </div>
        <div class="h-1.5 overflow-hidden rounded-full bg-n-alpha-1">
          <!-- The width is data-driven, hence the style binding. -->
          <div
            class="h-full rounded-full bg-n-ruby-9/60"
            :style="{ width: `${widthOf(row)}%` }"
          />
        </div>
      </li>
    </ul>
  </div>
</template>
