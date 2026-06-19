<script setup>
/* global axios */
import { ref, onMounted } from 'vue';
import { useRoute } from 'vue-router';

const route = useRoute();
const runs = ref([]);
const isLoading = ref(false);

const fetchRuns = async () => {
  isLoading.value = true;
  try {
    const { accountId } = route.params;
    const { data } = await axios.get(
      `/api/v1/accounts/${accountId}/ai_shadow_runs`
    );
    runs.value = Array.isArray(data) ? data : [];
  } catch (error) {
    runs.value = [];
  } finally {
    isLoading.value = false;
  }
};

onMounted(fetchRuns);
</script>

<template>
  <div class="flex flex-col w-full h-full overflow-auto p-6 gap-4">
    <div class="flex items-start justify-between gap-4">
      <div class="flex flex-col gap-1">
        <h1 class="text-xl font-semibold text-n-slate-12">
          {{ $t('AI_SHADOW_RUNS.TITLE') }}
        </h1>
        <p class="text-sm text-n-slate-11 mb-0">
          {{ $t('AI_SHADOW_RUNS.DESCRIPTION') }}
        </p>
      </div>
      <button
        type="button"
        class="shrink-0 text-sm font-medium px-3 py-2 rounded-lg bg-n-brand text-white disabled:opacity-50"
        :disabled="isLoading"
        @click="fetchRuns"
      >
        {{ isLoading ? $t('AI_SHADOW_RUNS.LOADING') : $t('AI_SHADOW_RUNS.REFRESH') }}
      </button>
    </div>

    <p v-if="!isLoading && !runs.length" class="text-sm text-n-slate-11 py-8 text-center">
      {{ $t('AI_SHADOW_RUNS.EMPTY') }}
    </p>

    <div
      v-else
      class="border border-n-weak rounded-xl overflow-hidden overflow-x-auto"
    >
      <table class="w-full text-sm">
        <thead class="bg-n-alpha-2 text-n-slate-11">
          <tr>
            <th class="text-left font-medium px-3 py-2">{{ $t('AI_SHADOW_RUNS.COLUMNS.CONVERSATION') }}</th>
            <th class="text-left font-medium px-3 py-2">{{ $t('AI_SHADOW_RUNS.COLUMNS.DEPARTMENT') }}</th>
            <th class="text-left font-medium px-3 py-2">{{ $t('AI_SHADOW_RUNS.COLUMNS.KNOWLEDGE') }}</th>
            <th class="text-left font-medium px-3 py-2">{{ $t('AI_SHADOW_RUNS.COLUMNS.REPLY') }}</th>
            <th class="text-left font-medium px-3 py-2">{{ $t('AI_SHADOW_RUNS.COLUMNS.TOOL') }}</th>
            <th class="text-left font-medium px-3 py-2">{{ $t('AI_SHADOW_RUNS.COLUMNS.MODEL') }}</th>
            <th class="text-left font-medium px-3 py-2">{{ $t('AI_SHADOW_RUNS.COLUMNS.COST') }}</th>
            <th class="text-left font-medium px-3 py-2">{{ $t('AI_SHADOW_RUNS.COLUMNS.LATENCY') }}</th>
            <th class="text-left font-medium px-3 py-2">{{ $t('AI_SHADOW_RUNS.COLUMNS.STATUS') }}</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-n-weak text-n-slate-12">
          <tr v-for="run in runs" :key="run.id" class="align-top">
            <td class="px-3 py-2 whitespace-nowrap">#{{ run.conversation_id }}</td>
            <td class="px-3 py-2 whitespace-nowrap">{{ run.department || $t('AI_SHADOW_RUNS.NONE') }}</td>
            <td class="px-3 py-2 whitespace-nowrap">{{ run.knowledge_count ?? 0 }}</td>
            <td class="px-3 py-2 max-w-md">{{ run.reply_text || $t('AI_SHADOW_RUNS.NONE') }}</td>
            <td class="px-3 py-2 whitespace-nowrap">{{ run.tool && run.tool.name ? run.tool.name : $t('AI_SHADOW_RUNS.NONE') }}</td>
            <td class="px-3 py-2 whitespace-nowrap">{{ run.provider }} / {{ run.model }}</td>
            <td class="px-3 py-2 whitespace-nowrap">{{ run.cost }}</td>
            <td class="px-3 py-2 whitespace-nowrap">{{ run.latency_ms }}</td>
            <td class="px-3 py-2 whitespace-nowrap">{{ run.status }}</td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
