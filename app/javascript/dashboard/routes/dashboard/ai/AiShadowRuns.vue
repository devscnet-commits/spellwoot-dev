<script setup>
/* global axios */
import { ref, onMounted } from 'vue';
import { useRoute } from 'vue-router';

const route = useRoute();
const runs = ref([]);
const isLoading = ref(false);

// Failed runs are the point of validation, so give them a distinct, explained badge.
const isError = run => run.status === 'error' || !!run.error_type;
const statusClass = run => {
  if (isError(run)) return 'bg-n-ruby-3 text-n-ruby-11';
  if (run.status === 'recorded') return 'bg-n-teal-3 text-n-teal-11';
  return 'bg-n-alpha-2 text-n-slate-11';
};

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
  <div
    class="flex flex-col w-full h-full overflow-auto p-4 sm:p-6 gap-4 max-w-4xl mx-auto"
  >
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
        {{
          isLoading
            ? $t('AI_SHADOW_RUNS.LOADING')
            : $t('AI_SHADOW_RUNS.REFRESH')
        }}
      </button>
    </div>

    <p
      v-if="!isLoading && !runs.length"
      class="text-sm text-n-slate-11 py-8 text-center"
    >
      {{ $t('AI_SHADOW_RUNS.EMPTY') }}
    </p>

    <div v-else class="flex flex-col gap-3">
      <div
        v-for="run in runs"
        :key="run.id"
        class="rounded-xl border border-n-weak bg-n-solid-1 p-4 flex flex-col gap-3"
      >
        <!-- Header: conversation + department, status/error on the right -->
        <div class="flex items-start justify-between gap-3">
          <div class="flex items-center gap-2 min-w-0 text-sm">
            <span class="font-medium text-n-slate-12">
              {{
                `${$t('AI_SHADOW_RUNS.CONVERSATION')} #${run.conversation_id}`
              }}
            </span>
            <span
              v-if="run.department"
              class="inline-flex items-center gap-1 text-n-slate-11 truncate"
            >
              <span class="i-lucide-layers size-3.5 shrink-0" />
              {{ run.department }}
            </span>
          </div>
          <span
            class="shrink-0 inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium"
            :class="statusClass(run)"
          >
            {{
              isError(run)
                ? $t(
                    `AI_SHADOW_RUNS.ERROR_TYPES.${run.error_type || 'unknown'}`
                  )
                : $t(`AI_SHADOW_RUNS.STATUS.${run.status}`)
            }}
          </span>
        </div>

        <!-- Proposed reply: the core of what the AI would have done -->
        <p
          class="text-sm text-n-slate-12 mb-0 whitespace-pre-wrap line-clamp-4 rounded-lg bg-n-alpha-1 px-3 py-2"
          :class="{ 'italic text-n-slate-11': !run.reply_text }"
        >
          {{ run.reply_text || $t('AI_SHADOW_RUNS.NO_REPLY') }}
        </p>

        <!-- Compact meta line: wraps instead of forcing horizontal scroll -->
        <div
          class="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-n-slate-11"
        >
          <span v-if="run.model" class="inline-flex items-center gap-1">
            <span class="i-lucide-cpu size-3.5" />
            {{ [run.provider, run.model].filter(Boolean).join(' / ') }}
          </span>
          <span class="inline-flex items-center gap-1">
            <span class="i-lucide-book-open size-3.5" />
            {{
              $t('AI_SHADOW_RUNS.KNOWLEDGE_COUNT', {
                count: run.knowledge_count ?? 0,
              })
            }}
          </span>
          <span v-if="run.tool" class="inline-flex items-center gap-1">
            <span class="i-lucide-wrench size-3.5" />
            {{ run.tool }}
          </span>
          <span class="inline-flex items-center gap-1">
            <span class="i-lucide-banknote size-3.5" />
            {{ `${$t('AI_SHADOW_RUNS.COST')}: ${run.cost ?? 0}` }}
          </span>
          <span class="inline-flex items-center gap-1">
            <span class="i-lucide-timer size-3.5" />
            {{ `${run.latency_ms ?? 0} ms` }}
          </span>
        </div>
      </div>
    </div>
  </div>
</template>
