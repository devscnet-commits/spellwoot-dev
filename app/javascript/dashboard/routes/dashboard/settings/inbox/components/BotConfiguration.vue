<script setup>
/* global axios */
// Sem agent_bots: o atendimento desta caixa é definido pelos Agentes de IA. Esta tela mostra quais IAs
// atendem a caixa E — quando mais de uma RESPONDE — QUAL é a principal (rádio). A decisão de "qual IA
// responde nesta caixa" é DA CAIXA (marcar/desmarcar segue na aba Caixas do agente). O rádio elimina o
// empate por construção: uma principal (priority 1), as demais em 2 (a eleição só usa o menor).
import { ref, computed, onMounted } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import { principalAgentId, buildPriorityPayload } from './aiInboxPriority';

const props = defineProps({
  inbox: {
    type: Object,
    default: () => ({}),
  },
});

const route = useRoute();
const router = useRouter();
const { t } = useI18n();

const accountId = computed(() => route.params.accountId);
const inboxId = computed(() => props.inbox?.id || route.params.inboxId);
const prioritiesUrl = () =>
  `/api/v1/accounts/${accountId.value}/inboxes/${inboxId.value}/ai_agent_priorities`;

// [{ agent_id, agent_name, mode, priority }] — os agentes que atendem esta caixa, ordenados como a eleição.
const attendingAgents = ref([]);
// agent_id da IA PRINCIPAL (o rádio marcado). Derivado do estado atual no fetch (sem mutar); normaliza no save.
const principalId = ref(null);
const isLoading = ref(false);
const isSaving = ref(false);

const liveAgents = computed(() =>
  attendingAgents.value.filter(a => a.mode === 'live')
);
// Uma IA live só: não há eleição; o rádio fica marcado e TRAVADO (comunica o estado, não some).
const singleLive = computed(() => liveAgents.value.length === 1);

const fetchAttending = async () => {
  isLoading.value = true;
  try {
    const { data } = await axios.get(prioritiesUrl());
    attendingAgents.value = Array.isArray(data) ? data : [];
    // deriva a principal do estado atual (min [priority, id]) — sem mutar o que está salvo
    principalId.value = principalAgentId(attendingAgents.value);
  } catch (error) {
    attendingAgents.value = [];
    principalId.value = null;
  } finally {
    isLoading.value = false;
  }
};

const savePriorities = async () => {
  isSaving.value = true;
  try {
    await axios.patch(prioritiesUrl(), {
      priorities: buildPriorityPayload(
        attendingAgents.value,
        principalId.value
      ),
    });
    useAlert(t('AI_AGENTS.INBOX_BOT.PRIORITY_SAVED'));
    await fetchAttending(); // recarrega na ordem da eleição
  } catch (error) {
    useAlert(t('AI_AGENTS.INBOX_BOT.PRIORITY_ERROR'));
  } finally {
    isSaving.value = false;
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

    <template v-else-if="attendingAgents.length">
      <span class="text-xs font-medium text-n-slate-11">
        {{ $t('AI_AGENTS.INBOX_BOT.ATTENDED_BY') }}
      </span>

      <div class="flex flex-col gap-2">
        <div
          v-for="agent in attendingAgents"
          :key="agent.agent_id"
          class="flex items-center justify-between gap-3 rounded-xl border border-n-weak bg-n-solid-1 px-4 py-3"
        >
          <div class="flex items-center gap-2.5 min-w-0">
            <!-- rádio "IA principal": só para quem RESPONDE (live). Marcar uma desmarca as outras. -->
            <input
              v-if="agent.mode === 'live'"
              v-model="principalId"
              type="radio"
              name="ai-inbox-principal"
              :value="agent.agent_id"
              :disabled="singleLive"
              data-testid="agent-principal"
              class="shrink-0"
            />
            <!-- sombra observa e não compete: sem rádio, mas com espaçador para alinhar com as live -->
            <span v-else class="size-4 shrink-0" />
            <span class="i-lucide-bot size-4 text-n-brand shrink-0" />
            <span class="text-sm font-medium text-n-slate-12 truncate">
              {{ agent.agent_name }}
            </span>
          </div>
          <div class="shrink-0 flex items-center gap-3">
            <!-- IA live única: o rádio fica marcado+travado; este texto explica o porquê -->
            <span
              v-if="agent.mode === 'live' && singleLive"
              class="text-xs text-n-slate-11"
            >
              {{ $t('AI_AGENTS.INBOX_BOT.SINGLE_LIVE') }}
            </span>
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
      </div>

      <p class="text-xs text-n-slate-11 mb-0">
        {{ $t('AI_AGENTS.INBOX_BOT.PRINCIPAL_HINT') }}
      </p>

      <!-- Salvar só quando há ELEIÇÃO (>=2 live). Com 1 ou 0 não há o que escolher. -->
      <div v-if="liveAgents.length >= 2" class="flex justify-end">
        <button
          type="button"
          :disabled="isSaving"
          class="text-sm font-medium px-3 py-2 rounded-lg bg-n-brand text-white disabled:opacity-50 disabled:cursor-not-allowed"
          @click="savePriorities"
        >
          {{ $t('AI_AGENTS.INBOX_BOT.PRIORITY_SAVE') }}
        </button>
      </div>
    </template>

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
