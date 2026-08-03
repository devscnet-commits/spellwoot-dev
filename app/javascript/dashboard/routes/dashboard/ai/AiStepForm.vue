<script setup>
/* global axios */
import { reactive, computed, ref } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import Select from 'dashboard/components-next/select/Select.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import AiPromptAssistant from './AiPromptAssistant.vue';
import { buildStepPayload } from './aiStepPayload';
import { buildSlotKeyOptions } from './aiSlotSource';

// Formulário de uma etapa, usado tanto na edição inline (dentro do card) quanto ao adicionar.
// Mantém um rascunho local e devolve o payload no save (o pai grava em form.steps). O PAYLOAD é
// idêntico ao de antes — o redesenho é só de apresentação/hierarquia + a faixa de feedback do slot.
const props = defineProps({
  step: { type: Object, default: null },
  isNew: { type: Boolean, default: false },
  // Posição da etapa na lista (0-based) — só para o badge "Etapa N".
  index: { type: Number, default: 0 },
  // Fontes para os seletores das automações (carregadas pelo pai).
  labels: { type: Array, default: () => [] },
  teams: { type: Array, default: () => [] },
  customAttributes: { type: Array, default: () => [] },
  // Variáveis INTERNAS do department (Ai::LeadVariable). Fonte do Select da chave junto com customAttributes;
  // o inline-create grava aqui (não em CustomAttributeDefinition).
  leadVariables: { type: Array, default: () => [] },
  // (B2) Ferramentas do department (Ai::Tool), carregadas pelo pai. Fonte do Select "opções vêm de: ferramenta"
  // num slot choice. Usadas só pelo NOME (domain_from_tool guarda o nome). Vazio => o modo ferramenta avisa.
  tools: { type: Array, default: () => [] },
  // Contexto para o POST do inline-create de LeadVariable (nested em ai_agents -> ai_departments).
  agentId: { type: [String, Number], default: null },
  departmentId: { type: [String, Number], default: null },
  departments: { type: Array, default: () => [] },
  // Desfecho (b)-core: times da WHITELIST do agente (handoff_team_ids) e IAs de handoff (handoff_agent_ids),
  // já resolvidos pelo pai. NÃO são todos os times da conta (props.teams) — é a lista que a resolução do
  // backend aceita (é aqui que entra a validação de escrita: fora da whitelist não é selecionável).
  handoffTeams: { type: Array, default: () => [] },
  handoffAgents: { type: Array, default: () => [] },
});
const emit = defineEmits([
  'save',
  'cancel',
  'variableCreated',
  'variableDeleted',
]);
const { t } = useI18n();
const route = useRoute();
const assistantOpen = ref(false);
const advancedOpen = ref(false);

const WEBHOOK_METHODS = ['POST', 'GET', 'PUT', 'PATCH', 'DELETE'];

const draft = reactive({
  name: props.step?.name || '',
  instructions: props.step?.instructions || '',
  group_delay_seconds: props.step?.group_delay_seconds ?? '',
  // Chave do slot que a etapa coleta (collect['attribute']). Escolhida no Select da união (LeadVariable ∪
  // CustomAttributeDefinition). Vazia => etapa informativa (buildStepPayload emite collect: null). NÃO há
  // mais inferência da instrução — a etapa DECLARA a variável.
  collectAttribute: props.step?.collect?.attribute || '',
  collectType: props.step?.collect?.type || 'text',
  collectOptions: Array.isArray(props.step?.collect?.options)
    ? props.step.collect.options.join('\n')
    : '',
  // (B2) Fonte das opções de um slot choice: 'fixed' (lista digitada) ou 'tool' (domínio dinâmico = resultado
  // da ferramenta). Semeado do banco: collect.domain_from_tool presente => 'tool'. collectDomainTool guarda o
  // NOME da ferramenta (é o que Ai::StepSlot.domain_from_tool lê e resolve por department.tools.find_by(name:)).
  collectSource: props.step?.collect?.domain_from_tool ? 'tool' : 'fixed',
  collectDomainTool: props.step?.collect?.domain_from_tool || '',
  // Obrigatório? SEMPRE no nível da etapa (slot_required), NUNCA collect.required (Gap 2 desacoplou).
  // Default obrigatório; null/undefined legado => obrigatório.
  slotRequired: props.step?.slot_required ?? true,
  // Conhecimento que a etapa DECLARA precisar (step['knowledge']): a IA busca ANTES de responder. Semeado
  // do banco (backfill do PR 1). query vazia => a etapa não declara nada. kinds separado por vírgula;
  // input DIRETO do usuário — nenhum estado assíncrono (sem o acoplamento do hasSlot que causou o #306).
  knowledgeQuery: props.step?.knowledge?.query || '',
  knowledgeKinds: Array.isArray(props.step?.knowledge?.kinds)
    ? props.step.knowledge.kinds.join(', ')
    : '',
  // Desfecho declarado AO concluir a etapa (step['on_complete'], (b)-core). SEMEADO do banco — editar sem
  // tocar preserva o valor (a armadilha de #306/knowledge: emitir sem semear apagaria o backfill). action
  // vazia => a etapa não declara desfecho (buildStepPayload emite on_complete: null).
  onCompleteAction: props.step?.on_complete?.action || '',
  onCompleteTeamId: props.step?.on_complete?.team_id ?? '',
  onCompleteTarget: props.step?.on_complete?.target || '',
  // automation_on_complete (booleano) é legado/ignorado; agora usamos automations: [{type, params}].
  automations: (Array.isArray(props.step?.automations)
    ? props.step.automations
    : []
  ).map(a => ({
    type: a?.type || 'tag',
    params: { ...(a?.params || {}) },
  })),
});

