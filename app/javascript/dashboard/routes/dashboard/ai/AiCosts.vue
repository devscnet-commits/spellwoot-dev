<script setup>
/* global axios */
import { ref, onMounted } from 'vue';
import { useRoute } from 'vue-router';

const route = useRoute();
const data = ref({ total_cost: 0, total_runs: 0, by_model: [] });
const isLoading = ref(false);

const fetchCosts = async () => {
  isLoading.value = true;
  try {
    const { data: payload } = await axios.get(
      `/api/v1/accounts/${route.params.accountId}/ai_costs`
    );
    data.value = payload || { total_cost: 0, total_runs: 0, by_model: [] };
  } finally {
    isLoading.value = false;
  }
};

onMounted(fetchCosts);
</script>

<template>
  <div
    class="flex flex-col w-full h-full overflow-auto p-4 sm:p-6 gap-4 max-w-5xl mx-auto"
  >
    <div class="flex flex-col gap-1">
      <h1 class="text-xl font-semibold text-n-slate-12">
        {{ $t('AI_COSTS.TITLE') }}
      </h1>
      <p class="text-sm text-n-slate-11 mb-0">
        {{ $t('AI_COSTS.DESCRIPTION') }}
      </p>
    </div>

    <div class="grid grid-cols-2 gap-3 sm:max-w-md">
      <div class="border border-n-weak rounded-xl p-4">
        <p class="text-xs text-n-slate-11 mb-1">
          {{ $t('AI_COSTS.TOTAL_COST') }}
        </p>
        <p class="text-lg font-semibold text-n-slate-12">
          {{ data.total_cost }}
        </p>
      </div>
      <div class="border border-n-weak rounded-xl p-4">
        <p class="text-xs text-n-slate-11 mb-1">
          {{ $t('AI_COSTS.TOTAL_RUNS') }}
        </p>
        <p class="text-lg font-semibold text-n-slate-12">
          {{ data.total_runs }}
        </p>
      </div>
    </div>

    <p
      v-if="!isLoading && !data.by_model.length"
      class="text-sm text-n-slate-11 py-8 text-center"
    >
      {{ $t('AI_COSTS.EMPTY') }}
    </p>
    <div v-else class="border border-n-weak rounded-xl overflow-x-auto">
      <table class="w-full text-sm min-w-[32rem]">
        <thead class="bg-n-alpha-2 text-n-slate-11">
          <tr>
            <th class="text-left font-medium px-3 py-2">
              {{ $t('AI_COSTS.COLUMNS.MODEL') }}
            </th>
            <th class="text-left font-medium px-3 py-2">
              {{ $t('AI_COSTS.COLUMNS.RUNS') }}
            </th>
            <th class="text-left font-medium px-3 py-2">
              {{ $t('AI_COSTS.COLUMNS.COST') }}
            </th>
            <th class="text-left font-medium px-3 py-2">
              {{ $t('AI_COSTS.COLUMNS.AVG_LATENCY') }}
            </th>
          </tr>
        </thead>
        <tbody class="divide-y divide-n-weak text-n-slate-12">
          <tr v-for="(row, index) in data.by_model" :key="index">
            <td class="px-3 py-2 whitespace-nowrap">
              {{ row.provider }} / {{ row.model }}
            </td>
            <td class="px-3 py-2">{{ row.runs }}</td>
            <td class="px-3 py-2">{{ row.cost }}</td>
            <td class="px-3 py-2">{{ row.avg_latency }}</td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
