<script setup>
import {
  STAGE_DOT_CLASS,
  stageColor,
  formatMoney,
  formatDuration,
} from '../../helpers';

defineProps({
  rows: { type: Array, default: () => [] },
});

// No stay ended inside the period: nothing to average.
const avgTimeOf = row =>
  row.avg_time_seconds === null ? '—' : formatDuration(row.avg_time_seconds);
</script>

<template>
  <div class="overflow-x-auto">
    <table class="w-full text-sm text-left">
      <thead
        class="text-xs font-medium tracking-wide uppercase bg-n-slate-2 text-n-slate-11"
      >
        <tr>
          <th class="px-5 py-3">
            {{ $t('CRM_PIPELINE_REPORTS.STAGES.STAGE') }}
          </th>
          <th class="px-3 py-3 text-right">
            {{ $t('CRM_PIPELINE_REPORTS.STAGES.CARDS_NOW') }}
          </th>
          <th class="px-3 py-3 text-right">
            {{ $t('CRM_PIPELINE_REPORTS.STAGES.VALUE') }}
          </th>
          <th class="px-3 py-3 text-right">
            {{ $t('CRM_PIPELINE_REPORTS.STAGES.ENTERED') }}
          </th>
          <th class="px-5 py-3 text-right">
            {{ $t('CRM_PIPELINE_REPORTS.STAGES.AVG_TIME') }}
          </th>
        </tr>
      </thead>
      <tbody class="divide-y divide-n-weak/50">
        <tr
          v-for="(row, index) in rows"
          :key="row.stage_id"
          class="hover:bg-n-slate-1"
        >
          <td class="px-5 py-3 font-medium text-n-slate-12">
            <div class="flex items-center gap-2 min-w-0">
              <span
                class="size-2 rounded-full shrink-0"
                :class="STAGE_DOT_CLASS[stageColor(row, index)]"
              />
              <span class="truncate">{{ row.name }}</span>
              <span
                v-if="row.polarity === 'positive'"
                class="px-1.5 py-0.5 text-xs font-medium rounded-full bg-n-teal-9/15 text-n-teal-11 shrink-0"
              >
                {{ $t('CRM_PIPELINE_REPORTS.STAGES.WON_BADGE') }}
              </span>
              <span
                v-else-if="row.polarity === 'negative'"
                class="px-1.5 py-0.5 text-xs font-medium rounded-full bg-n-ruby-9/15 text-n-ruby-11 shrink-0"
              >
                {{ $t('CRM_PIPELINE_REPORTS.STAGES.LOST_BADGE') }}
              </span>
            </div>
          </td>
          <td
            class="px-3 py-3 font-medium text-right text-n-slate-12 tabular-nums"
          >
            {{ row.count }}
          </td>
          <td class="px-3 py-3 text-right text-n-slate-11 tabular-nums">
            {{ formatMoney(row.value) }}
          </td>
          <td class="px-3 py-3 text-right text-n-slate-11 tabular-nums">
            {{ row.entered }}
          </td>
          <td class="px-5 py-3 text-right text-n-slate-11 tabular-nums">
            {{ avgTimeOf(row) }}
          </td>
        </tr>
      </tbody>
    </table>
  </div>
</template>
