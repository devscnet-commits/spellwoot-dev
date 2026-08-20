<script setup>
/* global axios */
import { ref, reactive, computed, watch, onMounted } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import AiVersionHistory from './AiVersionHistory.vue';
import AiPromptAssistant from './AiPromptAssistant.vue';
import TabBar from 'dashboard/components-next/tabbar/TabBar.vue';
import Logo from 'next/icon/Logo.vue';
import AiAgentBehaviorPanel from './AiAgentBehaviorPanel.vue';
import { useFormDirty } from 'dashboard/composables/useFormDirty';
import {
  defaultAgentForm,
  buildAgentPayload,
  buildInboxBindings,
} from './aiRoutingPayload';

const route = useRoute();
const router = useRouter();
const { t } = useI18n();

const isNew = computed(() => route.params.agentId === 'new');
const agentId = ref(isNew.value ? null : route.params.agentId);

// The agent holds identity, the inboxes it serves, and (fusão Departamento -> Agente, 19/08) its
// own behavior/knowledge/tools/steps/follow-up directly — no more separate department record.
const TAB_KEYS = [
  'about',
  'behavior',
  'followup',
  'finalization',
  'steps',
  'tools',
  'inboxes',
  'test',
];
// The agent tabs that edit the agent's own config sections (flattened).
const DEPT_TABS = ['behavior', 'followup', 'finalization', 'steps', 'tools'];
const activeKey = ref(route.query.tab === 'test' ? 'test' : 'about');
const tabs = computed(() =>
  TAB_KEYS.map(key => ({
    key,
    label: t(`AI_AGENTS.TABS.${key.toUpperCase()}`),
  }))
);
const activeIndex = computed(() => TAB_KEYS.indexOf(activeKey.value));
const onTabChanged = tab => {
  const found = tabs.value.find(x => x.label === tab.label);
  if (found) activeKey.value = found.key;
};

const profiles = ref([]);
const isSaving = ref(false);

const STAGE_BADGE = {
  production: { dot: 'bg-n-teal-9', text: 'text-n-teal-11', bg: 'bg-n-teal-3' },
  staging: { dot: 'bg-n-amber-9', text: 'text-n-amber-11', bg: 'bg-n-amber-3' },
  sandbox: { dot: 'bg-n-blue-9', text: 'text-n-blue-11', bg: 'bg-n-blue-3' },
  experimental: {
    dot: 'bg-n-slate-9',
    text: 'text-n-slate-11',
    bg: 'bg-n-alpha-2',
  },
};

const accountUrl = () => `/api/v1/accounts/${route.params.accountId}`;
const agentUrl = () => `${accountUrl()}/ai_agents`;

// Default em aiRoutingPayload.defaultAgentForm() — SEM team_id de propósito (issue H1: o override some da
// UI; ausente do payload = não zera a coluna no PATCH). Ver a nota no módulo.
const agentForm = reactive(defaultAgentForm());
const {
  isDirty: agentDirty,
  capture: captureAgent,
  reset: resetAgent,
} = useFormDirty(() => ({ ...agentForm }));

const stageBadge = computed(
  () => STAGE_BADGE[agentForm.stage] || STAGE_BADGE.experimental
);

const profileOptions = computed(() => [
  { value: '', label: t('AI_AGENTS.FORM.NONE') },
  ...profiles.value.map(p => ({ value: p.id, label: p.name })),
]);

// Teams power AI->AI routing: this agent serves its own team, and may hand off only to the
// teams in its allowlist (handoff_team_ids).
const teams = ref([]);
// Whitelist de times humanos = todos os times da conta. (Antes excluía agentForm.team_id; o "time deste
// agente" saiu da UI — issue H1 —, então não há mais o que excluir.)
const handoffTeamOptions = computed(() => teams.value);
const fetchTeams = async () => {
  try {
    const { data } = await axios.get(`${accountUrl()}/teams`);
    teams.value = Array.isArray(data) ? data : [];
  } catch (error) {
    teams.value = [];
  }
};
const toggleHandoffTeam = id => {
  const i = agentForm.handoff_team_ids.indexOf(id);
  if (i >= 0) {
    agentForm.handoff_team_ids.splice(i, 1);
    // não deixar o fallback órfão: se o time desmarcado era o destino padrão, limpa (o backend rejeitaria).
    if (agentForm.fallback_handoff_team_id === id)
      agentForm.fallback_handoff_team_id = '';
  } else agentForm.handoff_team_ids.push(id);
};
// (3) Opções do destino padrão de give-up: só os times MARCADOS na whitelist (não pode acionar quem não
// declarou). '' = padrão (1º da lista). Whitelist vazia -> só a opção padrão (a UI mostra o aviso).
const fallbackTeamOptions = computed(() => {
  const inList = new Set(agentForm.handoff_team_ids || []);
  return [
    { value: '', label: t('AI_AGENTS.HANDOFF.FALLBACK_DEFAULT') },
    ...teams.value
      .filter(tm => inList.has(tm.id))
      .map(tm => ({ value: tm.id, label: tm.name })),
  ];
});