// --- Chave do slot: Select da união (LeadVariable ∪ CustomAttributeDefinition), com a ORIGEM marcada
// (interna = memória da IA; painel = espelha na lateral). Empty = etapa informativa. ------------------
const hasSlot = computed(() => !!(draft.collectAttribute || '').trim());

const slotKeyOptions = computed(() => {
  const none = { value: '', label: t('AI_DEPARTMENTS.FORM.SLOT_KEY_NONE') };
  const opts = buildSlotKeyOptions(
    props.leadVariables,
    props.customAttributes
  ).map(o => ({
    value: o.value,
    label:
      o.source === 'panel'
        ? t('AI_DEPARTMENTS.FORM.SLOT_KEY_PANEL', { key: o.value })
        : t('AI_DEPARTMENTS.FORM.SLOT_KEY_INTERNAL', { key: o.value }),
  }));
  return [none, ...opts];
});

// Inline-create: cria uma Ai::LeadVariable (variável INTERNA), NÃO um CustomAttributeDefinition — dado da
// IA é memória de trabalho, não campo editável na lateral. O pai empilha o resultado em leadVariables (para
// a opção aparecer no Select) e aqui já selecionamos a chave recém-criada.
const creatingVariable = ref(false);
const newVariableName = ref('');
const createError = ref('');
const createVariable = async () => {
  const name = newVariableName.value.trim();
  if (!name) return;
  createError.value = '';
  try {
    const { data } = await axios.post(
      `/api/v1/accounts/${route.params.accountId}/ai_agents/${props.agentId}` +
        `/ai_departments/${props.departmentId}/ai_lead_variables`,
      { ai_lead_variable: { name } }
    );
    emit('variableCreated', data); // pai empilha em leadVariables => a opção aparece
    draft.collectAttribute = data.name; // seleciona a recém-criada
    newVariableName.value = '';
    creatingVariable.value = false;
  } catch (error) {
    createError.value =
      error.response?.data?.errors?.join('. ') ||
      t('AI_DEPARTMENTS.FORM.SLOT_KEY_CREATE_ERROR');
  }
};
const cancelCreate = () => {
  creatingVariable.value = false;
  newVariableName.value = '';
  createError.value = '';
};

// Preview da normalização — espelha Ai::LeadVariable#normalize_name (o backend é a autoridade). Regra de
// FORMATO, não de idioma: remove acentos (Latin), minúsculas, só [a-z0-9_]. O usuário vê o que vai virar
// ANTES de criar; vazio (ex.: só caracteres não-latinos) sinaliza que precisa de uma chave em letras/números.
const normalizeVariableName = raw =>
  (raw || '')
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9_]+/g, '_')
    .replace(/_+/g, '_')
    .replace(/^_+|_+$/g, '');
const normalizedPreview = computed(() =>
  normalizeVariableName(newVariableName.value)
);

// Variáveis INTERNAS (LeadVariable) — só estas dá para excluir aqui (CAD é da conta, gerido em Configurações).
const internalVariables = computed(() =>
  (props.leadVariables || []).filter(v => v?.name)
);

// Exclusão: o backend BLOQUEIA (422) se a variável estiver em uso por alguma etapa; o dado já coletado
// permanece em ai_collected_facts/memória do contato (a variável é só metadado do select). Confirma antes.
const deletingId = ref(null);
const deleteError = ref('');
const deleteVariable = async v => {
  if (!v?.id) return;
  const ask = t('AI_DEPARTMENTS.FORM.SLOT_KEY_DELETE_CONFIRM', { key: v.name });
  // eslint-disable-next-line no-alert
  if (!window.confirm(ask)) return;
  deletingId.value = v.id;
  deleteError.value = '';
  try {
    await axios.delete(
      `/api/v1/accounts/${route.params.accountId}/ai_agents/${props.agentId}` +
        `/ai_departments/${props.departmentId}/ai_lead_variables/${v.id}`
    );
    if (draft.collectAttribute === v.name) draft.collectAttribute = ''; // era a selecionada -> limpa
    emit('variableDeleted', v.id); // pai remove de leadVariables
  } catch (error) {
    deleteError.value =
      error.response?.data?.errors?.join('. ') ||
      t('AI_DEPARTMENTS.FORM.SLOT_KEY_DELETE_ERROR');
  } finally {
    deletingId.value = null;
  }
};

// Resumo do estado dos ajustes avançados (mostrado no cabeçalho da seção fechada).
const advancedSummary = computed(() => {
  const delay = Number(draft.group_delay_seconds) || 0;
  const delayPart =
    delay > 0
      ? t('AI_DEPARTMENTS.FORM.ADVANCED_SUMMARY_DELAY', { seconds: delay })
      : t('AI_DEPARTMENTS.FORM.ADVANCED_SUMMARY_NO_DELAY');
  const n = draft.automations.length;
  let autoPart = t('AI_DEPARTMENTS.FORM.ADVANCED_SUMMARY_NO_AUTOMATIONS');
  if (n === 1)
    autoPart = t('AI_DEPARTMENTS.FORM.ADVANCED_SUMMARY_ONE_AUTOMATION');
  else if (n > 1)
    autoPart = t('AI_DEPARTMENTS.FORM.ADVANCED_SUMMARY_N_AUTOMATIONS', {
      count: n,
    });
  return `${delayPart} · ${autoPart}`;
});

