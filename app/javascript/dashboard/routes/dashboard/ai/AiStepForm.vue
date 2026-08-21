<script setup>
/* global axios */
import { reactive, computed, ref, watch } from 'vue';
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
  // Variáveis INTERNAS do agente (Ai::LeadVariable). Fonte do Select da chave junto com customAttributes;
  // o inline-create grava aqui (não em CustomAttributeDefinition).
  leadVariables: { type: Array, default: () => [] },
  // (B2) Ferramentas do agente (Ai::Tool), carregadas pelo pai. Fonte do Select "opções vêm de: ferramenta"
  // num slot choice. Usadas só pelo NOME (domain_from_tool guarda o nome). Vazio => o modo ferramenta avisa.
  tools: { type: Array, default: () => [] },
  // Contexto para o POST do inline-create de LeadVariable (nested em ai_agents).
  agentId: { type: [String, Number], default: null },
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

// ==== "DADOS PARA COLETA NA ETAPA" — um item por dado, cada um com type/options/required/hint próprios
// (Ai::StepSlot.items no backend). uid é CLIENT-ONLY (v-for), nunca vai ao backend. ====
let collectItemUid = 0;
const nextCollectItemUid = () => {
  collectItemUid += 1;
  return collectItemUid;
};

// Formato ANTIGO (1 collect pra etapa inteira; attribute string OU array — ticket 586): todos os
// atributos COMPARTILHAVAM o mesmo type/options/domain_from_tool, e o required seguia a precedência do
// backend (Gap 2: collect.required explícito > step.slot_required > obrigatório por default). Replicada
// aqui só pra abrir uma etapa antiga com os valores certos — o PRÓXIMO save já grava items[], migrando
// a etapa sem exigir migração de banco nenhuma (Ai::StepSlot lê os dois formatos).
const legacyCollectAsRawItems = (collect, step) => {
  const attrs = Array.isArray(collect.attribute)
    ? collect.attribute
    : [collect.attribute].filter(Boolean);
  const required = collect.required ?? step?.slot_required ?? true;
  return attrs
    .map(a => (a || '').toString().trim())
    .filter(Boolean)
    .map(attribute => ({
      attribute,
      type: collect.type,
      options: collect.options,
      domain_from_tool: collect.domain_from_tool,
      required,
    }));
};

// Retorna as opções de um CAD como array de strings, ou [] quando não há valores.
const cadOptionsFor = key => {
  if (!key) return [];
  const cad = (props.customAttributes || []).find(a => a.attribute_key === key);
  if (!cad) return [];
  return Array.isArray(cad.attribute_values)
    ? cad.attribute_values.filter(Boolean)
    : [];
};

// O CAD (qualquer tipo) que um atributo coletado referencia, ou null (LeadVariable interna — aí sim o
// tipo/opções ficam livres pro usuário decidir, não há definição real pra espelhar).
const cadFor = key => {
  if (!key) return null;
  return (
    (props.customAttributes || []).find(a => a.attribute_key === key) || null
  );
};

// Achado ao vivo (18/08, ampliado): o pedido original travava só CAD tipo "lista" — mas um CAD tipo
// "link" (ex.: chave_1_2_3_) deixava a etapa oferecer "Escolha (opções)" com valores digitados à mão
// (ex.: "coisa 1/coisa2/coisa3") sem relação NENHUMA com o atributo real. Qualquer CAD (lista, texto,
// número, link, etc.) tem um tipo definido em Configurações → Atributos personalizados — um item da
// etapa não deveria poder divergir disso pra NENHUM tipo, não só lista. O mapeamento abaixo decide
// qual "Tipo do dado" da etapa corresponde a cada attribute_display_type do CAD.
const CAD_TYPE_TO_STEP_TYPE = {
  text: 'text',
  number: 'number',
  currency: 'number',
  percent: 'number',
  link: 'text',
  date: 'text',
  checkbox: 'text',
  list: 'choice',
};

