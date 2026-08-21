<script setup>
/* global axios */
import { ref, reactive, computed, onMounted } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import AiVersionHistory from './AiVersionHistory.vue';
import Logo from 'next/icon/Logo.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import Draggable from 'vuedraggable';
import { useFormDirty } from 'dashboard/composables/useFormDirty';
import { useUnsavedChangesGuard } from 'dashboard/composables/useUnsavedChangesGuard';
import AiTools from './AiTools.vue';
import AiStepForm from './AiStepForm.vue';
// (De)serialização de etapa por SPREAD (preserva collect/slot_required/campos futuros) — ver aiStepPayload.
import {
  parseStep,
  stepToApi,
  nextStepUid,
  mergeStepEdit,
  reconcileSteps,
} from './aiStepPayload';

// Always embedded inside the agent detail page now (fusão Departamento -> Agente, 19/08) — the
// page chrome (breadcrumb / outer shell / Cancelar) stays hidden, and every field here is really
// just another section of the SAME Ai::Agent record (behavior/playbook/tools/follow-up/close_rules).
const props = defineProps({
  embedded: { type: Boolean, default: false },
  // When embedded, which agent-level group of sections to show.
  section: { type: String, default: null },
});
const route = useRoute();
const router = useRouter();
const { t } = useI18n();

const isNew = computed(() => false);
const activeTab = ref('instructions');

// Flattened into agent-level tabs when embedded: each group maps to underlying sections.
const SECTION_GROUPS = {
  behavior: ['instructions', 'attendance'],
  followup: ['followup'],
  finalization: ['finalization'],
  steps: ['steps'],
  tools: ['tools'],
};
const visibleSections = computed(() =>
  props.embedded && props.section
    ? new Set(SECTION_GROUPS[props.section] || [])
    : new Set([activeTab.value])
);
const showSave = computed(() =>
  ['instructions', 'attendance', 'steps', 'followup', 'finalization'].some(s =>
    visibleSections.value.has(s)
  )
);
const isSaving = ref(false);
// (1) Guardrail contra sobrescrita cega do array de steps. lock_version do playbook no load; o save o
// reenvia e o backend responde 409 se estiver defasado (mudança out-of-band: console/outra aba/admin).
// `loadedSteps` guarda o estado carregado (clone) para o reconcileSteps saber o que o usuário REALMENTE
// mudou. `conflict.phase`: null | 'detected' (409, alterações preservadas) | 'reapplied' (juntou) |
// 'ambiguous' (array mudou de tamanho — não dá para reaplicar por índice; Frente C resolve).
const playbookLockVersion = ref(null);
const loadedSteps = ref([]);
const conflict = ref({ phase: null });
const cloneSteps = arr =>
  JSON.parse(JSON.stringify(Array.isArray(arr) ? arr : []));
// Operational summary counts (read-only) served by the agent serializer.
const summary = ref({ steps: 0, tools: 0, knowledge: 0 });

const form = reactive({
  objetivo: '',
  steps: [],
  transfer_when_steps: '',
  close_when_steps: '',
  // Transferência por confiança (agent.transfer_rules.min_confidence): transfere se a confiança
  // da IA for menor que o valor (0 = desligado). É o único gatilho determinístico — o match por
  // palavra-chave foi removido (substring sem contexto gerava falso positivo). Diferente de
  // transfer_when, que é só sugestão no prompt.
  transfer_min_confidence: 0,
  // Transferir para humano se a IA travar numa etapa de coleta por X mensagens
  // (agent.transfer_rules.stuck_handoff_turns). Default 3; 0 = desligado (nunca transfere por trava).
  stuck_handoff_turns: 10,
  // Atendimento
  group_delay_seconds: '',
  max_replies: '',
  max_input_chars: '',
  // O que fazer quando a mensagem passa do limite: 'truncate' (corta) ou 'ask_resume' (pede resumo).
  max_input_action: 'truncate',
  max_input_message: '',
  // Teto de tamanho por tipo de anexo, 0 = sem limite. Anexo acima do teto não é processado
  // (transcrito/lido) — o cliente recebe a mensagem correspondente. Documento = PDF/docx, em
  // caracteres (mesma unidade do limite de texto). Áudio em segundos (duração). Imagem não tem
  // teto — sem unidade fácil de configurar, a IA lê nativamente via visão.
  max_document_chars: '',
  max_document_message: '',
  max_audio_seconds: '',
  max_audio_message: '',
  // Follow-up: SÓ retoma a conversa. Decisões de entrega ficam em Atribuição.
  // Lista de comportamentos de follow-up (1 por contexto de horário); cada um com
  // suas tentativas, carência e a ação se o cliente não responder.
  followup_behaviors: [],
  // Finalização (close_rules): tempo de inatividade (vale p/ todos os comportamentos)
  // + mensagem de encerramento. Scaffold.
  close_message: '',
  inactivity_minutes: 30,
  // Decisão direta quando NÃO há follow-up configurado: ao bater a inatividade e
  // não existir mensagem para disparar, o agente segue por estas decisões (ordem =
  // prioridade). Cada item é { uid (transitório), type }.
  no_followup_action: '',
});
const {
  isDirty: deptDirty,
  capture: captureDept,
  reset: resetDept,
} = useFormDirty(() => ({ ...form }));

const agentUrl = () =>
  `/api/v1/accounts/${route.params.accountId}/ai_agents/${route.params.agentId}`;

// Custom attributes (account-level): source for the "Dado que esta etapa coleta" select in
// AiStepForm (the agent may use all of them — no per-agent opt-out).
const customAttributes = ref([]);
const fetchCustomAttributes = async () => {
  try {
    const { data } = await axios.get(
      `/api/v1/accounts/${route.params.accountId}/custom_attribute_definitions`
    );
    customAttributes.value = Array.isArray(data) ? data : [];
  } catch (error) {
    customAttributes.value = [];
  }
};

// Variáveis INTERNAS do agente (Ai::LeadVariable): fonte do Select da chave de slot no AiStepForm
// (junto com customAttributes). O endpoint index já existia; ninguém o consumia.
const leadVariables = ref([]);
const fetchLeadVariables = async () => {
  try {
    const { data } = await axios.get(`${agentUrl()}/ai_lead_variables`);
    leadVariables.value = Array.isArray(data) ? data : [];
  } catch (error) {
    leadVariables.value = [];
  }
};
// (B2) Ferramentas do agente: fonte do Select "opções vêm de: ferramenta" num slot choice do AiStepForm.
// Mesmo endpoint que a aba Ferramentas (AiTools) consome; buscado aqui para passar como prop às etapas.
const deptTools = ref([]);
const fetchDeptTools = async () => {
  try {
    const { data } = await axios.get(`${agentUrl()}/ai_tools`);
    deptTools.value = Array.isArray(data) ? data : [];
  } catch (error) {
    deptTools.value = [];
  }
};
// AiStepForm criou uma LeadVariable inline: empilha para a opção aparecer no Select (evita refetch).
const onVariableCreated = variable => {
  if (variable?.name) leadVariables.value.push(variable);
};
// AiStepForm excluiu uma LeadVariable: remove da lista (a opção some do select de todas as etapas).
const onVariableDeleted = id => {
  leadVariables.value = leadVariables.value.filter(v => v.id !== id);
};

