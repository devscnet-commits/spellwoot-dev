<script setup>
/* global axios */
// Sem agent_bots: o atendimento desta caixa é definido pelos Agentes de IA (aba Caixas
// de cada agente). Aqui apenas mostramos, em modo leitura, quais IAs atendem esta caixa.
import { ref, computed, onMounted } from 'vue';
import { useRoute, useRouter } from 'vue-router';

const props = defineProps({
  inbox: {
    type: Object,
    default: () => ({}),
  },
});

const route = useRoute();
const router = useRouter();

const accountId = computed(() => route.params.accountId);
const inboxId = computed(() => props.inbox?.id || route.params.inboxId);
const agentsUrl = () => `/api/v1/accounts/${accountId.value}/ai_agents`;

const attendingAgents = ref([]);
const isLoading = ref(false);

// O binding IA->caixa é por agente; varremos os agentes e juntamos os que atendem esta caixa.
const fetchAttending = async () => {
  isLoading.value = true;
  attendingAgents.value = [];
  try {
    const { data } = await axios.get(agentsUrl());
    const agents = Array.isArray(data) ? data : [];
    const results = await Promise.all(
      agents.map(async agent => {
        try {
          const { data: bindings } = await axios.get(
            `${agentsUrl()}/${agent.id}/ai_agent_inboxes`
          );
          const match = (Array.isArray(bindings) ? bindings : []).find(
            b => String(b.inbox_id) === String(inboxId.value)
          );
          return match && match.mode !== 'none'
            ? {
                id: agent.id,
                name: agent.assistant_name || agent.name,
                mode: match.mode,
              }
            : null;
        } catch (error) {
          return null;
        }
      })
    );
    attendingAgents.value = results.filter(Boolean);
  } finally {
    isLoading.value = false;
  }
};

const goAgents = () =>
  router.push({
    name: 'ai_agents_index',
    params: { accountId: accountId.value },
  });

onMounted(fetchAttending);
</script>

<template>
  <div class="mx-6 max-w-4xl flex flex-col gap-4">
    <div class="flex flex-col gap-0.5">
      <h3 class="text-sm font-medium text-n-slate-12">
        {{ $t('AI_AGENTS.INBOX_BOT.TITLE') }}
      </h3>
      <p class="text-sm text-n-slate-11 mb-0">
        {{ $t('AI_AGENTS.INBOX_BOT.DESC') }}
      </p>
    </div>

    <p v-if="isLoading" class="text-sm text-n-slate-11 mb-0">
      {{ $t('AI_AGENTS.INBOX_BOT.LOADING') }}
    </p>

    <div v-else-if="attendingAgents.length" class="flex flex-col gap-2">
      <span class="text-xs font-medium text-n-slate-11">
        {{ $t('AI_AGENTS.INBOX_BOT.ATTENDED_BY') }}
      </span>
      <div
        v-for="agent in attendingAgents"
        :key="agent.id"
        class="flex items-center justify-between gap-3 rounded-xl border border-n-weak bg-n-solid-1 px-4 py-3"
      >
        <div class="flex items-center gap-2 min-w-0">
          <span class="i-lucide-bot size-4 text-n-brand shrink-0" />
          <span class="text-sm font-medium text-n-slate-12 truncate">
            {{ agent.name }}
          </span>
        </div>
        <span
          class="shrink-0 inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium"
          :class="
            agent.mode === 'live'
              ? 'bg-n-teal-3 text-n-teal-11'
              : 'bg-n-amber-3 text-n-amber-11'
          "
        >
          {{
            agent.mode === 'live'
              ? $t('AI_AGENTS.INBOX_BOT.MODE_LIVE')
              : $t('AI_AGENTS.INBOX_BOT.MODE_SHADOW')
          }}
        </span>
      </div>
    </div>

    <p v-else class="text-sm text-n-slate-11 mb-0">
      {{ $t('AI_AGENTS.INBOX_BOT.NONE') }}
    </p>

    <button
      type="button"
      class="self-start text-sm font-medium text-n-brand hover:underline"
      @click="goAgents"
    >
      {{ $t('AI_AGENTS.INBOX_BOT.MANAGE') }}
    </button>
  </div>
</template>
