<script setup>
/* global axios */
import { reactive, computed, ref, watch, onBeforeUnmount } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import Select from 'dashboard/components-next/select/Select.vue';
import AiPromptAssistant from './AiPromptAssistant.vue';
import { buildStepPayload, slotAfterFlush } from './aiStepPayload';

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
  departments: { type: Array, default: () => [] },
  // Desfecho (b)-core: times da WHITELIST do agente (handoff_team_ids) e IAs de handoff (handoff_agent_ids),
  // já resolvidos pelo pai. NÃO são todos os times da conta (props.teams) — é a lista que a resolução do
  // backend aceita (é aqui que entra a validação de escrita: fora da whitelist não é selecionável).
  handoffTeams: { type: Array, default: () => [] },
  handoffAgents: { type: Array, default: () => [] },
});
const emit = defineEmits(['save', 'cancel']);
const { t } = useI18n();
const route = useRoute();
const assistantOpen = ref(false);
const advancedOpen = ref(false);

const WEBHOOK_METHODS = ['POST', 'GET', 'PUT', 'PATCH', 'DELETE'];

const draft = reactive({
  name: props.step?.name || '',
  instructions: props.step?.instructions || '',
  group_delay_seconds: props.step?.group_delay_seconds ?? '',
  // Chave do slot: vazia => o backend INFERE da instrução (tarja). Preenchida => declara a chave (collect).
  // Editável na tarja verde (substitui o antigo "Forçar o dado manualmente" de Ajustes avançados).
  collectAttribute: props.step?.collect?.attribute || '',
  collectType: props.step?.collect?.type || 'text',
  collectOptions: Array.isArray(props.step?.collect?.options)
    ? props.step.collect.options.join('\n')
    : '',
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

// --- Tarja do slot: o backend (Ai::StepSlot.infer) detecta a chave na instrução (mesma regex do runtime,
// via endpoint — sem segunda fonte de verdade). Debounce enquanto digita. -----------------------------
const detectedSlot = ref('');
const inferFailed = ref(false);
const inferPending = ref(false);
let inferTimer = null;

// Chama o endpoint; devolve { failed, attribute } SEM mutar estado — o caller decide (typing vs save).
const inferRaw = async instructions => {
  const text = (instructions || '').trim();
  if (!text) return { failed: false, attribute: '' };
  try {
    const { data } = await axios.post(
      `/api/v1/accounts/${route.params.accountId}/ai_steps/infer_slot`,
      { instructions: text },
      { timeout: 4000 }
    );
    return { failed: false, attribute: data?.attribute || '' };
  } catch (error) {
    return { failed: true, attribute: '' };
  }
};

// Enquanto digita: na falha esconde a tarja (não mostrar chave errada durante a edição).
watch(
  () => draft.instructions,
  value => {
    clearTimeout(inferTimer);
    inferPending.value = true;
    inferTimer = setTimeout(async () => {
      const r = await inferRaw(value);
      detectedSlot.value = r.failed ? '' : r.attribute;
      inferFailed.value = r.failed;
      inferPending.value = false;
    }, 500);
  },
  { immediate: true }
);
onBeforeUnmount(() => clearTimeout(inferTimer));

// (a) No SAVE: se há inferência pendente (debounce), roda agora e AGUARDA. Falha/timeout MANTÉM o último
// slot conhecido (slotAfterFlush) — uma falha de rede não pode virar "sem slot" em silêncio.
const flushInference = async () => {
  if (!inferPending.value) return;
  clearTimeout(inferTimer);
  const r = await inferRaw(draft.instructions);
  detectedSlot.value = slotAfterFlush(detectedSlot.value, r);
  inferFailed.value = r.failed;
  inferPending.value = false;
};

const manualSlot = computed(() => (draft.collectAttribute || '').trim());
const hasManualSlot = computed(() => !!manualSlot.value);
// Chave efetiva (manual OU inferida) e se há slot. O toggle e o slot_required dependem disto.
const activeSlot = computed(() => manualSlot.value || detectedSlot.value);
const hasSlot = computed(() => !!activeSlot.value);

// Edição da chave na tarja (substitui "Forçar o dado"). Ao abrir, semeia com a chave efetiva (inferida
// se não houver manual); limpar => volta a inferir (collectAttribute vazio).
const editingKey = ref(false);
const startEditKey = () => {
  if (!draft.collectAttribute) draft.collectAttribute = detectedSlot.value;
  editingKey.value = true;
};
const resetToAuto = () => {
  draft.collectAttribute = '';
  editingKey.value = false;
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
// Desfecho: ação em linguagem de usuário (não chave técnica); '' = etapa não declara desfecho.
const onCompleteActionOptions = computed(() => [
  { value: '', label: t('AI_DEPARTMENTS.FORM.STEP_ON_COMPLETE_NONE') },
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

// Payload montado em aiStepPayload.buildStepPayload: slot_required no nível da etapa (nunca
// collect.required), collect só com a chave manual, sem complete_when. Flush da inferência antes (a).
const onSave = async () => {
  if (!draft.name.trim()) return;
  await flushInference();
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
      slotRequired: draft.slotRequired,
      hasSlot: hasSlot.value,
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

    <!-- c) Tarja do slot: UM container e UM <input> SEMPRE montado. Só a APARÊNCIA muda com hasSlot (cor,
         ícone, texto de ajuda). Antes eram 3 ramos v-if com DOIS <input v-model="draft.collectAttribute">
         (âmbar "sem slot" vs verde "editando"); como hasSlot deriva de collectAttribute, a 1ª letra flipava
         o ramo e o Vue remontava o input, matando o foco. O input agora vive num único v-else, e digitar
         torna hasManualSlot true — continuamos NELE, sem remontar. NÃO toca inferência/slot_required. -->
    <div
      class="flex flex-col gap-2 px-3 py-2.5 rounded-lg"
      :class="{
        'bg-n-teal-3 text-n-teal-11': hasSlot,
        'bg-n-alpha-2 text-n-slate-11': !hasSlot && inferPending,
        'bg-n-amber-3 text-n-amber-11': !hasSlot && !inferPending,
      }"
    >
      <!-- linha da chave: ícone + (leitura da chave DETECTADA ou o input único) + reset -->
      <div class="flex items-center gap-2">
        <span
          class="shrink-0 size-4"
          :class="{
            'i-lucide-check': hasSlot,
            'i-lucide-loader-2 animate-spin': !hasSlot && inferPending,
            'i-lucide-alert-triangle': !hasSlot && !inferPending,
          }"
        />
        <!-- slot DETECTADO (inferido), sem override manual e sem editar: leitura + "editar" -->
        <template v-if="hasSlot && !editingKey && !hasManualSlot">
          <span class="flex-1 min-w-0 text-sm">
            {{ $t('AI_DEPARTMENTS.FORM.SLOT_DETECTED', { slot: activeSlot }) }}
          </span>
          <button
            type="button"
            class="shrink-0 inline-flex items-center gap-1 text-xs underline hover:no-underline"
            @click="startEditKey"
          >
            <span class="i-lucide-pencil size-3.5" />
            {{ $t('AI_DEPARTMENTS.FORM.SLOT_EDIT_KEY') }}
          </button>
        </template>
        <!-- INPUT ÚNICO — TODOS os outros casos (sem slot / editando / manual já digitado). Digitar a 1ª
             letra torna hasManualSlot true, então permanecemos NESTE mesmo v-else: o elemento não remonta. -->
        <input
          v-else
          v-model="draft.collectAttribute"
          type="text"
          data-testid="slot-key-input"
          :placeholder="
            $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_ATTRIBUTE_PLACEHOLDER')
          "
          class="flex-1 min-w-0 px-2 py-1 rounded border border-n-weak bg-n-solid-1 text-sm text-n-slate-12"
        />
        <button
          v-if="hasManualSlot || editingKey"
          type="button"
          class="shrink-0 text-xs underline hover:no-underline"
          @click="resetToAuto"
        >
          {{ $t('AI_DEPARTMENTS.FORM.SLOT_MANUAL_RESET') }}
        </button>
      </div>

      <!-- texto de ajuda: detectando / aviso de "sem slot". Só o texto muda; o input acima permanece. -->
      <span v-if="!hasSlot && inferPending" class="text-xs">
        {{ $t('AI_DEPARTMENTS.FORM.SLOT_DETECTING') }}
      </span>
      <span v-else-if="!hasSlot" class="text-xs">
        {{ $t('AI_DEPARTMENTS.FORM.SLOT_NONE_WARNING') }}
      </span>

      <!-- tipo + opções: só ao editar uma chave MANUAL (comportamento inalterado) -->
      <template v-if="editingKey && hasManualSlot">
        <label class="flex flex-col gap-1 text-xs">
          {{ $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_TYPE') }}
          <Select v-model="draft.collectType" :options="slotTypeOptions" />
        </label>
        <label
          v-if="draft.collectType === 'choice'"
          class="flex flex-col gap-1 text-xs"
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
      </template>

      <!-- obrigatório / opcional: só quando HÁ slot. Aparece ao digitar a 1ª letra — é sibling ABAIXO do
           input, não o remonta. -->
      <div
        v-if="hasSlot"
        class="flex flex-col gap-1 pt-1.5 border-t border-n-teal-5"
      >
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
            v-if="!draft.automations.length"
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

            <!-- change_team -->
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

          <button
            type="button"
            class="self-start inline-flex items-center gap-1 text-sm text-n-brand hover:underline"
            @click="addAutomation"
          >
            <span class="i-lucide-plus size-3.5" />
            {{ $t('AI_DEPARTMENTS.FORM.AUTOMATION_ADD') }}
          </button>
        </div>

        <!-- Desfecho AO concluir o funil (step['on_complete'], (b)-core). Cronológico: depois das automações
             da etapa. Vazio = a etapa não declara desfecho. -->
        <div class="flex flex-col gap-2 border-t border-n-weak pt-3">
          <span class="text-sm font-medium text-n-slate-12">
            {{ $t('AI_DEPARTMENTS.FORM.STEP_ON_COMPLETE_TITLE') }}
          </span>
          <span class="text-xs text-n-slate-11">
            {{ $t('AI_DEPARTMENTS.FORM.STEP_ON_COMPLETE_HINT') }}
          </span>
          <Select
            v-model="draft.onCompleteAction"
            :options="onCompleteActionOptions"
          />

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
        </div>
      </div>
    </div>

    <!-- e) Rodapé -->
    <div class="flex items-center justify-end gap-2 flex-wrap">
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

    <AiPromptAssistant v-model:open="assistantOpen" kind="step_instructions" />
  </div>
</template>