// Fontes para os seletores das automações de etapa (tag/time). Falha → lista vazia (não quebra a tela).
const labels = ref([]);
const fetchLabels = async () => {
  try {
    const { data } = await axios.get(
      `/api/v1/accounts/${route.params.accountId}/labels`
    );
    labels.value = Array.isArray(data) ? data : data?.payload || [];
  } catch (error) {
    labels.value = [];
  }
};
const teams = ref([]);
const fetchTeams = async () => {
  try {
    const { data } = await axios.get(
      `/api/v1/accounts/${route.params.accountId}/teams`
    );
    teams.value = Array.isArray(data) ? data : data?.payload || [];
  } catch (error) {
    teams.value = [];
  }
};
// Agente dono, para a WHITELIST do desfecho (on_complete): handoff_team_ids / handoff_agent_ids.
const agent = ref(null);
const fetchAgent = async () => {
  try {
    const { data } = await axios.get(agentUrl());
    agent.value = data || null;
  } catch (error) {
    agent.value = null;
  }
};
// IAs da conta, para resolver o NOME do alvo de handoff_ai (o backend casa por assistant_name || name).
const agentsList = ref([]);
const fetchAgents = async () => {
  try {
    const { data } = await axios.get(
      `/api/v1/accounts/${route.params.accountId}/ai_agents`
    );
    agentsList.value = Array.isArray(data) ? data : data?.payload || [];
  } catch (error) {
    agentsList.value = [];
  }
};
// Times da WHITELIST do agente (handoff_team_ids), na ordem marcada — a lista que a resolução do (b)-core
// aceita, NÃO todos os times da conta. Vazia => o select do desfecho fica vazio (com aviso na tela).
const handoffTeams = computed(() => {
  const ids = Array.isArray(agent.value?.handoff_team_ids)
    ? agent.value.handoff_team_ids
    : [];
  const byId = new Map(teams.value.map(tm => [tm.id, tm]));
  return ids.map(id => byId.get(id)).filter(Boolean);
});
// IAs de destino (handoff_agent_ids) com o NOME que o backend casa (assistant_name || name).
const handoffAgents = computed(() => {
  const ids = Array.isArray(agent.value?.handoff_agent_ids)
    ? agent.value.handoff_agent_ids
    : [];
  const byId = new Map(agentsList.value.map(a => [a.id, a]));
  return ids
    .map(id => byId.get(id))
    .filter(Boolean)
    .map(a => ({ id: a.id, name: a.assistant_name || a.name }));
});
const linesToArray = value =>
  (value || '')
    .split('\n')
    .map(l => l.trim())
    .filter(Boolean);
const arrayToLines = value => (Array.isArray(value) ? value.join('\n') : '');

// Etapas viram cards arrastáveis. O uid é transitório (só draggable/keys; removido no stepToApi).
// parseStep/stepToApi (aiStepPayload) usam SPREAD: preservam collect, slot_required e campos novos do
// backend, em vez de reconstruir a etapa com chaves fixas (era a classe de bug que comia dado no save).
const parseSteps = arr => (Array.isArray(arr) ? arr : []).map(parseStep);

// --- Follow-up: tentativas como lista (valor + unidade) ---
let fuUid = 0;
const nextFuUid = () => {
  fuUid += 1;
  return fuUid;
};
// delay em minutos <-> {value, unit} para uma UI amigável (10 min, 2 horas...).
const minutesToVU = dm => {
  const m = Number(dm) || 0;
  return m > 0 && m % 60 === 0
    ? { value: m / 60, unit: 'horas' }
    : { value: m, unit: 'minutos' };
};
const vuToMinutes = a =>
  (a.unit === 'horas' ? Number(a.value) * 60 : Number(a.value)) || 0;
const blankAttempt = () => ({
  uid: nextFuUid(),
  value: '',
  unit: 'minutos',
  message: '',
});
const blankWindow = () => ({ uid: nextFuUid(), start: '', end: '' });
const blankBehavior = () => ({
  uid: nextFuUid(),
  context: 'inbox_hours',
  windows: [],
  attempts: [blankAttempt()],
  no_response_action: 'assign',
});
const mapAttempts = arr =>
  (Array.isArray(arr) ? arr : []).map(a => ({
    uid: nextFuUid(),
    ...minutesToVU(a.delay_minutes),
    message: a.message || '',
  }));
// Hidrata os comportamentos do novo formato (`behaviors`) ou faz shim do antigo
// (um único follow-up vira um comportamento "dentro do horário").
const hydrateBehaviors = fu => {
  if (Array.isArray(fu.behaviors)) {
    return fu.behaviors.map(b => ({
      uid: nextFuUid(),
      context: b.context || 'inbox_hours',
      windows: (Array.isArray(b.windows) ? b.windows : []).map(w => ({
        uid: nextFuUid(),
        start: w.start || '',
        end: w.end || '',
      })),
      attempts: mapAttempts(b.attempts),
      no_response_action: b.no_response_action || 'assign',
    }));
  }
  if (Array.isArray(fu.attempts) && fu.attempts.length) {
    return [
      {
        uid: nextFuUid(),
        context: 'inbox_hours',
        windows: [],
        attempts: mapAttempts(fu.attempts),
        no_response_action:
          fu.on_complete_action === 'close' ? 'finalize' : 'assign',
      },
    ];
  }
  return [];
};
// --- Finalização: decisões para quando não há follow-up (cards arrastáveis) ---
// Aceita lista de strings ('finalize') ou de objetos ({ type: 'finalize' }); escolha única = a 1ª.
const parseNoFollowupAction = list =>
  (Array.isArray(list) ? list : [])
    .map(a => (typeof a === 'string' ? a : a?.type))
    .filter(Boolean)[0] || '';

const hydrate = dept => {
  const playbook = dept.playbook || {};
  // (1) token de concorrência + snapshot do estado carregado (para o reconcileSteps diferenciar o que o
  // usuário mudou). lock_version pode não existir em playbook novo/legado -> 0.
  playbookLockVersion.value = playbook.lock_version ?? 0;
  loadedSteps.value = cloneSteps(parseSteps(playbook.steps));
  conflict.value = { phase: null };
  const behavior = dept.behavior || {};
  const followUp = dept.follow_up || {};
  const close = dept.close_rules || {};
  const transferRules = dept.transfer_rules || {};
  Object.assign(form, {
    // objetivo não tem campo editável na tela (nunca teve) — só sobrevive via playbook.objetivo,
    // round-tripado aqui pra não ser apagado a cada save (ver #buildPayload).
    objetivo: playbook.objetivo || '',
    steps: parseSteps(playbook.steps),
    transfer_when_steps: arrayToLines(playbook.transfer_when),
    close_when_steps: arrayToLines(playbook.close_when),
    transfer_min_confidence: Number(transferRules.min_confidence) || 0,
    // ?? 3: chave ausente (agente antigo) => default 3; valor 0 explícito é preservado.
    stuck_handoff_turns: Number(transferRules.stuck_handoff_turns ?? 10),
    group_delay_seconds: behavior.grouping?.delay_seconds ?? '',
    max_replies: behavior.max_replies ?? '',
    max_input_chars: behavior.max_input_chars ?? '',
    max_input_action: behavior.max_input_action || 'truncate',
    max_input_message: behavior.max_input_message || '',
    max_document_chars: behavior.max_document_chars ?? '',
    max_document_message: behavior.max_document_message || '',
    max_audio_seconds: behavior.max_audio_seconds ?? '',
    max_audio_message: behavior.max_audio_message || '',
    followup_behaviors: hydrateBehaviors(followUp),
    close_message: close.message || '',
    inactivity_minutes: close.inactivity_minutes ?? 30,
    no_followup_action: parseNoFollowupAction(close.no_followup_actions),
  });
};

const fetchDepartment = async () => {
  const { data } = await axios.get(agentUrl());
  if (data) {
    hydrate(data);
    summary.value = {
      steps: data.steps_count ?? 0,
      tools: data.tools_count ?? 0,
      knowledge: data.knowledge_sources_count ?? 0,
    };
  }
  captureDept();
};

