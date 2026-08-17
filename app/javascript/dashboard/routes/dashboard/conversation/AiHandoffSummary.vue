<script setup>
/* global axios */
import { ref, computed, watch } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';

// Resumo do ÚLTIMO handoff automático da IA nesta conversa (escopo POR CONVERSA — distinto do
// ContactAiMemory, que é a memória do contato cross-conversa). Recarrega ao trocar de conversa.
const props = defineProps({
  conversationId: { type: [String, Number], required: true },
});

const route = useRoute();
const { t } = useI18n();

const isFetching = ref(false);
const data = ref(null);

const hasSummary = computed(() => Boolean(data.value?.summary));
// Chaves i18n ESTÁTICAS por reason (evita dynamic-key do intlify e mantém o lint feliz).
const reasonLabel = computed(() => {
  switch (data.value?.reason) {
    case 'loop':
      return t('CONVERSATION_SIDEBAR.HANDOFF_SUMMARY.REASONS.LOOP');
    case 'credit_exhausted':
      return t('CONVERSATION_SIDEBAR.HANDOFF_SUMMARY.REASONS.CREDIT_EXHAUSTED');
    case 'provider_unavailable':
      return t(
        'CONVERSATION_SIDEBAR.HANDOFF_SUMMARY.REASONS.PROVIDER_UNAVAILABLE'
      );
    case 'modelo_pediu_transferencia':
      return t('CONVERSATION_SIDEBAR.HANDOFF_SUMMARY.REASONS.MODEL_REQUESTED');
    case 'palavra_chave':
      return t('CONVERSATION_SIDEBAR.HANDOFF_SUMMARY.REASONS.KEYWORD');
    default:
      // reason PRESENTE mas não mapeado (ex.: max_turns/declined/max_questions) -> rótulo genérico, não
      // some da sidebar (foi assim que os reasons de give-up ficaram invisíveis). Sem reason -> vazio.
      return data.value?.reason
        ? t('CONVERSATION_SIDEBAR.HANDOFF_SUMMARY.REASONS.GENERIC')
        : '';
  }
});
const formattedDate = computed(() => {
  const d = data.value?.created_at;
  return d ? new Date(d).toLocaleString() : '';
});

const fetchSummary = async conversationId => {
  if (!conversationId) {
    data.value = null;
    return;
  }
  isFetching.value = true;
  try {
    const { data: payload } = await axios.get(
      `/api/v1/accounts/${route.params.accountId}/conversations/${conversationId}/ai_handoff_summary`
    );
    data.value = payload;
  } catch (error) {
    data.value = null;
  } finally {
    isFetching.value = false;
  }
};

watch(
  () => props.conversationId,
  id => fetchSummary(id),
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

    <template v-else-if="hasSummary">
      <span
        v-if="reasonLabel"
        class="inline-flex px-2 py-0.5 mb-2 text-xs rounded-full bg-n-slate-3 text-n-slate-11"
      >
        {{ reasonLabel }}
      </span>
      <p class="mb-3 text-sm leading-6 text-n-slate-12">
        {{ data.summary }}
      </p>
      <p class="mb-0 text-xs text-n-slate-10">
        {{
          t('CONVERSATION_SIDEBAR.HANDOFF_SUMMARY.META', {
            date: formattedDate,
          })
        }}
      </p>
    </template>

    <p v-else class="px-2 py-6 text-sm leading-6 text-center text-n-slate-11">
      {{ t('CONVERSATION_SIDEBAR.HANDOFF_SUMMARY.EMPTY') }}
    </p>
  </div>
</template>