// Espelha type/options do CAD quando o atributo referencia um — TANTO ao seedar do banco quanto ao
// adicionar um item novo (ver #newItemFromAttribute), porque o campo fica TRAVADO na tela: o usuário
// não tem como corrigir manualmente um valor desatualizado, então o que é exibido tem que ser SEMPRE
// o que o CAD diz agora, nunca o que ficou gravado no step em algum save anterior.
const mirrorCadOnto = item => {
  const cad = cadFor(item.attribute);
  if (!cad) return item;
  item.type = CAD_TYPE_TO_STEP_TYPE[cad.attribute_display_type] || 'text';
  if (item.type === 'choice') {
    item.source = 'fixed';
    item.options = cadOptionsFor(item.attribute).join('\n');
  }
  return item;
};

const rawItemToDraft = raw =>
  mirrorCadOnto({
    uid: nextCollectItemUid(),
    attribute: raw.attribute || '',
    type: raw.type || 'text',
    options: Array.isArray(raw.options) ? raw.options.join('\n') : '',
    source: raw.domain_from_tool ? 'tool' : 'fixed',
    domainTool: raw.domain_from_tool || '',
    required: raw.required ?? true,
    hint: raw.hint || '',
    // Carregado do banco = já configurado -> começa RECOLHIDO (senão toda etapa com 3 dados abriria
    // com 3 cards abertos, ilegível). Só nasce expandido quando ADICIONADO nesta sessão de edição.
    expanded: false,
  });

const seedCollectItems = (collect, step) => {
  if (!collect) return [];
  const rawItems = Array.isArray(collect.items)
    ? collect.items
    : legacyCollectAsRawItems(collect, step);
  return rawItems.map(rawItemToDraft);
};