const buildFollowUp = () => {
  const behaviors = form.followup_behaviors.map(b => ({
    context: b.context,
    windows:
      b.context === 'custom'
        ? b.windows
            .filter(w => w.start && w.end)
            .map(w => ({ start: w.start, end: w.end }))
        : [],
    attempts: b.attempts
      .filter(a => vuToMinutes(a) > 0)
      .map(a => ({
        delay_minutes: vuToMinutes(a),
        message: (a.message || '').trim(),
      })),
    no_response_action: b.no_response_action,
  }));
  return {
    enabled: behaviors.length > 0,
    behaviors,
  };
};

// Finalização (close_rules). O motor roda em Ai::FollowupConversationJob
// (run_action/run_fallback_action 'finalize'): envia a mensagem de encerramento
// e resolve a conversa após a janela de inatividade.
const buildFinalization = () => ({
  message: (form.close_message || '').trim(),
  inactivity_minutes: Number(form.inactivity_minutes) || 30,
  // Decisão direta quando não há follow-up (ordem do array = prioridade).
  no_followup_actions: form.no_followup_action ? [form.no_followup_action] : [],
});

const buildPayload = () => ({
  ai_agent: {
    behavior: {
      auto_attendance: true,
      grouping: { delay_seconds: Number(form.group_delay_seconds) || 0 },
      max_replies: Number(form.max_replies) || 0,
      max_input_chars: Number(form.max_input_chars) || 0,
      max_input_action: form.max_input_action || 'truncate',
      max_input_message: (form.max_input_message || '').trim(),
      max_document_chars: Number(form.max_document_chars) || 0,
      max_document_message: (form.max_document_message || '').trim(),
      max_audio_seconds: Number(form.max_audio_seconds) || 0,
      max_audio_message: (form.max_audio_message || '').trim(),
      reply_scope: 'all',
    },
    follow_up: buildFollowUp(),
    close_rules: buildFinalization(),
    // Transferência determinística (HandoffEvaluator): min_confidence 0 = desligado. Aceito pelo
    // jsonb_params do controller (sem mudança de backend). Keywords foi removido (falso positivo).
    transfer_rules: {
      min_confidence: Number(form.transfer_min_confidence) || 0,
      // 0 = desligado; senão transfere para humano após X mensagens travado numa etapa de coleta.
      stuck_handoff_turns: Number(form.stuck_handoff_turns) || 0,
    },
    playbook: {
      objetivo: form.objetivo,
      // (1) token de concorrência: o backend rejeita com 409 se o playbook mudou desde o load.
      lock_version: playbookLockVersion.value,
      steps: form.steps.filter(s => (s.name || '').trim()).map(stepToApi),
      transfer_when: linesToArray(form.transfer_when_steps),
      close_when: linesToArray(form.close_when_steps),
    },
  },
});

const save = async () => {
  // Obrigatório: pelo menos uma etapa (com nome) quando a aba Etapas está em foco.
  if (
    visibleSections.value.has('steps') &&
    !form.steps.some(s => (s.name || '').trim())
  ) {
    useAlert(t('AI_DEPARTMENTS.FORM.STEP_REQUIRED'));
    return;
  }
  isSaving.value = true;
  try {
    const { data } = await axios.patch(agentUrl(), buildPayload());
    // (Q6) Re-hidrata o lock_version com a versão FRESCA da resposta. Com (B) o save dispara por etapa; sem
    // isto, o 2º save da sequência mandaria a versão velha e levaria 409 SEMPRE. O serialize devolve
    // playbook.as_json (inclui lock_version), a mesma forma que o load lê. Fallback: preserva o atual.
    playbookLockVersion.value =
      data?.playbook?.lock_version ?? playbookLockVersion.value;
    useAlert(t('AI_DEPARTMENTS.SAVED'));
    conflict.value = { phase: null };
    resetDept();
  } catch (error) {
    // (1) 409 = o playbook mudou no servidor desde o load. NÃO sobrescreve nem descarta: mostra a tarja de
    // conflito com as alterações do usuário PRESERVADAS na tela; ele clica em "Recarregar e reaplicar".
    if (error?.response?.status === 409) {
      conflict.value = { phase: 'detected' };
    } else {
      useAlert(t('AI_DEPARTMENTS.ERROR'));
    }
  } finally {
    isSaving.value = false;
  }
};

// (1) "Recarregar e reaplicar": rebusca o playbook fresco (com a mudança out-of-band) e junta com as
// alterações do usuário via reconcileSteps. 'merged' -> aplica e o usuário revisa/salva; 'ambiguous' (array
// mudou de tamanho) -> mantém tudo na tela e oferece copiar/recarregar. NUNCA descarta o trabalho do usuário.
const reapplyConflict = async () => {
  isSaving.value = true;
  try {
    const { data } = await axios.get(agentUrl());
    const freshPlaybook = data?.playbook || {};
    const freshSteps = parseSteps(freshPlaybook.steps);
    const result = reconcileSteps(freshSteps, form.steps, loadedSteps.value);
    if (result.status === 'merged') {
      form.steps = result.steps;
      loadedSteps.value = cloneSteps(result.steps);
      playbookLockVersion.value = freshPlaybook.lock_version ?? 0;
      conflict.value = { phase: 'reapplied' };
    } else {
      conflict.value = { phase: 'ambiguous' };
    }
  } catch (error) {
    useAlert(t('AI_DEPARTMENTS.ERROR'));
  } finally {
    isSaving.value = false;
  }
};

// Fallback do caso ambíguo: copia as etapas do usuário (para reaplicar à mão depois de recarregar). Nunca
// perde o trabalho digitado.
const copyPendingSteps = async () => {
  try {
    await navigator.clipboard.writeText(
      JSON.stringify(form.steps.map(stepToApi), null, 2)
    );
    useAlert(t('AI_DEPARTMENTS.CONFLICT.COPIED'));
  } catch (error) {
    useAlert(t('AI_DEPARTMENTS.ERROR'));
  }
};

// Recarregar descartando (só no caso ambíguo, escolha EXPLÍCITA do usuário após copiar).
const discardAndReload = async () => {
  conflict.value = { phase: null };
  await fetchDepartment();
};

const goBack = () =>
  router.push({
    name: 'ai_agent_detail',
    params: { agentId: route.params.agentId },
  });

// Operational readiness (%): a checklist over data already loaded — no backend.
// 'INSTRUCTIONS'/'OBJETIVO' removidos: eram um ✓ enganoso pra campos sem editor na UI. O % é
// dinâmico (divide por checks.length), então cada remoção some sem desalinhar a conta.
const readinessChecks = computed(() => [
  { key: 'STEPS', ok: summary.value.steps > 0 },
  { key: 'KNOWLEDGE', ok: summary.value.knowledge > 0 },
  { key: 'TOOLS', ok: summary.value.tools > 0 },
]);
const readinessPct = computed(() => {
  const checks = readinessChecks.value;
  return checks.length
    ? Math.round((checks.filter(c => c.ok).length / checks.length) * 100)
    : 0;
});

// --- Histórico de versões (painel extraído em AiVersionHistory.vue) ---
const versionsBaseUrl = computed(
  () => `${agentUrl()}/ai_agent_behavior_versions`
);

// --- Etapas (cards arrastáveis; edição inline no próprio card) ---
// Em edição: número (editar aquele card), 'new' (adicionar) ou null (nada).
const editingStepIndex = ref(null);

// (A) Aviso ao sair com pendência. Rede de segurança MESMO com (B): o form sujo (deptDirty) OU um editor
// de etapa ABERTO (editingStepIndex != null) — o rascunho digitado sem clicar em Salvar é o caso que se
// perdia. Reusa o composable existente (onBeforeRouteLeave + confirm).
useUnsavedChangesGuard(
  () => deptDirty.value || editingStepIndex.value !== null,
  'AI_DEPARTMENTS.FORM.UNSAVED_LEAVE_CONFIRM'
);

