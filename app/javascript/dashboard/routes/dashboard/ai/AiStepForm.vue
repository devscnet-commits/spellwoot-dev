<script setup>
/* global axios */
import { reactive, computed, ref, watch, onBeforeUnmount } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import Select from 'dashboard/components-next/select/Select.vue';
import AiPromptAssistant from './AiPromptAssistant.vue';

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
  // Override MANUAL do slot (collect): quando vazio, o sistema INFERE o slot da instrução (faixa de
  // feedback). Preenchido = declara a chave explicitamente.
  collectAttribute: props.step?.collect?.attribute || '',
  collectType: props.step?.collect?.type || 'text',
  collectRequired: props.step?.collect?.required ?? true,
  collectOptions: Array.isArray(props.step?.collect?.options)
    ? props.step.collect.options.join('\n')
    : '',
  // automation_on_complete (booleano) é legado/ignorado; agora usamos automations: [{type, params}].
  automations: (Array.isArray(props.step?.automations)
    ? props.step.automations
    : []
  ).map(a => ({
    type: a?.type || 'tag',
    params: { ...(a?.params || {}) },
  })),
});

// --- Faixa de feedback do slot: o que o backend (Ai::StepSlot.infer) detecta na instrução ---------
// Não duplica a regex no front: chama o endpoint com debounce enquanto o usuário digita.
const detectedSlot = ref('');
const inferFailed = ref(false);
let inferTimer = null;

const inferSlot = async instructions => {
  const text = (instructions || '').trim();
  if (!text) {
    detectedSlot.value = '';
    inferFailed.value = false;
    return;
  }
  try {
    const { data } = await axios.post(
      `/api/v1/accounts/${route.params.accountId}/ai_steps/infer_slot`,
      { instructions: text }
    );
    detectedSlot.value = data?.attribute || '';
    inferFailed.value = false;
  } catch (error) {
    // Falha na detecção: esconder a faixa (não mostrar informação errada).
    detectedSlot.value = '';
    inferFailed.value = true;
  }
};

watch(
  () => draft.instructions,
  value => {
    clearTimeout(inferTimer);
    inferTimer = setTimeout(() => inferSlot(value), 500);
  },
  { immediate: true }
);
onBeforeUnmount(() => clearTimeout(inferTimer));

const manualSlot = computed(() => (draft.collectAttribute || '').trim());
const hasManualSlot = computed(() => !!manualSlot.value);
const resetToAuto = () => {
  draft.collectAttribute = '';
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

// PAYLOAD INALTERADO: mesmo objeto step de antes (name/instructions/collect/complete_when/
// group_delay_seconds/automations). Override manual -> collect declarado; sem override -> collect null
// (o backend infere da instrução em runtime).
const onSave = () => {
  if (!draft.name.trim()) return;
  const attribute = (draft.collectAttribute || '').trim();
  const hasSlot = !!attribute;
  const payload = {
    name: draft.name.trim(),
    instructions: (draft.instructions || '').trim(),
    group_delay_seconds: draft.group_delay_seconds,
    automations: draft.automations.map(a => ({
      type: a.type,
      params: a.params,
    })),
  };
  if (hasSlot) {
    payload.collect = {
      attribute,
      type: draft.collectType || 'text',
      required: draft.collectRequired,
    };
    if (draft.collectType === 'choice') {
      payload.collect.options = (draft.collectOptions || '')
        .split('\n')
        .map(o => o.trim())
        .filter(Boolean);
    }
    payload.complete_when = 'attribute_present';
  } else {
    payload.collect = null;
    payload.complete_when = 'always';
  }
  emit('save', payload);
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

    <!-- c) Faixa de feedback do slot (o que o sistema detectou) -->
    <div
      v-if="hasManualSlot"
      class="flex items-start gap-2 px-3 py-2 text-sm rounded-lg bg-n-blue-3 text-n-blue-11"
    >
      <span class="mt-0.5 shrink-0 size-4 i-lucide-lock" />
      <span class="flex-1 min-w-0">
        {{ $t('AI_DEPARTMENTS.FORM.SLOT_MANUAL', { slot: manualSlot }) }}
        <button
          type="button"
          class="ml-1 underline hover:no-underline"
          @click="resetToAuto"
        >
          {{ $t('AI_DEPARTMENTS.FORM.SLOT_MANUAL_RESET') }}
        </button>
      </span>
    </div>
    <div v-else-if="inferFailed" class="hidden" />
    <div
      v-else-if="detectedSlot"
      class="flex items-start gap-2 px-3 py-2 text-sm rounded-lg bg-n-teal-3 text-n-teal-11"
    >
      <span class="mt-0.5 shrink-0 size-4 i-lucide-check" />
      <span class="flex-1 min-w-0">
        {{ $t('AI_DEPARTMENTS.FORM.SLOT_DETECTED', { slot: detectedSlot }) }}
      </span>
    </div>
    <div
      v-else
      class="flex items-start gap-2 px-3 py-2 text-sm rounded-lg bg-n-blue-3 text-n-blue-11"
    >
      <span class="mt-0.5 shrink-0 size-4 i-lucide-info" />
      <span class="flex-1 min-w-0">{{
        $t('AI_DEPARTMENTS.FORM.SLOT_NONE')
      }}</span>
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

        <!-- override manual do slot -->
        <div class="flex flex-col gap-2">
          <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
            <span class="flex items-center gap-1.5">
              {{ $t('AI_DEPARTMENTS.FORM.STEP_OVERRIDE_LABEL') }}
              <span
                class="i-lucide-help-circle size-3.5 text-n-slate-10"
                :title="$t('AI_DEPARTMENTS.FORM.STEP_OVERRIDE_TOOLTIP')"
              />
            </span>
            <input
              v-model="draft.collectAttribute"
              type="text"
              :placeholder="
                $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_ATTRIBUTE_PLACEHOLDER')
              "
              class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-2"
            />
          </label>

          <template v-if="hasManualSlot">
            <label class="flex flex-col gap-1 text-sm text-n-slate-12 max-w-xs">
              {{ $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_TYPE') }}
              <Select v-model="draft.collectType" :options="slotTypeOptions" />
            </label>

            <label
              v-if="draft.collectType === 'choice'"
              class="flex flex-col gap-1.5 text-sm text-n-slate-12"
            >
              {{ $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_OPTIONS') }}
              <textarea
                v-model="draft.collectOptions"
                rows="2"
                :placeholder="
                  $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_OPTIONS_PLACEHOLDER')
                "
                class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-2 resize-y"
              />
            </label>

            <label class="flex items-center gap-2 text-sm text-n-slate-12">
              <input v-model="draft.collectRequired" type="checkbox" />
              {{ $t('AI_DEPARTMENTS.FORM.STEP_COLLECT_REQUIRED') }}
            </label>
          </template>
        </div>

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