const draft = reactive({
  name: props.step?.name || '',
  // "Padrão ouro": 2 campos separados em vez de 1 textarea (Objetivo/Regras) — melhora a
  // atenção do modelo (texto estruturado > prosa longa). Migração: etapa ANTIGA (só instructions, sem
  // objective) semeia objective com o texto legado — nada se perde, o admin edita/divide dali.
  // Tom/abordagem de fala NÃO é campo de etapa (removido — "Fala sugerida" dava a impressão de roteiro
  // fixo pro modelo mesmo com ressalva de exemplo); tom consistente vai no "Prompt base" do agente.
  objective: props.step?.objective || props.step?.instructions || '',
  // rulesText é o textarea cru (uma regra por linha); buildStepPayload divide em array no save.
  rulesText: Array.isArray(props.step?.rules)
    ? props.step.rules.join('\n')
    : props.step?.rules || '',
  group_delay_seconds: props.step?.group_delay_seconds ?? '',
  // "DADOS PARA COLETA NA ETAPA": um item por dado (Ai::StepSlot.items no backend), cada um com SEU
  // PRÓPRIO type/options/required/hint — CPF obrigatório e e-mail opcional na MESMA etapa, cada um
  // validado com o formato certo. Seedado de step.collect.items[] (formato novo) OU do step.collect
  // ANTIGO (1 collect pra etapa inteira, attribute string ou array — ticket 586), tratado como items de
  // 1+ elemento — ver #seedCollectItems. [] => etapa informativa (nenhum dado configurado ainda).
  collectItems: seedCollectItems(props.step?.collect, props.step),
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

// --- "+ Selecionar dado do sistema para coletar...": união LeadVariable ∪ CustomAttributeDefinition,
// filtrada pro que AINDA NÃO foi adicionado nesta etapa (evita coletar o mesmo dado duas vezes). Ao
// contrário do Select antigo (uma escolha SUBSTITUÍA a anterior), aqui escolher AGREGA um item novo —
// não existe mais "a" chave da etapa, existem VÁRIAS, cada uma seu próprio card. -----------------------
const usedAttributes = computed(
  () => new Set(draft.collectItems.map(i => i.attribute).filter(Boolean))
);

// O CAD tipo "lista" especificamente — só esse tem attribute_values pra mirar em "Opções".
const cadListFor = key => {
  const cad = cadFor(key);
  return cad && cad.attribute_display_type === 'list' ? cad : null;
};

// Por item (não mais um único slotLocked global — cada item da etapa tem SEU PRÓPRIO atributo, e só
// espelha um CAD quando O DELE for um).
const isItemLocked = item => !!cadFor(item.attribute);

const addExistingKey = ref('');
const addExistingOptions = computed(() =>
  buildSlotKeyOptions(props.leadVariables, props.customAttributes)
    .filter(o => !usedAttributes.value.has(o.value))
    .map(o => ({
      value: o.value,
      label:
        o.source === 'panel'
          ? t('AI_DEPARTMENTS.FORM.SLOT_KEY_PANEL', { key: o.value })
          : t('AI_DEPARTMENTS.FORM.SLOT_KEY_INTERNAL', { key: o.value }),
    }))
);

// Origem (system = CustomAttributeDefinition, aparece no painel · memory = LeadVariable, interna) pro
// badge do card — mesma fonte que addExistingOptions, mas por atributo já ADICIONADO.
const originOf = attribute =>
  (props.customAttributes || []).some(a => a.attribute_key === attribute)
    ? 'system'
    : 'memory';

// Ao adicionar um dado que já é um CustomAttributeDefinition (qualquer tipo — achado ao vivo 18/08,
// ampliado: travar só CAD tipo "lista" deixava um CAD tipo "link"/"número"/etc. oferecer um "Tipo do
// dado" divergente do que já está definido em Configurações → Atributos personalizados): auto-preenche
// o type espelhando o CAD (e as opções, quando for lista) — mesmo atalho que existia antes como watch
// contínuo; agora roda UMA vez, no momento de adicionar (com vários itens, reagir a "qual mudou" não
// faz mais sentido como watch global). LeadVariable interna (sem CAD) mantém o comportamento livre.
const newItemFromAttribute = attribute =>
  mirrorCadOnto({
    uid: nextCollectItemUid(),
    attribute,
    type: 'text',
    options: '',
    source: 'fixed',
    domainTool: '',
    required: true,
    hint: '',
    expanded: true, // recém-adicionado -> abre pra configurar tipo/obrigatório/dica na hora
  });

watch(addExistingKey, key => {
  if (!key) return;
  draft.collectItems.push(newItemFromAttribute(key));
  addExistingKey.value = ''; // reseta o combo — cada escolha é uma AGREGAÇÃO, não uma seleção persistente
});

const removeItem = uid => {
  draft.collectItems = draft.collectItems.filter(i => i.uid !== uid);
};

// Fallback: ao mudar manualmente o tipo de um item pra "choice", preenche as opções do CAD se ainda
// estiverem vazias (cobre o CAD que não é tipo "lista" no sistema, mas tem valores possíveis mesmo assim).
const onItemTypeChange = item => {
  if (item.type !== 'choice') return;
  if ((item.options || '').trim()) return;
  const values = cadOptionsFor(item.attribute);
  if (!values.length) return;
  item.source = 'fixed';
  item.options = values.join('\n');
};

// Inline-create: cria uma Ai::LeadVariable (variável INTERNA), NÃO um CustomAttributeDefinition — dado da
// IA é memória de trabalho, não campo editável na lateral. O pai empilha o resultado em leadVariables (para
// a opção aparecer no Select) e aqui já a adicionamos como item, expandida pra configurar tipo/obrigatório.
const creatingVariable = ref(false);
const newVariableName = ref('');
const createError = ref('');
const createVariable = async () => {
  const name = newVariableName.value.trim();
  if (!name) return;
  createError.value = '';
  try {
    const { data } = await axios.post(
      `/api/v1/accounts/${route.params.accountId}/ai_agents/${props.agentId}/ai_lead_variables`,
      { ai_lead_variable: { name } }
    );
    emit('variableCreated', data); // pai empilha em leadVariables => a opção aparece
    draft.collectItems.push(newItemFromAttribute(data.name)); // adiciona como item, já expandida
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
      `/api/v1/accounts/${route.params.accountId}/ai_agents/${props.agentId}/ai_lead_variables/${v.id}`
    );
    // era usada por algum item desta etapa -> remove (a variável em si já sumiu do backend; deixar o
    // item pendurado gravaria uma chave órfã no próximo save).
    draft.collectItems = draft.collectItems.filter(i => i.attribute !== v.name);
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

// (B2) Ferramentas do agente como opções do Select "opções vêm de: ferramenta". O value é o NOME (é o que
// domain_from_tool grava e o backend resolve). Placeholder vazio quando o agente não tem ferramenta.
const toolOptions = computed(() =>
  (props.tools || [])
    .map(tl => (tl?.name || '').trim())
    .filter(Boolean)
    .map(name => ({ value: name, label: name }))
);

// Aviso anti-degradação-silenciosa: um item está em modo ferramenta e o NOME salvo não existe (mais) na
// lista do agente (ferramenta removida/renomeada). O runtime já faz fail-open + emite
// tool_domain.unextractable, mas quem edita a etapa precisa VER que o slot voltou a aceitar qualquer
// valor. Função (não computed) — agora é POR ITEM, chamada no v-for.
const isToolDomainMissing = item => {
  if (item.source !== 'tool') return false;
  const chosen = (item.domainTool || '').trim();
  if (!chosen) return false;
  return !toolOptions.value.some(o => o.value === chosen);
};

// Rótulo do "Tipo do dado" pro badge do card recolhido (reaproveita slotTypeOptions — mesma fonte que o
// Select de edição usa, então o rótulo nunca diverge entre os dois estados do card).
const typeLabel = type =>
  slotTypeOptions.value.find(o => o.value === type)?.label || type;

// Resumo "N campos configurados" no cabeçalho da seção (mesmo padrão de advancedSummary acima).
const collectCountLabel = computed(() => {
  const n = draft.collectItems.length;
  if (n === 0) return t('AI_DEPARTMENTS.FORM.COLLECT_SECTION_COUNT_NONE');
  if (n === 1) return t('AI_DEPARTMENTS.FORM.COLLECT_SECTION_COUNT_ONE');
  return t('AI_DEPARTMENTS.FORM.COLLECT_SECTION_COUNT_MANY', { count: n });
});

const typeOptions = computed(() => [
  { value: 'tag', label: t('AI_DEPARTMENTS.FORM.AUTOMATION_TYPE_TAG') },
  { value: 'webhook', label: t('AI_DEPARTMENTS.FORM.AUTOMATION_TYPE_WEBHOOK') },
  {
    value: 'change_team',
    label: t('AI_DEPARTMENTS.FORM.AUTOMATION_TYPE_CHANGE_TEAM'),
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

// Nome é o único campo que bloqueia o Salvar (:disabled do botão, no rodapé) — mas até aqui nada no
// campo em si avisava disso, só o guard genérico de "você vai perder o progresso" ao tentar sair.
// nameTouched marca "o usuário já teve chance de perceber que o nome está vazio" (blur do campo OU
// tentativa de passar o mouse/focar o botão Salvar desabilitado) para então destacar o campo — não
// mostra erro de cara num rascunho novo que ainda nem foi tocado.
const nameTouched = ref(false);
const nameError = computed(() => nameTouched.value && !draft.name.trim());

// Payload montado em aiStepPayload.buildStepPayload: um item de collect.items[] por dado declarado
// (nunca mais 1 collect pra etapa inteira), sem complete_when. Sem flush de inferência — a etapa
// declara as variáveis, não há estado assíncrono no save em si (o inline-create já resolveu antes).
const onSave = () => {
  if (!draft.name.trim()) {
    nameTouched.value = true;
    return;
  }
  emit(
    'save',
    buildStepPayload({
      name: draft.name,
      objective: draft.objective,
      rules: draft.rulesText,
      groupDelaySeconds: draft.group_delay_seconds,
      automations: draft.automations,
      collectItems: draft.collectItems.map(i => ({
        attribute: i.attribute,
        type: i.type,
        options: i.options,
        source: i.source,
        domainTool: i.domainTool,
        required: i.required,
        hint: i.hint,
      })),
      onCompleteAction: draft.onCompleteAction,
      onCompleteTeamId: draft.onCompleteTeamId,
      onCompleteTarget: draft.onCompleteTarget,
    })
  );
};

// Aplica a sugestão do assistente (✨) nos 2 campos — o admin ainda revisa/edita antes de salvar a
// etapa (o "Salvar" continua sendo o único gesto que persiste). Não fecha campos existentes: SOBRESCREVE
// (o usuário abriu o assistente para gerar; se já tinha texto, o preview do assistente já deixou claro
// o que vai entrar).
const applyAssistantSuggestion = ({ objective, rules }) => {
  draft.objective = objective || '';
  draft.rulesText = Array.isArray(rules) ? rules.join('\n') : rules || '';
};
</script>

<template>
  <div class="flex flex-col gap-4">
    <!-- a) Cabeçalho: badge da etapa + nome como TÍTULO do card -->
    <div class="flex flex-col gap-1">
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
          class="flex-1 min-w-0 px-2 py-1 text-base font-medium text-n-slate-12 bg-transparent border-0 border-b focus:outline-none"
          :class="
            nameError
              ? 'border-n-ruby-9 focus:border-n-ruby-9'
              : 'border-transparent hover:border-n-weak focus:border-n-brand'
          "
          @blur="nameTouched = true"
        />
      </div>
      <span v-if="nameError" class="text-xs text-n-ruby-11">
        {{ $t('AI_DEPARTMENTS.FORM.STEP_NAME_REQUIRED') }}
      </span>
    </div>

    <!-- b) Instrução da etapa: 3 campos estruturados (Objetivo/Regras/Fala sugerida) em vez de 1
         textarea — texto estruturado segura melhor a atenção do modelo do que prosa longa. -->
    <div class="flex flex-col gap-3">
      <div class="flex justify-end -mb-1">
        <button
          type="button"
          class="i-lucide-sparkles size-4 text-n-slate-10 hover:text-n-brand"
          :title="$t('AI_AGENTS.PROMPT_ASSISTANT.OPEN')"
          @click="assistantOpen = true"
        />
      </div>

      <!-- Objetivo -->
      <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
        <span class="flex items-center gap-2">
          <span class="font-medium">
            {{ $t('AI_DEPARTMENTS.FORM.STEP_OBJECTIVE_LABEL') }}
          </span>
          <span class="text-xs text-n-slate-11">
            {{ $t('AI_DEPARTMENTS.FORM.STEP_OBJECTIVE_MICROHINT') }}
          </span>
        </span>
        <textarea
          v-model="draft.objective"
          rows="2"
          data-testid="step-objective"
          :placeholder="$t('AI_DEPARTMENTS.FORM.STEP_OBJECTIVE_PLACEHOLDER')"
          class="px-3 py-2.5 rounded-lg border border-n-weak bg-n-solid-2 resize-y leading-relaxed"
        />
      </label>

      <!-- Regras -->
      <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
        <span class="font-medium">
          {{ $t('AI_DEPARTMENTS.FORM.STEP_RULES_LABEL') }}
        </span>
        <textarea
          v-model="draft.rulesText"
          data-testid="step-rules"
          :placeholder="$t('AI_DEPARTMENTS.FORM.STEP_RULES_PLACEHOLDER')"
          class="px-3 py-2.5 rounded-lg border border-n-weak bg-n-solid-2 resize-y min-h-[110px] leading-relaxed"
        />
      </label>
    </div>

    <!-- c) DADOS PARA COLETA NA ETAPA: um card por dado (Ai::StepSlot.items no backend), cada um com
         SEU PRÓPRIO type/options/required/hint — CPF obrigatório e e-mail opcional na MESMA etapa,
         cada um validado com o formato certo. "+ Selecionar..." AGREGA um dado já cadastrado
         (LeadVariable ∪ CustomAttributeDefinition, origem marcada); "+ Adicionar variável
         personalizada" cria uma nova (LeadVariable interna) e já a adiciona como item. Lista vazia =
         etapa informativa (escolha implícita — não existe mais um "modo etapa informativa" à parte). -->
    <div class="flex flex-col gap-3">
      <div class="flex items-center justify-between gap-2">
        <span class="text-sm font-medium text-n-slate-12">
          {{ $t('AI_DEPARTMENTS.FORM.COLLECT_SECTION_TITLE') }}
        </span>
        <span class="text-xs text-n-slate-11">{{ collectCountLabel }}</span>
      </div>

      <ComboBox
        v-model="addExistingKey"
        :options="addExistingOptions"
        :placeholder="$t('AI_DEPARTMENTS.FORM.COLLECT_ADD_EXISTING_SEARCH')"
        :search-placeholder="$t('AI_DEPARTMENTS.FORM.SLOT_KEY_SEARCH')"
        data-testid="collect-add-existing"
      />

      <button
        v-if="!creatingVariable"
        type="button"
        class="text-left text-sm px-3 py-2 rounded-lg border border-dashed border-n-weak text-n-slate-11 hover:text-n-slate-12 hover:border-n-slate-8"
        data-testid="collect-add-custom"
        @click="creatingVariable = true"
      >
        {{ $t('AI_DEPARTMENTS.FORM.COLLECT_ADD_CUSTOM') }}
      </button>

      <!-- inline-create: cria uma variável INTERNA (Ai::LeadVariable); ao criar, já vira um item (ver
           #createVariable) — não é mais um Select a preencher depois. -->
      <div
        v-else
        class="flex flex-col gap-2 px-3 py-2.5 rounded-lg bg-n-alpha-2 text-n-slate-11"
      >
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
            data-testid="collect-cancel-create"
            @click="cancelCreate"
          >
            {{ $t('AI_DEPARTMENTS.FORM.CANCEL') }}
          </button>
        </div>
        <!-- preview da normalização — o usuário vê a chave que vai nascer, sem surpresa -->
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

        <!-- gerenciar/excluir variáveis internas existentes. O backend BLOQUEIA se estiver em uso. -->
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
      </div>

      <!-- confirmação de etapa informativa (empty): afirmativo, NÃO erro. -->
      <p v-if="!draft.collectItems.length" class="text-xs text-n-slate-11 mb-0">
        {{ $t('AI_DEPARTMENTS.FORM.COLLECT_EMPTY') }}
      </p>

      <!-- um card por dado configurado -->
      <div
        v-for="item in draft.collectItems"
        :key="item.uid"
        class="flex flex-col gap-2 px-3 py-2.5 rounded-lg bg-n-teal-3 text-n-teal-11"
      >
        <!-- cabeçalho: sempre visível, colapsado ou expandido -->
        <div class="flex items-start justify-between gap-2">
          <div class="flex flex-col gap-0.5 min-w-0">
            <span class="font-mono text-xs truncate">{{ item.attribute }}</span>
            <span class="text-xs text-n-slate-11">
              {{ typeLabel(item.type) }} ·
              {{
                originOf(item.attribute) === 'system'
                  ? $t('AI_DEPARTMENTS.FORM.COLLECT_ITEM_ORIGIN_SYSTEM')
                  : $t('AI_DEPARTMENTS.FORM.COLLECT_ITEM_ORIGIN_MEMORY')
              }}
              ·
              {{
                item.required
                  ? $t('AI_DEPARTMENTS.FORM.COLLECT_ITEM_REQUIRED_BADGE')
                  : $t('AI_DEPARTMENTS.FORM.COLLECT_ITEM_OPTIONAL_BADGE')
              }}
            </span>
            <span
              v-if="item.hint"
              class="text-xs text-n-slate-11 flex items-center gap-1"
            >
              <span class="i-lucide-info size-3 shrink-0" />
              {{ item.hint }}
            </span>
          </div>
          <div class="flex items-center gap-2 shrink-0">
            <button
              type="button"
              class="i-lucide-pencil size-3.5 text-n-slate-10 hover:text-n-slate-12"
              :data-testid="`collect-item-edit-${item.attribute}`"
              :title="$t('AI_DEPARTMENTS.FORM.COLLECT_ITEM_EDIT')"
              @click="item.expanded = !item.expanded"
            />
            <button
              type="button"
              class="i-lucide-trash-2 size-3.5 text-n-ruby-11 hover:opacity-70"
              :data-testid="`collect-item-remove-${item.attribute}`"
              :title="$t('AI_DEPARTMENTS.FORM.COLLECT_ITEM_REMOVE')"
              @click="removeItem(item.uid)"
            />
          </div>
        </div>

        <!-- expandido: tipo + opções + dica + obrigatório -->
        <template v-if="item.expanded">
          <label class="flex flex-col gap-1 text-xs">
            {{ $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_TYPE') }}
            <Select
              v-model="item.type"
              :options="slotTypeOptions"
              :disabled="isItemLocked(item)"
              :data-testid="`collect-item-type-${item.attribute}`"
              @update:model-value="onItemTypeChange(item)"
            />
          </label>

          <!-- Travado: o dado coletado É um atributo personalizado (CAD, qualquer tipo — achado ao
               vivo 18/08, ampliado) — tipo e opções têm que ser SEMPRE espelho do atributo, sem editar
               por aqui. Nem mostra o escolhe-a-fonte (fixa/ferramenta): travado, a fonte É o
               atributo, sempre. -->
          <p
            v-if="isItemLocked(item)"
            class="text-xs text-n-slate-11 flex items-start gap-1"
          >
            <span class="i-lucide-lock size-3.5 shrink-0 mt-0.5" />
            {{ $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_LOCKED_HINT') }}
          </p>
          <label
            v-if="isItemLocked(item) && cadListFor(item.attribute)"
            class="flex flex-col gap-1 text-xs"
          >
            {{ $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_OPTIONS') }}
            <textarea
              :value="item.options"
              rows="2"
              disabled
              :data-testid="`collect-item-options-locked-${item.attribute}`"
              class="px-2 py-1 rounded border border-n-weak bg-n-slate-2 text-n-slate-11 resize-y cursor-not-allowed"
            />
          </label>

          <!-- choice (não travado): as opções vêm de uma LISTA FIXA ou do RESULTADO de uma FERRAMENTA
               (domínio dinâmico). Um modo por vez, POR ITEM — cada dado choice desta etapa escolhe a
               sua fonte. -->
          <div
            v-else-if="!isItemLocked(item) && item.type === 'choice'"
            class="flex flex-col gap-2 text-xs"
          >
            <span class="text-n-slate-11">
              {{ $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_OPTIONS_SOURCE') }}
            </span>
            <div class="flex flex-col gap-1">
              <label class="flex items-start gap-2 text-sm cursor-pointer">
                <input
                  v-model="item.source"
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
                  v-model="item.source"
                  type="radio"
                  value="tool"
                  class="mt-0.5"
                />
                <span>{{
                  $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_OPTIONS_SOURCE_TOOL')
                }}</span>
              </label>
            </div>

            <label v-if="item.source !== 'tool'" class="flex flex-col gap-1">
              {{ $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_OPTIONS') }}
              <textarea
                v-model="item.options"
                rows="2"
                :placeholder="
                  $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_OPTIONS_PLACEHOLDER')
                "
                :data-testid="`collect-item-options-free-${item.attribute}`"
                class="px-2 py-1 rounded border border-n-weak bg-n-solid-1 resize-y"
              />
            </label>

            <template v-else>
              <label class="flex flex-col gap-1">
                {{ $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_TOOL') }}
                <Select
                  v-if="toolOptions.length"
                  v-model="item.domainTool"
                  :options="toolOptions"
                />
                <span v-else class="text-n-slate-11">
                  {{ $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_TOOL_EMPTY') }}
                </span>
              </label>
              <p class="text-n-slate-10">
                {{ $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_TOOL_HINT') }}
              </p>
              <p
                v-if="isToolDomainMissing(item)"
                data-testid="tool-domain-missing"
                class="flex items-start gap-1.5 text-n-ruby-11"
              >
                <span
                  class="i-lucide-alert-triangle size-3.5 mt-0.5 shrink-0"
                />
                <span>{{
                  $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_TOOL_MISSING', {
                    tool: item.domainTool,
                  })
                }}</span>
              </p>
            </template>
          </div>

          <label class="flex flex-col gap-1 text-xs">
            {{ $t('AI_DEPARTMENTS.FORM.COLLECT_ITEM_HINT_LABEL') }}
            <input
              v-model="item.hint"
              type="text"
              :placeholder="
                $t('AI_DEPARTMENTS.FORM.COLLECT_ITEM_HINT_PLACEHOLDER')
              "
              class="px-2 py-1 rounded border border-n-weak bg-n-solid-1 text-sm"
            />
          </label>

          <label
            class="flex items-center gap-2 text-sm cursor-pointer pt-1.5 border-t border-n-teal-5"
          >
            <input v-model="item.required" type="checkbox" />
            <span>{{ $t('AI_DEPARTMENTS.FORM.COLLECT_ITEM_REQUIRED') }}</span>
          </label>

          <button
            type="button"
            class="self-start text-xs font-medium underline hover:no-underline"
            @click="item.expanded = false"
          >
            {{ $t('AI_DEPARTMENTS.FORM.COLLECT_ITEM_SAVE_MINIMIZE') }}
          </button>
        </template>
      </div>
    </div>

    <!-- d) Ajustes avançados (recolhidos por padrão) -->
    <div class="rounded-lg border border-n-weak">
      <button
        type="button"
        class="w-full flex items-center justify-between gap-2 px-3 py-2.5 text-sm text-n-slate-12"
        @click="advancedOpen = !advancedOpen"
      >
        <span class="flex items-center gap-1.5 font-medium">
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

        <!-- (a chave do slot + obrigatório/opcional migraram para a tarja verde acima; a consulta ao
             conhecimento agora é uma tool agentic — consultar_conhecimento, sempre disponível, a IA
             decide quando chamar — não precisa mais de configuração por etapa aqui) -->

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
        <!-- Wrapper (não o <button> em si): um <button disabled> não dispara mouseenter/title de forma
             confiável no Chrome (elementos desabilitados não recebem eventos de mouse) — o span por
             fora sempre recebe o hover, então é ele quem revela a dica e acende o campo do nome. -->
        <span
          :title="
            !draft.name.trim()
              ? $t('AI_DEPARTMENTS.FORM.STEP_NAME_REQUIRED')
              : null
          "
          @mouseenter="nameTouched = true"
        >
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
        </span>
      </div>
    </div>

    <AiPromptAssistant
      v-model:open="assistantOpen"
      kind="step_instructions"
      :agent-id="agentId"
      @apply="applyAssistantSuggestion"
    />
  </div>
</template>