const openNewStep = () => {
  editingStepIndex.value = 'new';
};
const openEditStep = index => {
  editingStepIndex.value = index;
};
const saveStep = async payload => {
  if (editingStepIndex.value === 'new') {
    form.steps.push({ uid: nextStepUid(), ...payload });
  } else if (typeof editingStepIndex.value === 'number') {
    const i = editingStepIndex.value;
    form.steps.splice(i, 1, mergeStepEdit(form.steps[i], payload));
  }
  editingStepIndex.value = null;
  // (B) O Salvar da etapa PERSISTE na hora — não só fecha o editor. Reusa o save() do rodapé (mesma PATCH do
  // departamento inteiro; não há rota por etapa). O lock_version #324 é re-hidratado no save() (ver Q6), então
  // salvar várias etapas em sequência não dá 409. Fecha a armadilha do "Salvar que só fechava o editor".
  await save();
};
const cancelStep = () => {
  editingStepIndex.value = null;
};
const removeStep = index => {
  if (editingStepIndex.value === index) editingStepIndex.value = null;
  form.steps.splice(index, 1);
};

// --- Follow-up: comportamentos (1 por contexto), cada um com tentativas/ação ---
const FU_MAX_ATTEMPTS = 10;
const fuUnitOptions = computed(() => [
  { value: 'minutos', label: t('AI_DEPARTMENTS.FOLLOWUP.UNIT_MINUTES') },
  { value: 'horas', label: t('AI_DEPARTMENTS.FOLLOWUP.UNIT_HOURS') },
]);
// O que fazer quando a mensagem do cliente passa do limite de caracteres.
const inputActionOptions = computed(() => [
  {
    value: 'truncate',
    label: t('AI_DEPARTMENTS.ATTENDANCE.INPUT_LIMIT_ACTION_TRUNCATE'),
  },
  {
    value: 'ask_resume',
    label: t('AI_DEPARTMENTS.ATTENDANCE.INPUT_LIMIT_ACTION_ASK_RESUME'),
  },
]);
const fuContextOptions = computed(() => [
  { value: 'inbox_hours', label: t('AI_DEPARTMENTS.FOLLOWUP.CTX_INBOX') },
  { value: 'outside_hours', label: t('AI_DEPARTMENTS.FOLLOWUP.CTX_OUTSIDE') },
  { value: 'custom', label: t('AI_DEPARTMENTS.FOLLOWUP.CTX_CUSTOM') },
]);
const fuContextLabel = ctx =>
  fuContextOptions.value.find(o => o.value === ctx)?.label || ctx;
// 1 por contexto fixo (inbox_hours/outside_hours); "custom" é ilimitado. Cada card só
// oferece os fixos ainda não usados por OUTRO card (mantém o próprio).
const contextOptionsFor = bhv =>
  fuContextOptions.value.filter(
    o =>
      o.value === 'custom' ||
      o.value === bhv.context ||
      !form.followup_behaviors.some(b => b !== bhv && b.context === o.value)
  );
const fuNoResponseOptions = computed(() => [
  { value: 'assign', label: t('AI_DEPARTMENTS.FOLLOWUP.NR_ASSIGN') },
  { value: 'finalize', label: t('AI_DEPARTMENTS.FOLLOWUP.NR_FINALIZE') },
  { value: 'discard', label: t('AI_DEPARTMENTS.FOLLOWUP.NR_DISCARD') },
  { value: 'wait', label: t('AI_DEPARTMENTS.FOLLOWUP.NR_WAIT') },
  {
    value: 'wait_business_hours',
    label: t('AI_DEPARTMENTS.FOLLOWUP.NR_WAIT_HOURS'),
  },
]);
// O label do contador de tentativas reflete a ação escolhida em "Se o cliente não responder"
// (bhv.no_response_action — o VALUE não muda, só o texto). Fallback para COUNT_LABEL se vier
// vazio/inválido. Chaves estáticas por caso (evita o dynamic-key do intlify e reage em tempo real).
const followupCountLabel = action => {
  switch (action) {
    case 'assign':
      return t('AI_DEPARTMENTS.FOLLOWUP.COUNT_LABEL_ASSIGN');
    case 'finalize':
      return t('AI_DEPARTMENTS.FOLLOWUP.COUNT_LABEL_FINALIZE');
    case 'discard':
      return t('AI_DEPARTMENTS.FOLLOWUP.COUNT_LABEL_DISCARD');
    case 'wait':
      return t('AI_DEPARTMENTS.FOLLOWUP.COUNT_LABEL_WAIT');
    case 'wait_business_hours':
      return t('AI_DEPARTMENTS.FOLLOWUP.COUNT_LABEL_WAIT_BUSINESS_HOURS');
    default:
      return t('AI_DEPARTMENTS.FOLLOWUP.COUNT_LABEL');
  }
};
const addBehavior = () => {
  const used = new Set(form.followup_behaviors.map(b => b.context));
  const next =
    ['inbox_hours', 'outside_hours'].find(c => !used.has(c)) || 'custom';
  const b = blankBehavior();
  b.context = next;
  form.followup_behaviors.push(b);
};
const removeBehavior = index => form.followup_behaviors.splice(index, 1);
const addBehaviorWindow = b => b.windows.push(blankWindow());
const removeBehaviorWindow = (b, i) => b.windows.splice(i, 1);
const setBehaviorAttemptCount = (b, value) => {
  const target = Math.max(0, Math.min(FU_MAX_ATTEMPTS, Number(value) || 0));
  while (b.attempts.length < target) b.attempts.push(blankAttempt());
  while (b.attempts.length > target) b.attempts.pop();
};

// --- Finalização: decisão única quando não há follow-up configurado ---
// Escolha única em "pílulas" (não é mais fila ordenada): o motor executa exatamente esta.
const nfActionOptions = computed(() => [
  {
    value: '',
    label: t('AI_DEPARTMENTS.FINALIZATION.NF_DISABLED'),
    icon: 'i-lucide-ban',
  },
  {
    value: 'transfer_ai',
    label: t('AI_DEPARTMENTS.FINALIZATION.NF_TRANSFER_AI'),
    icon: 'i-lucide-bot',
  },
  {
    value: 'transfer_human',
    label: t('AI_DEPARTMENTS.FINALIZATION.NF_TRANSFER_HUMAN'),
    icon: 'i-lucide-user',
  },
  {
    value: 'wait',
    label: t('AI_DEPARTMENTS.FINALIZATION.NF_WAIT'),
    icon: 'i-lucide-clock',
  },
  {
    value: 'finalize',
    label: t('AI_DEPARTMENTS.FINALIZATION.NF_FINALIZE'),
    icon: 'i-lucide-check-circle',
  },
]);

onMounted(async () => {
  await fetchDepartment();
  captureDept();
  await Promise.all([
    fetchCustomAttributes(),
    fetchLeadVariables(),
    fetchDeptTools(),
    fetchLabels(),
    fetchTeams(),
    fetchAgent(),
    fetchAgents(),
  ]);
});
</script>