// Outras IAs da conta como destino de transferência (allowlist por agente específico —
// handoff_agent_ids). Lista as IAs ativas; o motor rotear por agente entra na etapa 2.
const agents = ref([]);
const fetchAgents = async () => {
  try {
    const { data } = await axios.get(agentUrl());
    agents.value = Array.isArray(data) ? data : [];
  } catch (error) {
    agents.value = [];
  }
};
const teamName = id => teams.value.find(tm => tm.id === id)?.name || '';
const handoffAgents = computed(() =>
  agents.value.filter(
    a => String(a.id) !== String(agentId.value) && a.status === 'active'
  )
);
const toggleHandoffAgent = id => {
  const i = agentForm.handoff_agent_ids.indexOf(id);
  if (i >= 0) agentForm.handoff_agent_ids.splice(i, 1);
  else agentForm.handoff_agent_ids.push(id);
};

const stageOptions = computed(() =>
  ['production', 'experimental'].map(s => ({
    value: s,
    label: t(`AI_AGENTS.STAGES.${s.toUpperCase()}`),
  }))
);

const LANGUAGES = ['pt-BR', 'en', 'es'];
const LANG_KEY = { 'pt-BR': 'PT_BR', en: 'EN', es: 'ES' };
const languageOptions = computed(() =>
  LANGUAGES.map(l => ({
    value: l,
    label: t(`AI_AGENTS.SOBRE.LANGUAGES.${LANG_KEY[l]}`),
  }))
);

const fetchProfiles = async () => {
  const { data } = await axios.get(`${accountUrl()}/ai_operation_profiles`);
  profiles.value = Array.isArray(data) ? data : [];
};

const fetchAgent = async () => {
  if (isNew.value) return;
  const { data } = await axios.get(`${agentUrl()}/${agentId.value}`);
  Object.keys(agentForm).forEach(k => {
    if (data[k] !== undefined && data[k] !== null) agentForm[k] = data[k];
  });
};

// Avatares são salvos como base64 inline. Encolhemos no cliente (quadrado, lado
// máx AVATAR_MAX_PX) para o data URL ficar leve e caber no campo sem inflar o banco.
const AVATAR_MAX_PX = 192;
const resizeToDataUrl = (dataUrl, maxPx) =>
  new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => {
      const scale = Math.min(1, maxPx / Math.max(img.width, img.height));
      const w = Math.max(1, Math.round(img.width * scale));
      const h = Math.max(1, Math.round(img.height * scale));
      const canvas = document.createElement('canvas');
      canvas.width = w;
      canvas.height = h;
      const ctx = canvas.getContext('2d');
      // Fundo branco para imagens com transparência (JPEG não tem alfa).
      ctx.fillStyle = '#ffffff';
      ctx.fillRect(0, 0, w, h);
      ctx.drawImage(img, 0, 0, w, h);
      resolve(canvas.toDataURL('image/jpeg', 0.85));
    };
    img.onerror = reject;
    img.src = dataUrl;
  });

const onAvatarUpload = ({ file }) => {
  const reader = new FileReader();
  reader.onload = async e => {
    try {
      agentForm.assistant_avatar = await resizeToDataUrl(
        e.target.result,
        AVATAR_MAX_PX
      );
    } catch {
      agentForm.assistant_avatar = e.target.result;
    }
  };
  reader.readAsDataURL(file);
};
const fileInput = ref(null);
const triggerUpload = () => {
  if (fileInput.value) fileInput.value.click();
};
// Recusa arquivos que não sejam imagem ou acima do limite, com aviso amigável.
const AVATAR_MAX_BYTES = 5 * 1024 * 1024;
const onFilePick = e => {
  const file = e.target.files && e.target.files[0];
  // Limpa para permitir reescolher o mesmo arquivo após um erro.
  e.target.value = '';
  if (!file) return;
  if (!file.type.startsWith('image/')) {
    useAlert(t('AI_AGENTS.SOBRE.AVATAR_INVALID_TYPE'));
    return;
  }
  if (file.size > AVATAR_MAX_BYTES) {
    useAlert(t('AI_AGENTS.SOBRE.AVATAR_TOO_LARGE', { mb: 5 }));
    return;
  }
  onAvatarUpload({ file });
};
const saveAgent = async () => {
  isSaving.value = true;
  // buildAgentPayload: spread-e-normaliza. Não emite team_id (o form não o tem) — não zera a coluna.
  const payload = buildAgentPayload(agentForm);
  try {
    if (isNew.value) {
      const { data } = await axios.post(agentUrl(), { ai_agent: payload });
      agentId.value = data.id;
      router.replace({ name: 'ai_agent_detail', params: { agentId: data.id } });
      // eslint-disable-next-line no-use-before-define
      fetchInboxes();
    } else {
      await axios.patch(`${agentUrl()}/${agentId.value}`, {
        ai_agent: payload,
      });
    }
    useAlert(t('AI_AGENTS.SAVED'));
    resetAgent();
  } catch (error) {
    // Surface the API's validation messages instead of a generic error.
    const messages = error.response?.data?.errors;
    useAlert(
      Array.isArray(messages) && messages.length
        ? messages.join('. ')
        : t('AI_AGENTS.ERROR')
    );
  } finally {
    isSaving.value = false;
  }
};