const slotTypeOptions = computed(() => [
  { value: 'text', label: t('AI_DEPARTMENTS.FORM.STEP_COLLECT_TYPE_TEXT') },
  { value: 'email', label: t('AI_DEPARTMENTS.FORM.STEP_COLLECT_TYPE_EMAIL') },
  { value: 'cpf', label: t('AI_DEPARTMENTS.FORM.STEP_COLLECT_TYPE_CPF') },
  { value: 'phone', label: t('AI_DEPARTMENTS.FORM.STEP_COLLECT_TYPE_PHONE') },
  { value: 'number', label: t('AI_DEPARTMENTS.FORM.STEP_COLLECT_TYPE_NUMBER') },
  { value: 'choice', label: t('AI_DEPARTMENTS.FORM.STEP_COLLECT_TYPE_CHOICE') },
  {
    value: 'attachment',
    label: t('AI_DEPARTMENTS.FORM.STEP_COLLECT_TYPE_ATTACHMENT'),
  },
]);

// (B2) Ferramentas do department como opções do Select "opções vêm de: ferramenta". O value é o NOME (é o que
// domain_from_tool grava e o backend resolve). Placeholder vazio quando o department não tem ferramenta.
const toolOptions = computed(() =>
  (props.tools || [])
    .map(tl => (tl?.name || '').trim())
    .filter(Boolean)
    .map(name => ({ value: name, label: name }))
);

// Aviso anti-degradação-silenciosa: o slot está em modo ferramenta e o NOME salvo não existe (mais) na lista
// do department (ferramenta removida/renomeada). O runtime já faz fail-open + emite tool_domain.unextractable,
// mas quem edita a etapa precisa VER que o slot voltou a aceitar qualquer valor. Só alerta quando há nome salvo.
const toolDomainMissing = computed(() => {
  if (draft.collectSource !== 'tool') return false;
  const chosen = (draft.collectDomainTool || '').trim();
  if (!chosen) return false;
  return !toolOptions.value.some(o => o.value === chosen);
});

const typeOptions = computed(() => [
  { value: 'tag', label: t('AI_DEPARTMENTS.FORM.AUTOMATION_TYPE_TAG') },
  { value: 'webhook', label: t('AI_DEPARTMENTS.FORM.AUTOMATION_TYPE_WEBHOOK') },
  {
    value: 'change_team',
    label: t('AI_DEPARTMENTS.FORM.AUTOMATION_TYPE_CHANGE_TEAM'),
  },
  {
    value: 'change_ai_department',
    label: t('AI_DEPARTMENTS.FORM.AUTOMATION_TYPE_CHANGE_AI_DEPARTMENT'),
  },
  {
    value: 'update_attribute',
    label: t('AI_DEPARTMENTS.FORM.AUTOMATION_TYPE_UPDATE_ATTRIBUTE'),
  },
]);
const methodOptions = WEBHOOK_METHODS.map(m => ({ value: m, label: m }));
const labelOptions = computed(() =>
  props.labels.map(l => ({ value: l.title, label: l.title }))
);
const teamOptions = computed(() =>
  props.teams.map(tm => ({ value: tm.id, label: tm.name }))
);
// Destino do "Encerrar o atendimento" (o item existir na lista JÁ significa que há desfecho; sem opção
// "Nenhum" — remover o item é que limpa). Linguagem de usuário, não chave técnica.
const onCompleteActionOptions = computed(() => [
  {
    value: 'handoff_human',
    label: t('AI_DEPARTMENTS.FORM.STEP_ON_COMPLETE_HANDOFF_HUMAN'),
  },
  { value: 'close', label: t('AI_DEPARTMENTS.FORM.STEP_ON_COMPLETE_CLOSE') },
  {
    value: 'handoff_ai',
    label: t('AI_DEPARTMENTS.FORM.STEP_ON_COMPLETE_HANDOFF_AI'),
  },
]);
// Time: SÓ a whitelist do agente (não props.teams). target de IA: por NOME (o backend casa por nome).
const handoffTeamOptions = computed(() =>
  props.handoffTeams.map(tm => ({ value: tm.id, label: tm.name }))
);
const handoffAgentOptions = computed(() =>
  props.handoffAgents.map(a => ({ value: a.name, label: a.name }))
);
const departmentOptions = computed(() =>
  props.departments.map(d => ({ value: d.id, label: d.name }))
);
// Só atributos de CONVERSA (a automação grava em conversation.custom_attributes).
const attributeOptions = computed(() =>
  props.customAttributes
    .filter(a => a.attribute_model === 'conversation_attribute')
    .map(a => ({ value: a.attribute_key, label: a.attribute_display_name }))
);

