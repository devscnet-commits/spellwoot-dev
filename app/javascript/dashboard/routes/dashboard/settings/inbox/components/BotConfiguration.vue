<script setup>
/* global axios */
// Sem agent_bots: o atendimento desta caixa é definido pelos Agentes de IA. Esta tela mostra quais IAs
// atendem a caixa E — quando mais de uma RESPONDE — em que ORDEM (priority), editável aqui: a decisão de
// "qual IA responde nesta caixa" é DA CAIXA, entre agentes (marcar/desmarcar segue na aba Caixas do agente).
import { ref, computed, onMounted } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import { priorityTie, buildPriorityPayload } from './aiInboxPriority';

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
const isLoading = ref(false);
const isSaving = ref(false);

const liveAgents = computed(() =>
  attendingAgents.value.filter(a => a.mode === 'live')
);
// Empate real (>=2 live no menor priority) — o agent.priority_tie que o backend emite.
const tie = computed(() => priorityTie(attendingAgents.value));

const fetchAttending = async () => {
  isLoading.value = true;
  try {
    const { data } = await axios.get(prioritiesUrl());
    attendingAgents.value = Array.isArray(data) ? data : [];
  } catch (error) {
    attendingAgents.value = [];
  } finally {
    isLoading.value = false;
  }
};

const savePriorities = async () => {
  isSaving.value = true;
  try {
    await axios.patch(prioritiesUrl(), {
      priorities: buildPriorityPayload(attendingAgents.value),
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

      <!-- Aviso de empate REAL (agent.priority_tie): >=2 IAs No ar dividindo o menor número -->
      <div
        v-if="tie"
        class="flex items-start gap-2 rounded-lg border border-n-amber-6 bg-n-amber-2 px-3 py-2 text-xs text-n-amber-11"
      >
        <span class="i-lucide-alert-triangle size-4 shrink-0 mt-0.5" />
        <span>
          {{
            $t('AI_AGENTS.INBOX_BOT.TIE_WARNING', {
              names: tie.names.join(', '),
              priority: tie.priority,
            })
          }}
        </span>
      </div>

      <div class="flex flex-col gap-2">
        <div
          v-for="agent in attendingAgents"
          :key="agent.agent_id"
          class="flex items-center justify-between gap-3 rounded-xl border border-n-weak bg-n-solid-1 px-4 py-3"
        >
          <div class="flex items-center gap-2 min-w-0">
            <span class="i-lucide-bot size-4 text-n-brand shrink-0" />
            <span class="text-sm font-medium text-n-slate-12 truncate">
              {{ agent.agent_name }}
            </span>
          </div>
          <div class="shrink-0 flex items-center gap-3">
            <!-- priority só para quem RESPONDE (live); sombra observa e não compete -->
            <label
              v-if="agent.mode === 'live'"
              class="flex items-center gap-1.5 text-xs text-n-slate-11"
            >
              {{ $t('AI_AGENTS.INBOX_BOT.PRIORITY_LABEL') }}
              <input
                v-model.number="agent.priority"
                type="number"
                min="1"
                data-testid="agent-priority"
                class="w-14 px-2 py-1 rounded border border-n-weak bg-n-solid-2 text-sm text-n-slate-12"
              />
            </label>
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
        {{ $t('AI_AGENTS.INBOX_BOT.PRIORITY_HINT') }}
      </p>

      <div v-if="liveAgents.length" class="flex justify-end">
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