// --- Histórico de versões (painel extraído em AiVersionHistory.vue) ---
const versionsBaseUrl = computed(
  () => `${agentUrl()}/${agentId.value}/ai_agent_versions`
);
const promptAssistantOpen = ref(false);

const goBack = () => router.push({ name: 'ai_agents_index' });
// Managing/creating custom levels is an advanced surface, off the main nav.
const goProfiles = () => router.push({ name: 'ai_profiles_index' });

// --- Caixas (live/shadow binding) ---
const inboxes = ref([]);
const INBOX_MODES = [
  {
    value: 'none',
    i18n: 'NONE_SHORT',
    active: 'bg-n-solid-1 text-n-slate-12 shadow-sm',
  },
  {
    value: 'live',
    i18n: 'LIVE_SHORT',
    active: 'bg-n-teal-3 text-n-teal-11 shadow-sm',
  },
];
const inboxesUrl = () => `${agentUrl()}/${agentId.value}/ai_agent_inboxes`;
const {
  isDirty: inboxesDirty,
  capture: captureInboxes,
  reset: resetInboxes,
} = useFormDirty(() =>
  inboxes.value.map(i => ({ inbox_id: i.inbox_id, mode: i.mode }))
);
const fetchInboxes = async () => {
  if (isNew.value) return;
  const { data } = await axios.get(inboxesUrl());
  inboxes.value = Array.isArray(data) ? data : [];
  captureInboxes();
};
const inboxSearch = ref('');
const filteredInboxes = computed(() => {
  const q = inboxSearch.value.trim().toLowerCase();
  if (!q) return inboxes.value;
  return inboxes.value.filter(i => (i.name || '').toLowerCase().includes(q));
});
const saveInboxes = async () => {
  try {
    // buildInboxBindings: priority só na linha que atende; "Não atende" destrói o binding no backend.
    await axios.put(inboxesUrl(), {
      bindings: buildInboxBindings(inboxes.value),
    });
    useAlert(t('AI_AGENTS.SAVED'));
    resetInboxes();
  } catch (error) {
    useAlert(t('AI_AGENTS.ERROR'));
  }
};

// --- Teste (Aba Laboratório): conversa simulada rodando o Ai::Gateway REAL (mesmo motor que
// atende clientes) contra uma inbox de teste isolada — ver
// Api::V1::Accounts::AiAgentTestConversationsController. Nenhuma mensagem sai de verdade.
const testUrl = () =>
  `${agentUrl()}/${agentId.value}/ai_agent_test_conversation`;
const testMessages = ref([]);
const testDraft = ref('');
const testLoading = ref(false);
const testLoaded = ref(false);

const fetchTestConversation = async () => {
  const { data } = await axios.get(testUrl());
  testMessages.value = data.messages || [];
  testLoaded.value = true;
};

const resetTest = async () => {
  testLoading.value = true;
  try {
    await axios.post(`${testUrl()}/reset`);
    testMessages.value = [];
  } catch (error) {
    useAlert(t('AI_AGENTS.ERROR'));
  } finally {
    testLoading.value = false;
  }
};

const sendTestMessage = async () => {
  const content = testDraft.value.trim();
  if (!content || isNew.value || testLoading.value) return;
  testDraft.value = '';
  testLoading.value = true;
  try {
    const { data } = await axios.post(`${testUrl()}/messages`, { content });
    testMessages.value = data.messages || [];
  } catch (error) {
    useAlert(t('AI_AGENTS.ERROR'));
  } finally {
    testLoading.value = false;
  }
};