<template>
  <div
    :class="
      embedded
        ? 'w-full'
        : 'w-full h-full overflow-auto bg-n-background p-4 sm:p-6'
    "
  >
    <div
      :class="
        embedded
          ? 'w-full flex flex-col gap-3'
          : 'max-w-4xl mx-auto flex flex-col gap-3'
      "
    >
      <button
        v-if="!embedded"
        type="button"
        class="self-start text-sm text-n-slate-11 hover:text-n-slate-12"
        @click="goBack"
      >
        {{ $t('AI_DEPARTMENTS.BACK') }}
      </button>

      <div
        :class="
          embedded
            ? 'flex flex-col gap-6'
            : 'rounded-2xl border border-n-weak bg-n-solid-1 px-4 sm:px-10 py-6 sm:py-7 flex flex-col gap-6'
        "
      >
        <div v-if="!embedded" class="flex items-center justify-between gap-4">
          <h1
            class="text-2xl sm:text-3xl font-semibold text-n-slate-12 truncate"
          >
            {{ form.name || $t('AI_DEPARTMENTS.NEW') }}
          </h1>
          <Logo class="h-8 w-auto shrink-0" />
        </div>

        <!-- Operational summary: what this agent is made of, at a glance -->
        <div
          v-if="!isNew && !embedded"
          class="flex flex-wrap items-center gap-x-4 gap-y-2 text-sm text-n-slate-11"
        >
          <span class="inline-flex items-center gap-1.5">
            <span class="i-lucide-list-checks size-4" />
            {{ $t('AI_DEPARTMENTS.STATS_STEPS', { count: summary.steps }) }}
          </span>
          <span class="inline-flex items-center gap-1.5">
            <span class="i-lucide-wrench size-4" />
            {{ $t('AI_DEPARTMENTS.STATS_TOOLS', { count: summary.tools }) }}
          </span>
          <span class="inline-flex items-center gap-1.5">
            <span class="i-lucide-book-open size-4" />
            {{
              $t('AI_DEPARTMENTS.STATS_KNOWLEDGE', { count: summary.knowledge })
            }}
          </span>
        </div>

        <!-- Prontidão Operacional: checklist sobre dados já carregados (sem backend) -->
        <div
          v-if="!isNew && !embedded"
          class="rounded-xl border border-n-weak bg-n-solid-2 p-4 flex flex-col gap-3"
        >
          <div class="flex items-center justify-between gap-3">
            <span class="text-sm font-semibold text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.READINESS.TITLE') }}
            </span>
            <span
              class="text-lg font-semibold"
              :class="
                readinessPct === 100
                  ? 'text-n-teal-11'
                  : readinessPct >= 60
                    ? 'text-n-slate-12'
                    : 'text-n-amber-11'
              "
            >
              {{ `${readinessPct}%` }}
            </span>
          </div>
          <div class="flex flex-wrap gap-x-4 gap-y-1.5">
            <span
              v-for="check in readinessChecks"
              :key="check.key"
              class="inline-flex items-center gap-1.5 text-xs"
              :class="check.ok ? 'text-n-slate-11' : 'text-n-amber-11'"
            >
              <span
                class="size-3.5"
                :class="
                  check.ok
                    ? 'i-lucide-check-circle-2 text-n-teal-11'
                    : 'i-lucide-alert-circle'
                "
              />
              {{ $t(`AI_DEPARTMENTS.READINESS.${check.key}`) }}
            </span>
          </div>
        </div>

        <div
          v-if="!embedded"
          class="flex flex-wrap items-center gap-x-5 gap-y-1 border-b border-n-weak"
        >
          <button
            v-for="tab in ['instructions', 'steps', 'tools']"
            :key="tab"
            type="button"
            class="pb-2.5 text-sm font-medium border-b-2 -mb-px disabled:opacity-40"
            :class="
              activeTab === tab
                ? 'border-n-brand text-n-brand'
                : 'border-transparent text-n-slate-11 hover:text-n-slate-12'
            "
            :disabled="isNew && tab !== 'instructions'"
            @click="activeTab = tab"
          >
            {{ $t(`AI_DEPARTMENTS.DETAIL_TABS.${tab.toUpperCase()}`) }}
          </button>
          <span class="flex items-center gap-2 pb-2.5 ml-1 text-n-slate-10">
            <span class="w-px h-3.5 bg-n-weak" />
            <span class="text-xs">{{
              $t('AI_DEPARTMENTS.ADVANCED_LABEL')
            }}</span>
          </span>
          <button
            v-for="tab in ['attendance', 'followup']"
            :key="tab"
            type="button"
            class="pb-2.5 text-sm font-medium border-b-2 -mb-px disabled:opacity-40"
            :class="
              activeTab === tab
                ? 'border-n-brand text-n-brand'
                : 'border-transparent text-n-slate-10 hover:text-n-slate-12'
            "
            :disabled="isNew"
            @click="activeTab = tab"
          >
            {{ $t(`AI_DEPARTMENTS.DETAIL_TABS.${tab.toUpperCase()}`) }}
          </button>
        </div>

        <!-- ATENDIMENTO -->
        <div
          v-if="visibleSections.has('attendance')"
          class="flex flex-col gap-5"
        >
          <section
            class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-3"
          >
            <h2 class="text-sm font-medium text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.GROUPING_TITLE') }}
            </h2>
            <p class="text-sm text-n-slate-11 mb-0">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.GROUPING_HINT') }}
            </p>
            <label class="flex flex-col gap-1 text-sm text-n-slate-12 max-w-xs">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.GROUPING_DELAY') }}
              <input
                v-model="form.group_delay_seconds"
                type="number"
                min="0"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
              />
            </label>
          </section>

          <section
            class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-3"
          >
            <h2 class="text-sm font-medium text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.MAX_REPLIES_TITLE') }}
            </h2>
            <p class="text-sm text-n-slate-11 mb-0">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.MAX_REPLIES_HINT') }}
            </p>
            <label class="flex flex-col gap-1 text-sm text-n-slate-12 max-w-xs">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.MAX_REPLIES_FIELD') }}
              <input
                v-model="form.max_replies"
                type="number"
                min="0"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
              />
            </label>
          </section>

          <section
            class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-3"
          >
            <h2 class="text-sm font-medium text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.INPUT_LIMIT_TITLE') }}
            </h2>
            <p class="text-sm text-n-slate-11 mb-0">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.INPUT_LIMIT_HINT') }}
            </p>
            <label class="flex flex-col gap-1 text-sm text-n-slate-12 max-w-xs">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.INPUT_LIMIT_FIELD') }}
              <input
                v-model="form.max_input_chars"
                type="number"
                min="0"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
              />
            </label>
            <label class="flex flex-col gap-1 text-sm text-n-slate-12 max-w-xs">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.INPUT_LIMIT_ACTION') }}
              <Select
                v-model="form.max_input_action"
                :options="inputActionOptions"
              />
            </label>
            <label
              v-if="form.max_input_action === 'ask_resume'"
              class="flex flex-col gap-1 text-sm text-n-slate-12"
            >
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.INPUT_LIMIT_MESSAGE') }}
              <textarea
                v-model="form.max_input_message"
                rows="2"
                :placeholder="
                  $t(
                    'AI_DEPARTMENTS.ATTENDANCE.INPUT_LIMIT_MESSAGE_PLACEHOLDER'
                  )
                "
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-y min-h-16"
              />
            </label>
          </section>

          <section
            class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-3"
          >
            <h2 class="text-sm font-medium text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.ATTACHMENT_LIMIT_TITLE') }}
            </h2>
            <p class="text-sm text-n-slate-11 mb-0">
              {{ $t('AI_DEPARTMENTS.ATTENDANCE.ATTACHMENT_LIMIT_HINT') }}
            </p>

            <div class="flex flex-col gap-1">
              <label
                class="flex flex-col gap-1 text-sm text-n-slate-12 max-w-xs"
              >
                {{
                  $t(
                    'AI_DEPARTMENTS.ATTENDANCE.ATTACHMENT_LIMIT_DOCUMENT_FIELD'
                  )
                }}
                <input
                  v-model="form.max_document_chars"
                  type="number"
                  min="0"
                  class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
                />
              </label>
              <label
                v-if="Number(form.max_document_chars) > 0"
                class="flex flex-col gap-1 text-sm text-n-slate-12"
              >
                {{
                  $t(
                    'AI_DEPARTMENTS.ATTENDANCE.ATTACHMENT_LIMIT_DOCUMENT_MESSAGE'
                  )
                }}
                <textarea
                  v-model="form.max_document_message"
                  rows="2"
                  :placeholder="
                    $t(
                      'AI_DEPARTMENTS.ATTENDANCE.ATTACHMENT_LIMIT_MESSAGE_PLACEHOLDER_DOCUMENT'
                    )
                  "
                  class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-y min-h-16"
                />
              </label>
            </div>

            <div class="flex flex-col gap-1">
              <label
                class="flex flex-col gap-1 text-sm text-n-slate-12 max-w-xs"
              >
                {{
                  $t('AI_DEPARTMENTS.ATTENDANCE.ATTACHMENT_LIMIT_AUDIO_FIELD')
                }}
                <input
                  v-model="form.max_audio_seconds"
                  type="number"
                  min="0"
                  class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
                />
              </label>
              <label
                v-if="Number(form.max_audio_seconds) > 0"
                class="flex flex-col gap-1 text-sm text-n-slate-12"
              >
                {{
                  $t('AI_DEPARTMENTS.ATTENDANCE.ATTACHMENT_LIMIT_AUDIO_MESSAGE')
                }}
                <textarea
                  v-model="form.max_audio_message"
                  rows="2"
                  :placeholder="
                    $t(
                      'AI_DEPARTMENTS.ATTENDANCE.ATTACHMENT_LIMIT_MESSAGE_PLACEHOLDER_AUDIO'
                    )
                  "
                  class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-y min-h-16"
                />
              </label>
            </div>
          </section>

          <!-- Histórico de versões da configuração (Comportamento + follow-up + etapas) -->
          <AiVersionHistory
            v-if="!isNew"
            :base-url="versionsBaseUrl"
            :title-key="
              embedded
                ? 'AI_AGENTS.VERSIONS.TITLE_SETTINGS'
                : 'AI_AGENTS.VERSIONS.TITLE'
            "
            error-key="AI_DEPARTMENTS.ERROR"
            @restored="fetchDepartment"
          />
        </div>

        <!-- FOLLOW-UP -->
        <div v-if="visibleSections.has('followup')" class="flex flex-col gap-5">
          <section
            class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-4"
          >
            <div class="flex flex-col gap-0.5">
              <h2 class="text-sm font-medium text-n-slate-12 mb-0">
                {{ $t('AI_DEPARTMENTS.FOLLOWUP.TITLE') }}
              </h2>
              <p class="text-xs text-n-slate-11 mb-0">
                {{ $t('AI_DEPARTMENTS.FOLLOWUP.HINT') }}
              </p>
            </div>

            <div class="flex flex-col gap-0.5">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('AI_DEPARTMENTS.FOLLOWUP.BEHAVIORS_TITLE') }}
              </span>
              <p class="text-xs text-n-slate-11 mb-0">
                {{ $t('AI_DEPARTMENTS.FOLLOWUP.BEHAVIORS_HINT') }}
              </p>
            </div>

            <p
              v-if="!form.followup_behaviors.length"
              class="text-sm text-n-slate-11 mb-0"
            >
              {{ $t('AI_DEPARTMENTS.FOLLOWUP.BEHAVIORS_EMPTY') }}
            </p>

            <!-- 1 comportamento por contexto de horário (sem ordem manual) -->
            <div
              v-if="form.followup_behaviors.length"
              class="flex flex-col gap-3"
            >
              <div
                v-for="(bhv, bi) in form.followup_behaviors"
                :key="bhv.uid"
                class="rounded-xl border border-n-weak bg-n-solid-1 p-4 flex flex-col gap-3"
              >
                <div class="flex items-center gap-2">
                  <span class="flex-1 text-sm font-medium text-n-slate-12">
                    {{ fuContextLabel(bhv.context) }}
                  </span>
                  <button
                    type="button"
                    class="shrink-0 text-n-slate-11 hover:text-n-ruby-11"
                    :aria-label="$t('AI_DEPARTMENTS.FOLLOWUP.BEHAVIOR_REMOVE')"
                    @click="removeBehavior(bi)"
                  >
                    <span class="i-lucide-trash-2 size-4 inline-block" />
                  </button>
                </div>

                <div
                  class="flex flex-col gap-1.5 text-sm text-n-slate-12 max-w-sm"
                >
                  <span>{{ $t('AI_DEPARTMENTS.FOLLOWUP.CONTEXT') }}</span>
                  <Select
                    v-model="bhv.context"
                    :options="contextOptionsFor(bhv)"
                  />
                </div>

                <!-- Janelas (somente Personalizado) -->
                <div
                  v-if="bhv.context === 'custom'"
                  class="flex flex-col gap-2"
                >
                  <span class="text-sm text-n-slate-12">
                    {{ $t('AI_DEPARTMENTS.FOLLOWUP.WINDOWS') }}
                  </span>
                  <div
                    v-for="(win, wi) in bhv.windows"
                    :key="win.uid"
                    class="flex items-center gap-2"
                  >
                    <input
                      v-model="win.start"
                      type="time"
                      class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-2 text-sm"
                    />
                    <span class="text-sm text-n-slate-11">
                      {{ $t('AI_DEPARTMENTS.FOLLOWUP.WINDOW_TO') }}
                    </span>
                    <input
                      v-model="win.end"
                      type="time"
                      class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-2 text-sm"
                    />
                    <button
                      type="button"
                      class="shrink-0 text-n-slate-11 hover:text-n-ruby-11"
                      :aria-label="$t('AI_DEPARTMENTS.FOLLOWUP.WINDOW_REMOVE')"
                      @click="removeBehaviorWindow(bhv, wi)"
                    >
                      <span class="i-lucide-x size-4 inline-block" />
                    </button>
                  </div>
                  <button
                    type="button"
                    class="self-start text-sm font-medium text-n-brand hover:underline"
                    @click="addBehaviorWindow(bhv)"
                  >
                    + {{ $t('AI_DEPARTMENTS.FOLLOWUP.WINDOW_ADD') }}
                  </button>
                </div>

                <!-- Tentativas -->
                <label
                  class="flex flex-col gap-1 text-sm text-n-slate-12 max-w-xs"
                >
                  {{ followupCountLabel(bhv.no_response_action) }}
                  <input
                    :value="bhv.attempts.length"
                    type="number"
                    min="0"
                    :max="FU_MAX_ATTEMPTS"
                    class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-2"
                    @input="setBehaviorAttemptCount(bhv, $event.target.value)"
                  />
                </label>

                <div
                  v-for="(attempt, ai) in bhv.attempts"
                  :key="attempt.uid"
                  class="rounded-xl border border-n-weak bg-n-solid-2 p-3 flex flex-col gap-2"
                >
                  <span class="text-sm font-medium text-n-slate-12">
                    {{
                      $t('AI_DEPARTMENTS.FOLLOWUP.ATTEMPT_LABEL', {
                        n: ai + 1,
                      })
                    }}
                  </span>
                  <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                    {{ $t('AI_DEPARTMENTS.FOLLOWUP.ATTEMPT_INTERVAL') }}
                    <div class="flex items-stretch gap-2">
                      <input
                        v-model="attempt.value"
                        type="number"
                        min="0"
                        class="w-24 h-10 px-3 rounded-lg border border-n-weak bg-n-solid-1 text-sm"
                      />
                      <div
                        class="shrink-0 [&_select]:!h-10 [&_select]:!py-0 [&>div]:h-full"
                      >
                        <Select
                          v-model="attempt.unit"
                          :options="fuUnitOptions"
                        />
                      </div>
                    </div>
                  </label>
                  <label class="flex flex-col gap-1 text-sm text-n-slate-12">
                    {{ $t('AI_DEPARTMENTS.FOLLOWUP.ATTEMPT_MESSAGE') }}
                    <textarea
                      v-model="attempt.message"
                      rows="2"
                      :placeholder="
                        $t(
                          'AI_DEPARTMENTS.FOLLOWUP.ATTEMPT_MESSAGE_PLACEHOLDER'
                        )
                      "
                      class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-y min-h-16"
                    />
                  </label>
                </div>

                <!-- Ação se o cliente não responder -->
                <div
                  class="flex flex-col gap-1.5 text-sm text-n-slate-12 max-w-sm"
                >
                  <span>{{ $t('AI_DEPARTMENTS.FOLLOWUP.NO_RESPONSE') }}</span>
                  <Select
                    v-model="bhv.no_response_action"
                    :options="fuNoResponseOptions"
                  />
                  <span class="text-xs text-n-slate-11">
                    {{ $t('AI_DEPARTMENTS.FOLLOWUP.NO_RESPONSE_HINT') }}
                  </span>
                </div>
              </div>
            </div>

            <button
              type="button"
              class="self-start text-sm font-medium text-n-brand hover:underline"
              @click="addBehavior"
            >
              + {{ $t('AI_DEPARTMENTS.FOLLOWUP.BEHAVIOR_ADD') }}
            </button>
          </section>
        </div>

        <!-- FINALIZAÇÃO (encerrar conversas) -->
        <div
          v-if="visibleSections.has('finalization')"
          class="flex flex-col gap-5"
        >
          <section
            class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-4"
          >
            <div class="flex flex-col gap-0.5">
              <h2 class="text-sm font-medium text-n-slate-12 mb-0">
                {{ $t('AI_DEPARTMENTS.FINALIZATION.TITLE') }}
              </h2>
              <p class="text-xs text-n-slate-11 mb-0">
                {{ $t('AI_DEPARTMENTS.FINALIZATION.HINT') }}
              </p>
            </div>

            <label class="flex flex-col gap-1 text-sm text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.FINALIZATION.MESSAGE') }}
              <textarea
                v-model="form.close_message"
                rows="3"
                :placeholder="
                  $t('AI_DEPARTMENTS.FINALIZATION.MESSAGE_PLACEHOLDER')
                "
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-y min-h-[5rem]"
              />
            </label>

            <!-- Encerrar quando (close_when): mora em ai_playbooks.close_when; aqui é só a posição
                 visual, perto da mensagem de encerramento que é enviada quando o gatilho dispara. -->
            <label class="flex flex-col gap-1 text-sm text-n-slate-12">
              {{ $t('AI_DEPARTMENTS.FORM.CLOSE_WHEN') }}
              <textarea
                v-model="form.close_when_steps"
                rows="4"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-y min-h-[5rem] leading-relaxed"
              />
              <span class="text-xs text-n-slate-11">
                {{ $t('AI_DEPARTMENTS.FORM.CLOSE_WHEN_HINT') }}
              </span>
            </label>

            <label class="flex flex-col gap-1 text-sm text-n-slate-12 max-w-xs">
              {{ $t('AI_DEPARTMENTS.FINALIZATION.INACTIVITY') }}
              <input
                v-model="form.inactivity_minutes"
                type="number"
                min="0"
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
              />
              <span class="text-xs text-n-slate-11">
                {{ $t('AI_DEPARTMENTS.FINALIZATION.INACTIVITY_HINT') }}
              </span>
            </label>

            <!-- Decisão direta quando NÃO há follow-up configurado -->
            <div class="flex flex-col gap-3 pt-1 border-t border-n-weak">
              <div class="flex flex-col gap-0.5 pt-3">
                <span class="text-sm font-medium text-n-slate-12">
                  {{ $t('AI_DEPARTMENTS.FINALIZATION.NF_TITLE') }}
                </span>
                <p class="text-xs text-n-slate-11 mb-0">
                  {{ $t('AI_DEPARTMENTS.FINALIZATION.NF_HINT') }}
                </p>
              </div>

              <!-- Escolha única em pílulas segmentadas -->
              <div class="flex flex-wrap gap-1.5 rounded-xl bg-n-alpha-2 p-1">
                <button
                  v-for="opt in nfActionOptions"
                  :key="opt.value || 'none'"
                  type="button"
                  class="inline-flex flex-1 min-w-[8rem] items-center justify-center gap-1.5 px-4 py-2 rounded-lg text-sm font-medium transition-colors"
                  :class="
                    form.no_followup_action === opt.value
                      ? 'bg-n-brand text-white shadow-sm'
                      : 'text-n-slate-11 hover:text-n-slate-12 hover:bg-n-alpha-1'
                  "
                  @click="form.no_followup_action = opt.value"
                >
                  <span :class="opt.icon" class="size-4 shrink-0" />
                  {{ opt.label }}
                </button>
              </div>
              <p
                v-if="form.no_followup_action === 'finalize'"
                class="text-xs text-n-slate-11 mb-0"
              >
                {{ $t('AI_DEPARTMENTS.FINALIZATION.NF_FINALIZE_BADGE') }}
              </p>
            </div>
          </section>
        </div>

        <!-- ETAPAS -->
        <div v-if="visibleSections.has('steps')" class="flex flex-col gap-5">
          <section
            class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-4"
          >
            <div class="flex flex-col gap-0.5">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('AI_DEPARTMENTS.STEPS_TITLE') }}
              </span>
              <p class="text-xs text-n-slate-11 mb-0">
                {{ $t('AI_DEPARTMENTS.STEPS_DESC') }}
              </p>
            </div>

            <p
              v-if="!form.steps.length && editingStepIndex !== 'new'"
              class="text-sm text-n-slate-11 mb-0"
            >
              {{ $t('AI_DEPARTMENTS.FORM.STEP_EMPTY') }}
            </p>

            <!-- Cards arrastáveis (reordenar pelo handle) -->
            <Draggable
              v-if="form.steps.length"
              v-model="form.steps"
              item-key="uid"
              handle=".step-drag"
              tag="div"
              class="flex flex-col gap-2"
            >
              <template #item="{ element, index }">
                <div
                  :key="element.uid"
                  class="rounded-xl border border-n-weak bg-n-solid-1"
                >
                  <!-- Edição inline (abre no próprio card) -->
                  <AiStepForm
                    v-if="editingStepIndex === index"
                    :step="element"
                    :is-new="false"
                    :index="index"
                    :labels="labels"
                    :teams="teams"
                    :custom-attributes="customAttributes"
                    :lead-variables="leadVariables"
                    :tools="deptTools"
                    :agent-id="route.params.agentId"
                    :handoff-teams="handoffTeams"
                    :handoff-agents="handoffAgents"
                    class="p-4"
                    @save="saveStep"
                    @cancel="cancelStep"
                    @variable-created="onVariableCreated"
                    @variable-deleted="onVariableDeleted"
                  />
                  <!-- Linha colapsada -->
                  <div v-else class="flex items-center gap-3 px-3 py-2.5">
                    <span
                      class="step-drag i-lucide-grip-vertical size-4 shrink-0 text-n-slate-10 cursor-grab"
                      :aria-label="$t('AI_DEPARTMENTS.FORM.STEP_DRAG')"
                    />
                    <span
                      class="shrink-0 w-5 text-xs font-medium text-n-slate-11"
                    >
                      {{ index + 1 }}
                    </span>
                    <div class="min-w-0 flex-1">
                      <p
                        class="text-sm font-medium text-n-slate-12 mb-0 truncate"
                      >
                        {{ element.name }}
                      </p>
                      <p
                        v-if="element.objective"
                        class="text-xs text-n-slate-11 mb-0 truncate"
                      >
                        {{ element.objective }}
                      </p>
                    </div>
                    <span
                      v-if="element.automation_on_complete"
                      class="shrink-0 i-lucide-zap size-3.5 text-n-amber-11"
                      :title="$t('AI_DEPARTMENTS.FORM.STEP_AUTOMATION')"
                    />
                    <button
                      type="button"
                      class="shrink-0 text-n-slate-11 hover:text-n-slate-12"
                      :aria-label="$t('AI_DEPARTMENTS.FORM.STEP_EDIT')"
                      @click="openEditStep(index)"
                    >
                      <span class="i-lucide-pencil size-4 inline-block" />
                    </button>
                    <button
                      type="button"
                      class="shrink-0 text-n-slate-11 hover:text-n-ruby-11"
                      :aria-label="$t('AI_DEPARTMENTS.FORM.STEP_REMOVE')"
                      @click="removeStep(index)"
                    >
                      <span class="i-lucide-trash-2 size-4 inline-block" />
                    </button>
                  </div>
                </div>
              </template>
            </Draggable>

            <!-- Adicionar nova etapa (mesmo formulário, ao fim da lista) -->
            <div
              v-if="editingStepIndex === 'new'"
              class="rounded-xl border border-n-weak bg-n-solid-1 p-4"
            >
              <AiStepForm
                :step="null"
                is-new
                :index="form.steps.length"
                :labels="labels"
                :teams="teams"
                :custom-attributes="customAttributes"
                :lead-variables="leadVariables"
                :tools="deptTools"
                :agent-id="route.params.agentId"
                :handoff-teams="handoffTeams"
                :handoff-agents="handoffAgents"
                @save="saveStep"
                @cancel="cancelStep"
                @variable-created="onVariableCreated"
                @variable-deleted="onVariableDeleted"
              />
            </div>

            <!-- Adicionar etapa (sem limite) -->
            <div v-if="editingStepIndex === null" class="flex justify-end">
              <button
                type="button"
                class="shrink-0 text-sm font-medium px-4 py-1.5 rounded-full bg-n-brand text-white"
                @click="openNewStep"
              >
                + {{ $t('AI_DEPARTMENTS.FORM.STEP_ADD') }}
              </button>
            </div>
            <!-- Quando transferir para um humano: transfer_when (orienta a IA) + min_confidence
                 (gatilho determinístico). UMA explicação no topo do bloco, não uma por campo. -->
            <div class="flex flex-col gap-3 pt-1 border-t border-n-weak">
              <div class="flex flex-col gap-0.5 pt-3">
                <span class="text-sm font-medium text-n-slate-12">
                  {{ $t('AI_DEPARTMENTS.FORM.TRANSFER_TITLE') }}
                </span>
                <p class="text-xs text-n-slate-11 mb-0">
                  {{ $t('AI_DEPARTMENTS.FORM.TRANSFER_INTRO') }}
                </p>
              </div>
              <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
                  {{ $t('AI_DEPARTMENTS.FORM.TRANSFER_WHEN') }}
                  <textarea
                    v-model="form.transfer_when_steps"
                    rows="6"
                    class="px-3 py-2.5 rounded-lg border border-n-weak bg-n-solid-1 resize-y min-h-28 leading-relaxed"
                  />
                </label>
                <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
                  {{ $t('AI_DEPARTMENTS.FORM.TRANSFER_MIN_CONFIDENCE') }}
                  <input
                    v-model="form.transfer_min_confidence"
                    type="number"
                    min="0"
                    max="1"
                    step="0.1"
                    class="w-32 px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm"
                  />
                </label>
                <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
                  {{ $t('AI_DEPARTMENTS.FORM.STUCK_HANDOFF_TURNS') }}
                  <input
                    v-model="form.stuck_handoff_turns"
                    type="number"
                    min="0"
                    step="1"
                    class="w-32 px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm"
                  />
                  <span class="text-xs text-n-slate-11">
                    {{ $t('AI_DEPARTMENTS.FORM.STUCK_HANDOFF_TURNS_HINT') }}
                  </span>
                </label>
              </div>
            </div>
          </section>
        </div>

        <!-- FERRAMENTAS -->
        <AiTools
          v-if="visibleSections.has('tools') && !isNew"
          :agent-id="route.params.agentId"
        />

        <!-- (1) Tarja de conflito (save defasado / 409). Diz o que FAZER, não só o que houve. As alterações
             do usuário ficam PRESERVADAS na tela em todos os estados. -->
        <div
          v-if="conflict.phase"
          class="flex flex-col gap-2 px-3 py-2.5 rounded-lg bg-n-amber-3 text-n-amber-11"
        >
          <div class="flex items-start gap-2">
            <span class="mt-0.5 shrink-0 size-4 i-lucide-alert-triangle" />
            <span class="flex-1 min-w-0 text-sm">
              <template v-if="conflict.phase === 'detected'">
                {{ $t('AI_DEPARTMENTS.CONFLICT.DETECTED') }}
              </template>
              <template v-else-if="conflict.phase === 'reapplied'">
                {{ $t('AI_DEPARTMENTS.CONFLICT.REAPPLIED') }}
              </template>
              <template v-else>
                {{ $t('AI_DEPARTMENTS.CONFLICT.AMBIGUOUS') }}
              </template>
            </span>
          </div>
          <div class="flex flex-wrap gap-2 pl-6">
            <button
              v-if="conflict.phase === 'detected'"
              type="button"
              class="text-xs font-medium px-2.5 py-1.5 rounded-lg bg-n-amber-9 text-white disabled:opacity-50"
              :disabled="isSaving"
              @click="reapplyConflict"
            >
              {{ $t('AI_DEPARTMENTS.CONFLICT.REAPPLY_ACTION') }}
            </button>
            <template v-if="conflict.phase === 'ambiguous'">
              <button
                type="button"
                class="text-xs font-medium px-2.5 py-1.5 rounded-lg bg-n-amber-9 text-white"
                @click="copyPendingSteps"
              >
                {{ $t('AI_DEPARTMENTS.CONFLICT.COPY_ACTION') }}
              </button>
              <button
                type="button"
                class="text-xs px-2.5 py-1.5 rounded-lg bg-n-alpha-2 text-n-slate-12"
                @click="discardAndReload"
              >
                {{ $t('AI_DEPARTMENTS.CONFLICT.RELOAD_ACTION') }}
              </button>
            </template>
          </div>
        </div>

        <!-- Save bar (config tabs only) -->
        <div
          v-if="showSave"
          class="flex items-center justify-between gap-2 border-t border-n-weak pt-4 flex-wrap"
        >
          <!-- (C) Com (B), salvar a etapa já persistiu tudo — o rodapé fica sem pendência. O botão já
               desabilita (:disabled=!deptDirty), e este rótulo torna explícito o "nada a salvar", para o
               usuário não clicar por precaução. Some assim que houver qualquer edição (deptDirty). -->
          <span class="text-xs text-n-slate-11">
            <template v-if="!deptDirty && !isSaving">
              {{ $t('AI_DEPARTMENTS.FORM.ALL_SAVED') }}
            </template>
          </span>
          <div class="flex gap-2">
            <button
              v-if="!embedded"
              type="button"
              class="text-sm px-3 py-2 rounded-lg bg-n-alpha-2 text-n-slate-12"
              @click="goBack"
            >
              {{ $t('AI_DEPARTMENTS.FORM.CANCEL') }}
            </button>
            <button
              type="button"
              class="text-sm font-medium px-4 py-2 rounded-lg bg-n-brand text-white disabled:opacity-50 disabled:cursor-not-allowed"
              :disabled="isSaving || !deptDirty"
              @click="save"
            >
              {{ $t('AI_DEPARTMENTS.FORM.SAVE') }}
            </button>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
