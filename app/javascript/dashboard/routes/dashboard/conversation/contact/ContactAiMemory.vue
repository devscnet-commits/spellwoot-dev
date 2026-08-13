<script setup>
/* global axios */
import { ref, computed, watch } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import { collectedFactsList } from './aiCollectedFacts';

const props = defineProps({
  contactId: { type: [String, Number], required: true },
  // ai_collected_facts da conversa ATUAL (conversation.additional_attributes) — read-only. Distinto da
  // memória do CONTATO (key_facts do LLM, cross-conversa) que este componente já busca por endpoint.
  collectedFacts: { type: Object, default: () => ({}) },
});

const route = useRoute();
const { t } = useI18n();

const isFetching = ref(false);
const memory = ref(null);

const keyFacts = computed(() => Object.entries(memory.value?.key_facts || {}));
// Bloco 1 — Memória do CLIENTE (contato, cross-conversa, gerada pelo LLM).
const hasCustomerMemory = computed(
  () => Boolean(memory.value?.summary) || keyFacts.value.length > 0
);
// Bloco 2 — Coletado NESTA conversa (slots crus). Ordem de coleta, token -> "não informado".
// (nome != da prop collectedFacts para não sombreá-la no template)
const collectedList = computed(() => collectedFactsList(props.collectedFacts));
const hasCollectedFacts = computed(() => collectedList.value.length > 0);
const hasAnything = computed(
  () => hasCustomerMemory.value || hasCollectedFacts.value
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

    <template v-else>
      <!-- Bloco 1 — Memória do CLIENTE (contato, cross-conversa, LLM) -->
      <section v-if="hasCustomerMemory" class="mb-4">
        <h4
          class="mb-1.5 text-xs font-semibold uppercase tracking-wide text-n-slate-10"
        >
          {{ t('CONVERSATION_SIDEBAR.AI_MEMORY.LABEL_CUSTOMER') }}
        </h4>
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
      </section>

      <!-- Bloco 2 — Coletado NESTA conversa (slots crus, read-only, ordem de coleta) -->
      <section v-if="hasCollectedFacts">
        <h4
          class="mb-1.5 text-xs font-semibold uppercase tracking-wide text-n-slate-10"
        >
          {{ t('CONVERSATION_SIDEBAR.AI_MEMORY.LABEL_COLLECTED') }}
        </h4>
        <dl class="flex flex-col gap-1.5">
          <div
            v-for="fact in collectedList"
            :key="fact.key"
            class="flex gap-2 text-sm"
          >
            <dt class="shrink-0 text-n-slate-11">{{ fact.label }}:</dt>
            <dd class="min-w-0 break-words text-n-slate-12">
              {{ fact.value }}
            </dd>
          </div>
        </dl>
      </section>

      <p
        v-if="!hasAnything"
        class="px-2 py-6 text-sm leading-6 text-center text-n-slate-11"
      >
        {{ t('CONVERSATION_SIDEBAR.AI_MEMORY.EMPTY') }}
      </p>
    </template>
  </div>
</template>