const addAutomation = () => draft.automations.push({ type: 'tag', params: {} });
const removeAutomation = i => draft.automations.splice(i, 1);
// Ao trocar o tipo, zera os parâmetros (evita arrastar params do tipo anterior).
const onTypeChange = i => {
  draft.automations[i].params = {};
};
// "Encerrar o atendimento" (o desfecho, step['on_complete']): entra na lista de automações como um item
// ÚNICO e TERMINAL. NÃO vai para draft.automations (o runner o trataria como "continua") — fica no estado
// próprio, que o buildStepPayload emite em on_complete. Adicionar => default handoff_human; remover => limpa
// (buildStepPayload emite on_complete: null). Só um por etapa (é um objeto, não uma lista).
const addOnComplete = () => {
  draft.onCompleteAction = 'handoff_human';
};
const removeOnComplete = () => {
  draft.onCompleteAction = '';
  draft.onCompleteTeamId = '';
  draft.onCompleteTarget = '';
};

// Payload montado em aiStepPayload.buildStepPayload: slot_required no nível da etapa (nunca
// collect.required), collect só com a chave DECLARADA (collectAttribute; vazio => collect null), sem
// complete_when. Sem flush de inferência — a etapa declara a variável, não há estado assíncrono.
const onSave = () => {
  if (!draft.name.trim()) return;
  emit(
    'save',
    buildStepPayload({
      name: draft.name,
      instructions: draft.instructions,
      groupDelaySeconds: draft.group_delay_seconds,
      automations: draft.automations,
      collectAttribute: draft.collectAttribute,
      collectType: draft.collectType,
      collectOptions: draft.collectOptions,
      collectSource: draft.collectSource,
      collectDomainTool: draft.collectDomainTool,
      slotRequired: draft.slotRequired,
      knowledgeQuery: draft.knowledgeQuery,
      knowledgeKinds: draft.knowledgeKinds,
      onCompleteAction: draft.onCompleteAction,
      onCompleteTeamId: draft.onCompleteTeamId,
      onCompleteTarget: draft.onCompleteTarget,
    })
  );
};
</script>

