<script setup>
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import { formatMoney } from '../../helpers';

defineProps({
  rows: { type: Array, default: () => [] },
});
</script>

<template>
  <div>
    <p
      v-if="!rows.length"
      class="py-6 mb-0 text-sm text-center text-n-slate-11"
    >
      {{ $t('CRM_PIPELINE_REPORTS.AGENTS.EMPTY') }}
    </p>
    <div v-else class="overflow-x-auto">
      <table class="w-full text-sm text-left">
        <thead
          class="text-xs font-medium tracking-wide uppercase bg-n-slate-2 text-n-slate-11"
        >
          <tr>
            <th class="px-5 py-3">
              {{ $t('CRM_PIPELINE_REPORTS.AGENTS.AGENT') }}
            </th>
            <th class="px-3 py-3 text-right text-n-teal-11">
              {{ $t('CRM_PIPELINE_REPORTS.AGENTS.WON') }}
            </th>
            <th class="px-3 py-3 text-right">
              {{ $t('CRM_PIPELINE_REPORTS.AGENTS.VALUE') }}
            </th>
            <th class="px-3 py-3 text-right text-n-ruby-11">
              {{ $t('CRM_PIPELINE_REPORTS.AGENTS.LOST') }}
            </th>
            <th class="px-5 py-3 text-right text-n-amber-11">
              {{ $t('CRM_PIPELINE_REPORTS.AGENTS.OPEN') }}
            </th>
          </tr>
        </thead>
        <tbody class="divide-y divide-n-weak/50">
          <tr
            v-for="(row, index) in rows"
            :key="row.user_id ?? 'none'"
            class="hover:bg-n-slate-1"
          >
            <td class="px-5 py-2.5">
              <div class="flex items-center gap-2.5 min-w-0">
                <span class="w-5 text-xs text-n-slate-10 tabular-nums shrink-0">
                  {{ index + 1 }}
                </span>
                <Avatar
                  v-if="row.name"
                  :name="row.name"
                  :size="24"
                  rounded-full
                />
                <span
                  v-else
                  class="flex items-center justify-center rounded-full size-6 bg-n-alpha-2 shrink-0"
                >
                  <span class="i-lucide-user size-3.5 text-n-slate-10" />
                </span>
                <span
                  class="font-medium truncate"
                  :class="
                    row.name ? 'text-n-slate-12' : 'italic text-n-slate-11'
                  "
                >
                  {{ row.name || $t('CRM_PIPELINE_REPORTS.AGENTS.UNASSIGNED') }}
                </span>
              </div>
            </td>
            <td
              class="px-3 py-2.5 font-medium text-right text-n-teal-11 tabular-nums"
            >
              {{ row.won_count }}
            </td>
            <td class="px-3 py-2.5 text-right text-n-slate-11 tabular-nums">
              {{ formatMoney(row.won_value) }}
            </td>
            <td
              class="px-3 py-2.5 font-medium text-right text-n-ruby-11 tabular-nums"
            >
              {{ row.lost_count }}
            </td>
            <td
              class="px-5 py-2.5 font-medium text-right text-n-amber-11 tabular-nums"
            >
              {{ row.open_count }}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
