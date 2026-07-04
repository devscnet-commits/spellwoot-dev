<script setup>
/* global axios */
import { ref, computed, watch } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

const props = defineProps({
  contactId: { type: [String, Number], required: true },
});

const route = useRoute();
const { t } = useI18n();

const isFetching = ref(false);
const memory = ref(null);

const keyFacts = computed(() => Object.entries(memory.value?.key_facts || {}));
const hasMemory = computed(
  () => Boolean(memory.value?.summary) || keyFacts.value.length > 0
);
const formattedDate = computed(() => {
  const d = memory.value?.last_updated_at;
  return d ? new Date(d).toLocaleDateString() : '';
});

const fetchMemory = async contactId => {
  if (!contactId) {
    memory.value = null;
    return;
  }
  isFetching.value = true;
  try {
    const { data } = await axios.get(
      `/api/v1/accounts/${route.params.accountId}/contacts/${contactId}/ai_memory`
    );
    memory.value = data;
  } catch (error) {
    memory.value = null;
  } finally {
    isFetching.value = false;
  }
};

watch(
  () => props.contactId,
  id => fetchMemory(id),
  { immediate: true }
);
</script>

<template>
  <div class="px-4 py-3">
    <div
      v-if="isFetching"
      class="flex items-center justify-center py-8 text-n-slate-11"
    >
      <Spinner />
    </div>

    <template v-else-if="hasMemory">
      <p v-if="memory.summary" class="mb-3 text-sm leading-6 text-n-slate-12">
        {{ memory.summary }}
      </p>

      <dl v-if="keyFacts.length" class="flex flex-col gap-1.5 mb-3">
        <div
          v-for="[factKey, factValue] in keyFacts"
          :key="factKey"
          class="flex gap-2 text-sm"
        >
          <dt class="capitalize shrink-0 text-n-slate-11">{{ factKey }}:</dt>
          <dd class="min-w-0 break-words text-n-slate-12">{{ factValue }}</dd>
        </div>
      </dl>

      <p class="mb-0 text-xs text-n-slate-10">
        {{
          t('CONVERSATION_SIDEBAR.AI_MEMORY.META', {
            date: formattedDate,
            count: memory.conversations_count,
          })
        }}
      </p>
    </template>

    <p v-else class="px-2 py-6 text-sm leading-6 text-center text-n-slate-11">
      {{ t('CONVERSATION_SIDEBAR.AI_MEMORY.EMPTY') }}
    </p>
  </div>
</template>