<template>
  <div class="flex flex-col gap-4">
    <!-- a) Cabeçalho: badge da etapa + nome como TÍTULO do card -->
    <div class="flex items-center gap-2.5">
      <span
        class="shrink-0 px-2 py-0.5 rounded-full bg-n-alpha-2 text-xs font-medium text-n-slate-11"
      >
        {{ $t('AI_DEPARTMENTS.FORM.STEP_NUMBER', { number: index + 1 }) }}
      </span>
      <input
        v-model="draft.name"
        type="text"
        :placeholder="$t('AI_DEPARTMENTS.FORM.STEP_NAME_PLACEHOLDER')"
        class="flex-1 min-w-0 px-2 py-1 text-base font-medium text-n-slate-12 bg-transparent border-0 border-b border-transparent hover:border-n-weak focus:border-n-brand focus:outline-none"
      />
    </div>

    <!-- b) Instruções: o campo PRINCIPAL -->
    <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
      <span class="flex items-center gap-2">
        <span class="font-medium">
          {{ $t('AI_DEPARTMENTS.FORM.STEP_INSTRUCTIONS_LABEL') }}
        </span>
        <span class="text-xs text-n-slate-11">
          {{ $t('AI_DEPARTMENTS.FORM.STEP_INSTRUCTIONS_MICROHINT') }}
        </span>
        <button
          type="button"
          class="i-lucide-sparkles size-4 text-n-slate-10 hover:text-n-brand"
          :title="$t('AI_AGENTS.PROMPT_ASSISTANT.OPEN')"
          @click="assistantOpen = true"
        />
      </span>
      <textarea
        v-model="draft.instructions"
        :placeholder="$t('AI_DEPARTMENTS.FORM.STEP_INSTRUCTIONS_PLACEHOLDER')"
        class="px-3 py-2.5 rounded-lg border border-n-weak bg-n-solid-2 resize-y min-h-[150px] leading-relaxed"
      />
    </label>

    <!-- c) Chave do slot: a etapa DECLARA a variável que coleta (Select da união LeadVariable ∪
         CustomAttributeDefinition, origem marcada). Empty = etapa informativa (escolha explícita, não
         acidente). Inline-create grava LeadVariable interna. NÃO há mais inferência da instrução. -->
    <div
      class="flex flex-col gap-2 px-3 py-2.5 rounded-lg"
      :class="
        hasSlot ? 'bg-n-teal-3 text-n-teal-11' : 'bg-n-alpha-2 text-n-slate-11'
      "
    >
      <span class="text-sm font-medium">
        {{ $t('AI_DEPARTMENTS.FORM.SLOT_KEY_LABEL') }}
      </span>

      <!-- modo normal: ComboBox COM BUSCA da chave + atalho "criar/gerenciar variável". A busca é o que faz
           o usuário VER "documento_cpf" antes de criar "numero_conta" — mata a duplicata na apresentação. -->
      <template v-if="!creatingVariable">
        <ComboBox
          v-model="draft.collectAttribute"
          :options="slotKeyOptions"
          :search-placeholder="$t('AI_DEPARTMENTS.FORM.SLOT_KEY_SEARCH')"
          data-testid="slot-key-select"
        />
        <button
          type="button"
          class="self-start inline-flex items-center gap-1 text-xs underline hover:no-underline"
          @click="creatingVariable = true"
        >
          <span class="i-lucide-plus size-3.5" />
          {{ $t('AI_DEPARTMENTS.FORM.SLOT_KEY_CREATE') }}
        </button>
      </template>

      <!-- inline-create: cria uma variável INTERNA (Ai::LeadVariable), não um atributo de painel -->
      <template v-else>
        <div class="flex items-center gap-2">
          <input
            v-model="newVariableName"
            type="text"
            data-testid="new-variable-name"
            :placeholder="$t('AI_DEPARTMENTS.FORM.SLOT_KEY_CREATE_PLACEHOLDER')"
            class="flex-1 min-w-0 px-2 py-1 rounded border border-n-weak bg-n-solid-1 text-sm text-n-slate-12"
            @keydown.enter.prevent="createVariable"
          />
          <button
            type="button"
            class="shrink-0 text-xs font-medium px-2 py-1 rounded bg-n-brand text-white disabled:opacity-50"
            :disabled="!newVariableName.trim()"
            @click="createVariable"
          >
            {{ $t('AI_DEPARTMENTS.FORM.SLOT_KEY_CREATE_CONFIRM') }}
          </button>
          <button
            type="button"
            class="shrink-0 text-xs underline hover:no-underline"
            @click="cancelCreate"
          >
            {{ $t('AI_DEPARTMENTS.FORM.CANCEL') }}
          </button>
        </div>
        <!-- item 1: preview da normalização — o usuário vê a chave que vai nascer, sem surpresa -->
        <span
          v-if="newVariableName.trim()"
          class="text-xs"
          data-testid="normalized-preview"
        >
          {{
            normalizedPreview
              ? $t('AI_DEPARTMENTS.FORM.SLOT_KEY_NORMALIZED', {
                  key: normalizedPreview,
                })
              : $t('AI_DEPARTMENTS.FORM.SLOT_KEY_NORMALIZED_EMPTY')
          }}
        </span>
        <span class="text-xs">
          {{ $t('AI_DEPARTMENTS.FORM.SLOT_KEY_CREATE_HINT') }}
        </span>
        <span v-if="createError" class="text-xs text-n-ruby-11">
          {{ createError }}
        </span>

        <!-- item 4: gerenciar/excluir variáveis internas existentes. O backend BLOQUEIA se estiver em uso. -->
        <div v-if="internalVariables.length" class="mt-1 flex flex-col gap-1">
          <span class="text-xs font-medium">
            {{ $t('AI_DEPARTMENTS.FORM.SLOT_KEY_MANAGE_LABEL') }}
          </span>
          <div
            v-for="v in internalVariables"
            :key="v.id"
            class="flex items-center justify-between gap-2 text-xs"
          >
            <span class="font-mono truncate">{{ v.name }}</span>
            <button
              type="button"
              class="shrink-0 inline-flex items-center gap-1 text-n-ruby-11 hover:underline disabled:opacity-50"
              :disabled="deletingId === v.id"
              :data-testid="`delete-variable-${v.name}`"
              @click="deleteVariable(v)"
            >
              <span class="i-lucide-trash-2 size-3.5" />
              {{ $t('AI_DEPARTMENTS.FORM.SLOT_KEY_DELETE') }}
            </button>
          </div>
          <span class="text-xs">
            {{ $t('AI_DEPARTMENTS.FORM.SLOT_KEY_DELETE_HINT') }}
          </span>
          <span v-if="deleteError" class="text-xs text-n-ruby-11">
            {{ deleteError }}
          </span>
        </div>
      </template>

      <!-- confirmação de etapa informativa (empty): afirmativo, NÃO erro. Etapa sem coleta é legítima. -->
      <span v-if="!hasSlot && !creatingVariable" class="text-xs">
        {{ $t('AI_DEPARTMENTS.FORM.SLOT_NONE_CONFIRM') }}
      </span>

      <!-- tipo + opções + obrigatório: só quando HÁ chave escolhida -->
      <template v-if="hasSlot">
        <label class="flex flex-col gap-1 text-xs">
          {{ $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_TYPE') }}
          <Select v-model="draft.collectType" :options="slotTypeOptions" />
        </label>
        <!-- choice: as opções vêm de uma LISTA FIXA ou do RESULTADO de uma FERRAMENTA (domínio dinâmico). Um
             modo por vez — o campo do outro some (dois campos de opções visíveis convida a preencher os dois). -->
        <div
          v-if="draft.collectType === 'choice'"
          class="flex flex-col gap-2 text-xs"
        >
          <span class="text-n-slate-11">
            {{ $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_OPTIONS_SOURCE') }}
          </span>
          <div class="flex flex-col gap-1">
            <label class="flex items-start gap-2 text-sm cursor-pointer">
              <input
                v-model="draft.collectSource"
                type="radio"
                value="fixed"
                class="mt-0.5"
              />
              <span>{{
                $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_OPTIONS_SOURCE_FIXED')
              }}</span>
            </label>
            <label class="flex items-start gap-2 text-sm cursor-pointer">
              <input
                v-model="draft.collectSource"
                type="radio"
                value="tool"
                class="mt-0.5"
              />
              <span>{{
                $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_OPTIONS_SOURCE_TOOL')
              }}</span>
            </label>
          </div>

          <!-- lista fixa -->
          <label
            v-if="draft.collectSource !== 'tool'"
            class="flex flex-col gap-1"
          >
            {{ $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_OPTIONS') }}
            <textarea
              v-model="draft.collectOptions"
              rows="2"
              :placeholder="
                $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_OPTIONS_PLACEHOLDER')
              "
              class="px-2 py-1 rounded border border-n-weak bg-n-solid-1 resize-y"
            />
          </label>

          <!-- domínio dinâmico: o resultado da ferramenta é o conjunto de valores aceitos -->
          <template v-else>
            <label class="flex flex-col gap-1">
              {{ $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_TOOL') }}
              <Select
                v-if="toolOptions.length"
                v-model="draft.collectDomainTool"
                :options="toolOptions"
              />
              <span v-else class="text-n-slate-11">
                {{ $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_TOOL_EMPTY') }}
              </span>
            </label>
            <p class="text-n-slate-10">
              {{ $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_TOOL_HINT') }}
            </p>
            <!-- ferramenta salva não existe mais (removida/renomeada): avisa que o slot voltou a aceitar tudo -->
            <p
              v-if="toolDomainMissing"
              data-testid="tool-domain-missing"
              class="flex items-start gap-1.5 text-n-ruby-11"
            >
              <span class="i-lucide-alert-triangle size-3.5 mt-0.5 shrink-0" />
              <span>{{
                $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_TOOL_MISSING', {
                  tool: draft.collectDomainTool,
                })
              }}</span>
            </p>
          </template>
        </div>

        <div class="flex flex-col gap-1 pt-1.5 border-t border-n-teal-5">
          <label class="flex items-start gap-2 text-sm cursor-pointer">
            <input
              v-model="draft.slotRequired"
              type="radio"
              :value="true"
              class="mt-0.5"
            />
            <span>{{ $t('AI_DEPARTMENTS.FORM.SLOT_REQUIRED_YES') }}</span>
          </label>
          <label class="flex items-start gap-2 text-sm cursor-pointer">
            <input
              v-model="draft.slotRequired"
              type="radio"
              :value="false"
              class="mt-0.5"
            />
            <span>{{ $t('AI_DEPARTMENTS.FORM.SLOT_REQUIRED_NO') }}</span>
          </label>
        </div>
      </template>
    </div>

    <!-- d) Ajustes avançados (recolhidos por padrão) -->
    <div class="rounded-lg border border-n-weak">
      <button
        type="button"
        class="w-full flex items-center justify-between gap-2 px-3 py-2.5 text-sm text-n-slate-12"
        @click="advancedOpen = !advancedOpen"
      >
        <span class="flex items-center gap-1.5">
          <span
            class="i-lucide-chevron-down size-4 transition-transform"
            :class="{ 'rotate-180': advancedOpen }"
          />
          {{ $t('AI_DEPARTMENTS.FORM.ADVANCED_TITLE') }}
        </span>
        <span v-if="!advancedOpen" class="text-xs text-n-slate-11 truncate">
          {{ advancedSummary }}
        </span>
      </button>

      <div
        v-if="advancedOpen"
        class="flex flex-col gap-4 px-3 pb-3 pt-1 border-t border-n-weak"
      >
        <!-- delay -->
        <label class="flex flex-col gap-1 text-sm text-n-slate-12 max-w-xs">
          <span class="flex items-center gap-1.5">
            {{ $t('AI_DEPARTMENTS.FORM.STEP_DELAY') }}
            <span
              class="i-lucide-help-circle size-3.5 text-n-slate-10"
              :title="$t('AI_DEPARTMENTS.FORM.STEP_DELAY_HINT')"
            />
          </span>
          <input
            v-model="draft.group_delay_seconds"
            type="number"
            min="0"
            :placeholder="$t('AI_DEPARTMENTS.FORM.STEP_DELAY_PLACEHOLDER')"
            class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-2"
          />
        </label>

        <!-- Consulta ao conhecimento ANTES de responder. Cronológico: a consulta é ANTES da resposta;
             as automações são DEPOIS de concluir a etapa. Declara step['knowledge'] = { query, kinds }. -->
        <div class="flex flex-col gap-1.5 border-t border-n-weak pt-3">
          <span class="text-sm font-medium text-n-slate-12">
            {{ $t('AI_DEPARTMENTS.FORM.STEP_KNOWLEDGE_LABEL') }}
          </span>
          <span class="text-xs text-n-slate-11">
            {{ $t('AI_DEPARTMENTS.FORM.STEP_KNOWLEDGE_HINT') }}
          </span>
          <textarea
            v-model="draft.knowledgeQuery"
            rows="2"
            :placeholder="
              $t('AI_DEPARTMENTS.FORM.STEP_KNOWLEDGE_QUERY_PLACEHOLDER')
            "
            class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-2 resize-y text-sm"
          />
          <label class="flex flex-col gap-1 text-xs text-n-slate-11">
            {{ $t('AI_DEPARTMENTS.FORM.STEP_KNOWLEDGE_KINDS_LABEL') }}
            <input
              v-model="draft.knowledgeKinds"
              type="text"
              :placeholder="
                $t('AI_DEPARTMENTS.FORM.STEP_KNOWLEDGE_KINDS_PLACEHOLDER')
              "
              class="px-2 py-1 rounded border border-n-weak bg-n-solid-1 text-sm text-n-slate-12"
            />
            <span class="text-n-slate-10">{{
              $t('AI_DEPARTMENTS.FORM.STEP_KNOWLEDGE_KINDS_HINT')
            }}</span>
          </label>
        </div>

        <!-- (a chave do slot + obrigatório/opcional migraram para a tarja verde acima) -->

        <!-- automações ao concluir a etapa -->
        <div class="flex flex-col gap-2 border-t border-n-weak pt-3">
          <span class="text-sm font-medium text-n-slate-12">
            {{ $t('AI_DEPARTMENTS.FORM.AUTOMATIONS_TITLE') }}
          </span>

          <p
            v-if="!draft.automations.length && !draft.onCompleteAction"
            class="text-xs text-n-slate-11 mb-0"
          >
            {{ $t('AI_DEPARTMENTS.FORM.AUTOMATION_EMPTY') }}
          </p>

          <div
            v-for="(automation, automationIndex) in draft.automations"
            :key="automationIndex"
            class="flex flex-col gap-2 rounded-lg border border-n-weak bg-n-solid-2 p-3"
          >
            <div class="flex items-center justify-between gap-2">
              <label class="flex flex-col gap-1 text-xs text-n-slate-11">
                {{ $t('AI_DEPARTMENTS.FORM.AUTOMATION_TYPE') }}
                <Select
                  v-model="automation.type"
                  :options="typeOptions"
                  @update:model-value="onTypeChange(automationIndex)"
                />
              </label>
              <button
                type="button"
                class="shrink-0 text-xs text-n-ruby-11 hover:underline"
                @click="removeAutomation(automationIndex)"
              >
                {{ $t('AI_DEPARTMENTS.FORM.AUTOMATION_REMOVE') }}
              </button>
            </div>

            <!-- tag -->
            <label
              v-if="automation.type === 'tag'"
              class="flex flex-col gap-1 text-xs text-n-slate-11"
            >
              {{ $t('AI_DEPARTMENTS.FORM.AUTOMATION_TAG_LABEL') }}
              <Select
                v-model="automation.params.label"
                :options="labelOptions"
                :placeholder="
                  $t('AI_DEPARTMENTS.FORM.AUTOMATION_TAG_PLACEHOLDER')
                "
              />
            </label>

            <!-- webhook -->
            <template v-else-if="automation.type === 'webhook'">
              <label class="flex flex-col gap-1 text-xs text-n-slate-11">
                {{ $t('AI_DEPARTMENTS.FORM.AUTOMATION_WEBHOOK_URL') }}
                <input
                  v-model="automation.params.url"
                  type="url"
                  :placeholder="
                    $t('AI_DEPARTMENTS.FORM.AUTOMATION_WEBHOOK_URL_PLACEHOLDER')
                  "
                  class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm"
                />
              </label>
              <label class="flex flex-col gap-1 text-xs text-n-slate-11">
                {{ $t('AI_DEPARTMENTS.FORM.AUTOMATION_WEBHOOK_METHOD') }}
                <Select
                  v-model="automation.params.method"
                  :options="methodOptions"
                />
              </label>
              <label class="flex flex-col gap-1 text-xs text-n-slate-11">
                {{ $t('AI_DEPARTMENTS.FORM.AUTOMATION_WEBHOOK_HEADERS') }}
                <textarea
                  v-model="automation.params.headers"
                  rows="2"
                  :placeholder="
                    $t(
                      'AI_DEPARTMENTS.FORM.AUTOMATION_WEBHOOK_HEADERS_PLACEHOLDER'
                    )
                  "
                  class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm resize-y"
                />
              </label>
            </template>

            <!-- change_team: move a fila mas a IA CONTINUA (não é handoff). Distingue do "Encerrar". -->
            <label
              v-else-if="automation.type === 'change_team'"
              class="flex flex-col gap-1 text-xs text-n-slate-11"
            >
              {{ $t('AI_DEPARTMENTS.FORM.AUTOMATION_TEAM') }}
              <Select
                v-model="automation.params.team_id"
                :options="teamOptions"
                :placeholder="
                  $t('AI_DEPARTMENTS.FORM.AUTOMATION_TEAM_PLACEHOLDER')
                "
              />
              <span class="text-n-slate-10">{{
                $t('AI_DEPARTMENTS.FORM.AUTOMATION_CHANGE_TEAM_HINT')
              }}</span>
            </label>

            <!-- change_ai_department -->
            <label
              v-else-if="automation.type === 'change_ai_department'"
              class="flex flex-col gap-1 text-xs text-n-slate-11"
            >
              {{ $t('AI_DEPARTMENTS.FORM.AUTOMATION_DEPARTMENT') }}
              <Select
                v-model="automation.params.department_id"
                :options="departmentOptions"
                :placeholder="
                  $t('AI_DEPARTMENTS.FORM.AUTOMATION_DEPARTMENT_PLACEHOLDER')
                "
              />
            </label>

            <!-- update_attribute -->
            <template v-else-if="automation.type === 'update_attribute'">
              <label class="flex flex-col gap-1 text-xs text-n-slate-11">
                {{ $t('AI_DEPARTMENTS.FORM.AUTOMATION_ATTRIBUTE') }}
                <Select
                  v-model="automation.params.key"
                  :options="attributeOptions"
                  :placeholder="
                    $t('AI_DEPARTMENTS.FORM.AUTOMATION_ATTRIBUTE_PLACEHOLDER')
                  "
                />
              </label>
              <label class="flex flex-col gap-1 text-xs text-n-slate-11">
                {{ $t('AI_DEPARTMENTS.FORM.AUTOMATION_VALUE') }}
                <input
                  v-model="automation.params.value"
                  type="text"
                  :placeholder="
                    $t('AI_DEPARTMENTS.FORM.AUTOMATION_VALUE_PLACEHOLDER')
                  "
                  class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 text-sm"
                />
              </label>
            </template>
          </div>

          <!-- "Encerrar o atendimento" (desfecho, step['on_complete']): item ÚNICO e TERMINAL da lista.
               NÃO entra em draft.automations — fica no estado próprio, emitido em on_complete pelo
               buildStepPayload. -->
          <div
            v-if="draft.onCompleteAction"
            class="flex flex-col gap-2 rounded-lg border border-n-amber-6 bg-n-amber-2 p-3"
          >
            <div class="flex items-center justify-between gap-2">
              <label
                class="flex flex-col gap-1 text-xs text-n-slate-11 flex-1 min-w-0"
              >
                {{ $t('AI_DEPARTMENTS.FORM.STEP_ON_COMPLETE_TITLE') }}
                <Select
                  v-model="draft.onCompleteAction"
                  :options="onCompleteActionOptions"
                />
              </label>
              <button
                type="button"
                class="shrink-0 text-xs text-n-ruby-11 hover:underline"
                @click="removeOnComplete"
              >
                {{ $t('AI_DEPARTMENTS.FORM.AUTOMATION_REMOVE') }}
              </button>
            </div>

            <!-- handoff_human: time da WHITELIST do agente (não todos os times da conta) -->
            <label
              v-if="draft.onCompleteAction === 'handoff_human'"
              class="flex flex-col gap-1 text-xs text-n-slate-11"
            >
              {{ $t('AI_DEPARTMENTS.FORM.STEP_ON_COMPLETE_TEAM') }}
              <Select
                v-if="handoffTeamOptions.length"
                v-model="draft.onCompleteTeamId"
                :options="handoffTeamOptions"
                :placeholder="
                  $t('AI_DEPARTMENTS.FORM.STEP_ON_COMPLETE_TEAM_PLACEHOLDER')
                "
              />
              <span v-else class="text-n-amber-11">
                {{ $t('AI_DEPARTMENTS.FORM.STEP_ON_COMPLETE_TEAM_EMPTY') }}
              </span>
            </label>

            <!-- handoff_ai: IA de destino (handoff_agent_ids), por nome -->
            <label
              v-else-if="draft.onCompleteAction === 'handoff_ai'"
              class="flex flex-col gap-1 text-xs text-n-slate-11"
            >
              {{ $t('AI_DEPARTMENTS.FORM.STEP_ON_COMPLETE_TARGET') }}
              <Select
                v-if="handoffAgentOptions.length"
                v-model="draft.onCompleteTarget"
                :options="handoffAgentOptions"
                :placeholder="
                  $t('AI_DEPARTMENTS.FORM.STEP_ON_COMPLETE_TARGET_PLACEHOLDER')
                "
              />
              <span v-else class="text-n-amber-11">
                {{ $t('AI_DEPARTMENTS.FORM.STEP_ON_COMPLETE_TARGET_EMPTY') }}
              </span>
            </label>

            <!-- aviso terminal (afirmativo: explica o porquê, não lista restrição) -->
            <p class="text-xs text-n-amber-11 mb-0">
              {{ $t('AI_DEPARTMENTS.FORM.STEP_ON_COMPLETE_TERMINAL_WARNING') }}
            </p>
          </div>

          <div class="flex items-center gap-3 flex-wrap">
            <button
              type="button"
              class="inline-flex items-center gap-1 text-sm text-n-brand hover:underline"
              @click="addAutomation"
            >
              <span class="i-lucide-plus size-3.5" />
              {{ $t('AI_DEPARTMENTS.FORM.AUTOMATION_ADD') }}
            </button>
            <button
              v-if="!draft.onCompleteAction"
              type="button"
              class="inline-flex items-center gap-1 text-sm text-n-brand hover:underline"
              @click="addOnComplete"
            >
              <span class="i-lucide-flag size-3.5" />
              {{ $t('AI_DEPARTMENTS.FORM.STEP_ON_COMPLETE_ADD') }}
            </button>
          </div>
        </div>
      </div>
    </div>

    <!-- e) Rodapé -->
    <div class="flex items-center justify-between gap-3 flex-wrap">
      <!-- Microcopy honesta: o Salvar grava a PÁGINA inteira no servidor na hora (não só esta etapa) — o
           rótulo não deve deixar ninguém deduzir um escopo que não existe (a PATCH é do departamento todo). -->
      <span class="text-xs text-n-slate-11">
        {{ $t('AI_DEPARTMENTS.FORM.STEP_SAVE_HINT') }}
      </span>
      <div class="flex items-center gap-2 flex-wrap">
        <button
          type="button"
          class="text-sm px-3 py-2 rounded-lg bg-n-alpha-2 text-n-slate-12"
          @click="emit('cancel')"
        >
          {{ $t('AI_DEPARTMENTS.FORM.CANCEL') }}
        </button>
        <button
          type="button"
          :disabled="!draft.name.trim()"
          class="text-sm font-medium px-3 py-2 rounded-lg bg-n-brand text-white disabled:opacity-50 disabled:cursor-not-allowed"
          @click="onSave"
        >
          {{
            isNew
              ? $t('AI_DEPARTMENTS.FORM.STEP_CREATE')
              : $t('AI_DEPARTMENTS.FORM.SAVE')
          }}
        </button>
      </div>
    </div>

    <AiPromptAssistant
      v-model:open="assistantOpen"
      kind="step_instructions"
      :department-id="departmentId"
    />
  </div>
</template>