watch(activeKey, async key => {
  if (key === 'test' && !isNew.value && !testLoaded.value) {
    await fetchTestConversation();
  }
});

onMounted(async () => {
  await fetchProfiles();
  fetchTeams();
  fetchAgents();
  await fetchAgent();
  captureAgent();
  await fetchInboxes();
  if (activeKey.value === 'test' && !isNew.value) await fetchTestConversation();
});
</script>

<template>
  <div class="w-full h-full overflow-auto bg-n-background p-4 sm:p-6">
    <div class="max-w-5xl mx-auto flex flex-col gap-3">
      <button
        type="button"
        class="self-start text-sm text-n-slate-11 hover:text-n-slate-12"
        @click="goBack"
      >
        {{ $t('AI_AGENTS.BACK') }}
      </button>

      <!-- Main card -->
      <div
        class="rounded-2xl border border-n-weak bg-n-solid-1 px-4 sm:px-8 py-6 flex flex-col gap-5"
      >
        <!-- Header: name (left) + brand logo (right) -->
        <div class="flex items-start justify-between gap-4">
          <div class="flex items-center gap-3 min-w-0">
            <h1 class="text-2xl font-semibold text-n-slate-12 truncate">
              {{
                agentForm.assistant_name ||
                agentForm.name ||
                $t('AI_AGENTS.NEW')
              }}
            </h1>
            <span
              class="shrink-0 inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-xs font-medium"
              :class="[stageBadge.bg, stageBadge.text]"
            >
              <span class="size-1.5 rounded-full" :class="stageBadge.dot" />
              {{ $t(`AI_AGENTS.STAGES.${agentForm.stage.toUpperCase()}`) }}
            </span>
          </div>
          <Logo class="h-7 w-auto shrink-0" />
        </div>

        <TabBar
          :tabs="tabs"
          :initial-active-tab="activeIndex"
          @tab-changed="onTabChanged"
        />

        <!-- SOBRE -->
        <div v-if="activeKey === 'about'" class="flex flex-col gap-5">
          <!-- Identidade do agente: embrulhada em card para padronizar com as demais abas -->
          <section
            class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-5"
          >
            <!-- Row 1: avatar + image actions | identify cards -->
            <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
              <div class="flex items-start gap-3">
                <Avatar
                  :src="agentForm.assistant_avatar"
                  :name="agentForm.assistant_name || agentForm.name || 'IA'"
                  :size="80"
                />
                <div class="flex flex-col gap-2">
                  <input
                    ref="fileInput"
                    type="file"
                    accept="image/*"
                    class="hidden"
                    @change="onFilePick"
                  />
                  <Button
                    variant="outline"
                    color="slate"
                    size="sm"
                    icon="i-lucide-upload"
                    :label="$t('AI_AGENTS.SOBRE.UPLOAD')"
                    @click="triggerUpload"
                  />
                </div>
              </div>

              <div class="lg:col-span-2 flex flex-col gap-2">
                <span class="text-sm font-medium text-n-slate-12">
                  {{ $t('AI_AGENTS.IDENTIFY_AS.LABEL') }}
                </span>
                <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <button
                    type="button"
                    class="relative flex items-start gap-3 text-left p-5 rounded-2xl border-2 transition-all"
                    :class="
                      agentForm.identify_as === 'human'
                        ? 'border-n-brand bg-n-brand/10 shadow-sm'
                        : 'border-n-weak bg-n-solid-2 hover:border-n-slate-7'
                    "
                    @click="agentForm.identify_as = 'human'"
                  >
                    <span
                      class="shrink-0 size-10 rounded-full flex items-center justify-center"
                      :class="
                        agentForm.identify_as === 'human'
                          ? 'bg-n-brand text-white'
                          : 'bg-n-alpha-2 text-n-slate-11'
                      "
                    >
                      <span class="i-lucide-user-round size-5" />
                    </span>
                    <span class="flex flex-col gap-0.5 min-w-0">
                      <span class="text-base font-semibold text-n-slate-12">
                        {{ $t('AI_AGENTS.IDENTIFY_AS.HUMAN') }}
                      </span>
                      <span class="text-xs text-n-slate-11">
                        {{ $t('AI_AGENTS.IDENTIFY_AS.HUMAN_HINT') }}
                      </span>
                    </span>
                    <span
                      v-if="agentForm.identify_as === 'human'"
                      class="i-lucide-check-circle-2 size-5 text-n-brand absolute top-3 right-3"
                    />
                  </button>
                  <button
                    type="button"
                    class="relative flex items-start gap-3 text-left p-5 rounded-2xl border-2 transition-all"
                    :class="
                      agentForm.identify_as === 'ai'
                        ? 'border-n-brand bg-n-brand/10 shadow-sm'
                        : 'border-n-weak bg-n-solid-2 hover:border-n-slate-7'
                    "
                    @click="agentForm.identify_as = 'ai'"
                  >
                    <span
                      class="shrink-0 size-10 rounded-full flex items-center justify-center"
                      :class="
                        agentForm.identify_as === 'ai'
                          ? 'bg-n-brand text-white'
                          : 'bg-n-alpha-2 text-n-slate-11'
                      "
                    >
                      <span class="i-lucide-bot size-5" />
                    </span>
                    <span class="flex flex-col gap-0.5 min-w-0">
                      <span class="text-base font-semibold text-n-slate-12">
                        {{ $t('AI_AGENTS.IDENTIFY_AS.AI') }}
                      </span>
                      <span class="text-xs text-n-slate-11">
                        {{ $t('AI_AGENTS.IDENTIFY_AS.AI_HINT') }}
                      </span>
                    </span>
                    <span
                      v-if="agentForm.identify_as === 'ai'"
                      class="i-lucide-check-circle-2 size-5 text-n-brand absolute top-3 right-3"
                    />
                  </button>
                </div>
              </div>
            </div>

            <!-- Identidade essencial: nome + perfil operacional -->
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-5">
              <Input
                v-model="agentForm.assistant_name"
                :label="$t('AI_AGENTS.SOBRE.AGENT_NAME')"
              />
              <div class="flex flex-col gap-1.5">
                <span class="text-sm font-medium text-n-slate-12">
                  {{ $t('AI_AGENTS.SOBRE.MODEL') }}
                  <span class="text-n-ruby-9">*</span>
                </span>
                <Select
                  v-model="agentForm.ai_operation_profile_id"
                  :options="profileOptions"
                />
                <span
                  v-if="!agentForm.ai_operation_profile_id"
                  class="text-xs text-n-ruby-11"
                >
                  {{ $t('AI_AGENTS.SOBRE.MODEL_REQUIRED') }}
                </span>
                <button
                  type="button"
                  class="self-start text-xs text-n-slate-11 hover:text-n-brand"
                  @click="goProfiles"
                >
                  {{ $t('AI_AGENTS.SOBRE.MANAGE_LEVELS') }}
                </button>
              </div>
            </div>

            <TextArea
              v-model="agentForm.assistant_personality"
              :label="$t('AI_AGENTS.SOBRE.PERSONALITY')"
              :max-length="1000"
            />
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-5">
              <Input
                v-model="agentForm.company_name"
                :label="$t('AI_AGENTS.SOBRE.COMPANY')"
              />
              <Input
                v-model="agentForm.site"
                :label="$t('AI_AGENTS.SOBRE.SITE')"
              />
            </div>

            <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-5">
              <div class="flex flex-col gap-1.5">
                <span class="text-sm font-medium text-n-slate-12">
                  {{ $t('AI_AGENTS.SOBRE.LANGUAGE') }}
                </span>
                <Select
                  v-model="agentForm.assistant_language"
                  :options="languageOptions"
                />
              </div>
              <div class="flex flex-col gap-1.5">
                <span class="text-sm font-medium text-n-slate-12">
                  {{ $t('AI_AGENTS.FORM.STAGE') }}
                </span>
                <Select v-model="agentForm.stage" :options="stageOptions" />
              </div>
            </div>
          </section>

          <div class="flex justify-end">
            <Button
              :label="$t('AI_AGENTS.FORM.SAVE')"
              :is-loading="isSaving"
              :disabled="
                !agentDirty ||
                !(agentForm.assistant_name || agentForm.name || '').trim() ||
                !agentForm.ai_operation_profile_id
              "
              @click="saveAgent"
            />
          </div>

          <!-- Histórico de versões -->
          <AiVersionHistory
            v-if="!isNew"
            :base-url="versionsBaseUrl"
            @restored="fetchAgent"
          />
        </div>

        <!-- ATENDIMENTOS E TRANSFERÊNCIAS: dois cards por pergunta, na ordem entrada -> saída.
             CARD 1 "Quando este agente atende" (caixas + prioridade) e CARD 2 "Para onde o agente
             transfere" (times humanos, fallback, outras IAs). Hierarquia replicada da aba Finalização:
             h2 de seção + subtítulo, rótulos text-sm font-medium, ajuda text-xs. -->
        <div v-else-if="activeKey === 'inboxes'" class="flex flex-col gap-4">
          <!-- CARD 1 — Quando este agente atende (entrada) -->
          <section
            class="border border-n-weak rounded-xl p-5 flex flex-col gap-4 bg-n-solid-2"
          >
            <div class="flex flex-col gap-0.5">
              <h2 class="text-base font-semibold text-n-slate-12 mb-0">
                {{ $t('AI_AGENTS.INBOXES.TITLE') }}
              </h2>
              <p class="text-xs text-n-slate-11 mb-0">
                {{ $t('AI_AGENTS.INBOXES.DESCRIPTION') }}
              </p>
            </div>
            <p v-if="isNew" class="text-sm text-n-slate-11">
              {{ $t('AI_AGENTS.SAVE_FIRST') }}
            </p>
            <p v-else-if="!inboxes.length" class="text-sm text-n-slate-11">
              {{ $t('AI_AGENTS.INBOXES.EMPTY') }}
            </p>
            <template v-else>
              <input
                v-model="inboxSearch"
                type="search"
                :placeholder="$t('AI_AGENTS.INBOXES.SEARCH')"
                class="w-full sm:w-64 px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm text-n-slate-12"
              />
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <!-- Linha única: nome + toggle. A PRIORIDADE (qual IA responde quando mais de uma atende a
                     MESMA caixa) NÃO vive aqui — é decisão da caixa, editada em Configurações → Caixa →
                     Atendimento por IA, onde os agentes concorrentes aparecem lado a lado. -->
                <div
                  v-for="inbox in filteredInboxes"
                  :key="inbox.inbox_id"
                  class="rounded-xl border border-n-weak bg-n-solid-2 px-3 py-2.5 flex items-center justify-between gap-3"
                >
                  <div class="flex items-center gap-2 min-w-0">
                    <span
                      class="shrink-0 size-8 rounded-lg bg-n-alpha-2 flex items-center justify-center"
                    >
                      <span class="i-lucide-inbox size-4 text-n-slate-11" />
                    </span>
                    <span class="text-sm font-medium text-n-slate-12 truncate">
                      {{ inbox.name }}
                    </span>
                  </div>
                  <div
                    class="shrink-0 grid grid-cols-2 gap-1 rounded-lg bg-n-alpha-1 p-1"
                  >
                    <button
                      v-for="m in INBOX_MODES"
                      :key="m.value"
                      type="button"
                      class="px-2.5 py-1 rounded-md text-xs font-medium transition-colors"
                      :class="
                        inbox.mode === m.value
                          ? m.active
                          : 'text-n-slate-11 hover:text-n-slate-12'
                      "
                      @click="inbox.mode = m.value"
                    >
                      {{ $t(`AI_AGENTS.INBOXES.${m.i18n}`) }}
                    </button>
                  </div>
                </div>
              </div>
              <div class="flex justify-end">
                <Button
                  :label="$t('AI_AGENTS.INBOXES.SAVE')"
                  :disabled="!inboxesDirty"
                  @click="saveInboxes"
                />
              </div>
            </template>
          </section>

          <!-- CARD 2 — Para onde o agente transfere (saída). NB: este "Salvar" persiste o agentForm
               INTEIRO (nome, instruções, perfil...), não só os campos de transferência — é o saveAgent
               global, distinto do "Salvar caixas" do CARD 1, que é escopado às caixas. Não é regressão. -->
          <div
            class="border border-n-weak rounded-xl p-5 flex flex-col gap-5 bg-n-solid-2"
          >
            <div class="flex flex-col gap-0.5">
              <h2 class="text-base font-semibold text-n-slate-12 mb-0">
                {{ $t('AI_AGENTS.HANDOFF.TITLE') }}
              </h2>
              <p class="text-xs text-n-slate-11 mb-0">
                {{ $t('AI_AGENTS.HANDOFF.DESCRIPTION') }}
              </p>
            </div>

            <div class="flex flex-col gap-1.5">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('AI_AGENTS.HANDOFF.ALLOWLIST') }}
              </span>
              <p
                v-if="!handoffTeamOptions.length"
                class="text-sm text-n-slate-11 mb-0"
              >
                {{ $t('AI_AGENTS.HANDOFF.NO_TEAMS') }}
              </p>
              <div v-else class="grid grid-cols-1 sm:grid-cols-2 gap-2">
                <label
                  v-for="tm in handoffTeamOptions"
                  :key="tm.id"
                  class="flex items-center gap-2 text-sm text-n-slate-12 rounded-lg border border-n-weak px-3 py-2"
                >
                  <input
                    type="checkbox"
                    :checked="agentForm.handoff_team_ids.includes(tm.id)"
                    @change="toggleHandoffTeam(tm.id)"
                  />
                  <span class="truncate">{{ tm.name }}</span>
                </label>
              </div>
              <span class="text-xs text-n-slate-11">
                {{ $t('AI_AGENTS.HANDOFF.ALLOWLIST_HINT') }}
              </span>
            </div>

            <!-- (3) Destino PADRÃO quando a IA desiste (give-up sem destino declarado): um dos times marcados -->
            <div class="flex flex-col gap-1.5">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('AI_AGENTS.HANDOFF.FALLBACK_LABEL') }}
              </span>
              <p
                v-if="!agentForm.handoff_team_ids.length"
                class="text-sm text-n-slate-11 mb-0"
              >
                {{ $t('AI_AGENTS.HANDOFF.FALLBACK_EMPTY') }}
              </p>
              <Select
                v-else
                v-model="agentForm.fallback_handoff_team_id"
                :options="fallbackTeamOptions"
              />
              <span class="text-xs text-n-slate-11">
                {{ $t('AI_AGENTS.HANDOFF.FALLBACK_HINT') }}
              </span>
            </div>

            <!-- Outras IAs como destino (roteia pelo time da IA) -->
            <div class="flex flex-col gap-1.5">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('AI_AGENTS.HANDOFF.IA_ALLOWLIST') }}
              </span>
              <p
                v-if="!handoffAgents.length"
                class="text-sm text-n-slate-11 mb-0"
              >
                {{ $t('AI_AGENTS.HANDOFF.NO_IA') }}
              </p>
              <div v-else class="grid grid-cols-1 sm:grid-cols-2 gap-2">
                <label
                  v-for="ia in handoffAgents"
                  :key="ia.id"
                  class="flex items-center gap-2 text-sm text-n-slate-12 rounded-lg border border-n-weak px-3 py-2"
                >
                  <input
                    type="checkbox"
                    :checked="agentForm.handoff_agent_ids.includes(ia.id)"
                    @change="toggleHandoffAgent(ia.id)"
                  />
                  <span class="min-w-0 truncate">
                    {{ ia.assistant_name || ia.name }}
                    <span v-if="ia.team_id" class="text-n-slate-11">
                      · {{ teamName(ia.team_id) }}
                    </span>
                  </span>
                </label>
              </div>
              <span class="text-xs text-n-slate-11">
                {{ $t('AI_AGENTS.HANDOFF.IA_ALLOWLIST_HINT') }}
              </span>
            </div>

            <div class="flex justify-end">
              <Button
                :label="$t('AI_AGENTS.FORM.SAVE')"
                :is-loading="isSaving"
                :disabled="!agentDirty"
                @click="saveAgent"
              />
            </div>
          </div>
        </div>

        <!-- COMPORTAMENTO / CONHECIMENTO / ETAPAS / FERRAMENTAS (departamento padrão) -->
        <div
          v-else-if="DEPT_TABS.includes(activeKey)"
          class="flex flex-col gap-5"
        >
          <p v-if="isNew" class="text-sm text-n-slate-11">
            {{ $t('AI_AGENTS.SAVE_FIRST') }}
          </p>
          <template v-else>
            <section
              v-if="activeKey === 'behavior'"
              class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-4"
            >
              <div class="flex flex-col gap-1">
                <div class="flex justify-end -mb-1">
                  <button
                    type="button"
                    class="i-lucide-sparkles size-4 text-n-slate-10 hover:text-n-brand"
                    :title="$t('AI_AGENTS.PROMPT_ASSISTANT.OPEN')"
                    @click="promptAssistantOpen = true"
                  />
                </div>
                <TextArea
                  v-model="agentForm.base_prompt"
                  :label="$t('AI_AGENTS.FORM.BASE_PROMPT')"
                  :max-length="4000"
                  resize
                  custom-text-area-class="min-h-40 resize-y"
                />
                <p class="text-xs text-n-slate-11 mb-0">
                  {{ $t('AI_AGENTS.FORM.BASE_PROMPT_HINT') }}
                </p>
              </div>
              <AiPromptAssistant
                v-model:open="promptAssistantOpen"
                kind="base_prompt"
                :agent-id="agentId"
              />
              <div class="flex flex-col gap-1">
                <TextArea
                  v-model="agentForm.guardrails"
                  :label="$t('AI_AGENTS.FORM.GUARDRAILS')"
                  :max-length="2000"
                  resize
                  custom-text-area-class="min-h-40 resize-y"
                />
                <p class="text-xs text-n-slate-11 mb-0">
                  {{ $t('AI_AGENTS.FORM.GUARDRAILS_HINT') }}
                </p>
              </div>
              <div class="flex justify-end">
                <Button
                  :label="$t('AI_AGENTS.FORM.SAVE')"
                  :is-loading="isSaving"
                  :disabled="!agentDirty"
                  @click="saveAgent"
                />
              </div>

              <!-- Histórico do prompt do agente (base_prompt/guardrails via Ai::Version).
                   Fica DENTRO desta seção, junto aos campos que restaura — distinto do
                   "Histórico das Configurações" (ai_agent_behavior_versions) que vem no AiAgentBehaviorPanel. -->
              <AiVersionHistory
                v-if="!isNew"
                :base-url="versionsBaseUrl"
                title-key="AI_AGENTS.VERSIONS.TITLE_PROMPT"
                @restored="fetchAgent"
              />
            </section>

            <AiAgentBehaviorPanel embedded :section="activeKey" />
          </template>
        </div>

        <!-- TESTE -->
        <div v-else-if="activeKey === 'test'" class="flex flex-col gap-5">
          <div class="flex items-center justify-between gap-3">
            <div class="flex items-center gap-3 min-w-0">
              <span
                class="size-10 rounded-xl bg-n-brand/10 text-n-brand flex items-center justify-center shrink-0"
              >
                <span class="i-lucide-flask-conical size-5" />
              </span>
              <div class="flex flex-col min-w-0">
                <h2 class="text-base font-semibold text-n-slate-12 mb-0">
                  {{ $t('AI_AGENTS.TEST.LAB_TITLE') }}
                </h2>
                <p class="text-sm text-n-slate-11 mb-0">
                  {{ $t('AI_AGENTS.TEST.LAB_SUBTITLE') }}
                </p>
              </div>
            </div>
            <Button
              v-if="!isNew"
              icon="i-lucide-rotate-ccw"
              variant="faded"
              color="slate"
              :label="$t('AI_AGENTS.TEST.RESET')"
              :is-loading="testLoading && !testMessages.length"
              @click="resetTest"
            />
          </div>

          <p v-if="isNew" class="text-sm text-n-slate-11">
            {{ $t('AI_AGENTS.SAVE_FIRST') }}
          </p>

          <template v-else>
            <!-- Conversa simulada: cada mensagem passa pelo Ai::Gateway de verdade (mesmas etapas,
                 ferramentas, memória e gates de reply_scope/auto_attendance/horário que valem pro
                 cliente real) — não é mais um dry-run à parte. -->
            <div
              class="rounded-2xl border border-n-weak bg-n-solid-2 p-4 flex flex-col gap-3 min-h-[320px]"
            >
              <div
                class="flex-1 flex flex-col gap-2 overflow-y-auto max-h-[480px]"
              >
                <p
                  v-if="!testMessages.length"
                  class="text-sm text-n-slate-11 text-center py-8 mb-0"
                >
                  {{ $t('AI_AGENTS.TEST.EMPTY') }}
                </p>
                <template v-for="m in testMessages" :key="m.id">
                  <div
                    v-if="m.message_type === 'incoming'"
                    class="self-end max-w-[80%] rounded-2xl rounded-br-sm bg-n-brand text-white px-4 py-2.5 text-sm whitespace-pre-wrap"
                  >
                    {{ m.content }}
                  </div>
                  <div
                    v-else-if="m.private"
                    class="self-center max-w-[90%] rounded-xl bg-n-amber-3 text-n-amber-11 px-3 py-2 text-xs whitespace-pre-wrap"
                  >
                    {{ m.content }}
                  </div>
                  <div
                    v-else
                    class="self-start max-w-[80%] rounded-2xl rounded-bl-sm bg-n-solid-1 border border-n-weak px-4 py-2.5 text-sm text-n-slate-12 whitespace-pre-wrap"
                  >
                    {{ m.content }}
                  </div>
                </template>
                <p
                  v-if="testLoading"
                  class="self-start text-xs text-n-slate-11 mb-0"
                >
                  {{ $t('AI_AGENTS.TEST.THINKING') }}
                </p>
              </div>

              <div class="flex gap-2 items-end">
                <TextArea
                  v-model="testDraft"
                  :placeholder="$t('AI_AGENTS.TEST.PLACEHOLDER')"
                  :max-length="1000"
                  custom-text-area-class="min-h-10"
                  @keydown.enter.exact.prevent="sendTestMessage"
                />
                <Button
                  icon="i-lucide-send"
                  :label="$t('AI_AGENTS.TEST.SEND')"
                  :is-loading="testLoading"
                  :disabled="!testDraft.trim()"
                  @click="sendTestMessage"
                />
              </div>
            </div>
          </template>
        </div>
      </div>
    </div>
  </div>
</template>
