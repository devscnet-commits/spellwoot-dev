<script setup>
import { reactive, computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import Select from 'dashboard/components-next/select/Select.vue';
import AiPromptAssistant from './AiPromptAssistant.vue';

// Formulário de uma etapa, usado tanto na edição inline (dentro do card) quanto ao adicionar.
// Mantém um rascunho local e devolve o payload no save (o pai grava em form.steps).
const props = defineProps({
  step: { type: Object, default: null },
  isNew: { type: Boolean, default: false },
  // Fontes para os seletores das automações (carregadas pelo pai).
  labels: { type: Array, default: () => [] },
  teams: { type: Array, default: () => [] },
  customAttributes: { type: Array, default: () => [] },
  departments: { type: Array, default: () => [] },
});
const emit = defineEmits(['save', 'cancel']);
const { t } = useI18n();
const assistantOpen = ref(false);

const WEBHOOK_METHODS = ['POST', 'GET', 'PUT', 'PATCH', 'DELETE'];

const draft = reactive({
  name: props.step?.name || '',
  instructions: props.step?.instructions || '',
  group_delay_seconds: props.step?.group_delay_seconds ?? '',
  // automation_on_complete (booleano) é legado/ignorado; agora usamos automations: [{type, params}].
  automations: (Array.isArray(props.step?.automations)
    ? props.step.automations
    : []
  ).map(a => ({
    type: a?.type || 'tag',
    params: { ...(a?.params || {}) },
  })),
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

const onSave = () => {
  if (!draft.name.trim()) return;
  emit('save', {
    name: draft.name.trim(),
    instructions: (draft.instructions || '').trim(),
    group_delay_seconds: draft.group_delay_seconds,
    automations: draft.automations.map(a => ({
      type: a.type,
      params: a.params,
    })),
  });
};
</script>

<template>
  <div class="flex flex-col gap-3">
    <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
      {{ $t('AI_DEPARTMENTS.FORM.STEP_NAME') }}
      <input
        v-model="draft.name"
        type="text"
        :placeholder="$t('AI_DEPARTMENTS.FORM.STEP_NAME_PLACEHOLDER')"
        class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-2"
      />
    </label>
    <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
      <span class="flex items-center gap-1.5">
        {{ $t('AI_DEPARTMENTS.FORM.STEP_INSTRUCTIONS') }}
        <button
          type="button"
          class="i-lucide-help-circle size-4 text-n-slate-10 hover:text-n-brand"
          :title="$t('AI_AGENTS.PROMPT_ASSISTANT.OPEN')"
          @click="assistantOpen = true"
        />
      </span>
      <textarea
        v-model="draft.instructions"
        rows="3"
        :placeholder="$t('AI_DEPARTMENTS.FORM.STEP_INSTRUCTIONS_PLACEHOLDER')"
        class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-2 resize-y min-h-[5rem]"
      />
    </label>
    <label class="flex flex-col gap-1 text-sm text-n-slate-12 max-w-xs">
      {{ $t('AI_DEPARTMENTS.FORM.STEP_DELAY') }}
      <input
        v-model="draft.group_delay_seconds"
        type="number"
        min="0"
        :placeholder="$t('AI_DEPARTMENTS.FORM.STEP_DELAY_PLACEHOLDER')"
        class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-2"
      />
      <span class="text-xs text-n-slate-11">
        {{ $t('AI_DEPARTMENTS.FORM.STEP_DELAY_HINT') }}
      </span>
    </label>

    <!-- Automações ao concluir a etapa -->
    <div class="flex flex-col gap-2 border-t border-n-weak pt-3">
      <div class="flex flex-col gap-0.5">
        <span class="text-sm font-medium text-n-slate-12">
          {{ $t('AI_DEPARTMENTS.FORM.AUTOMATIONS_TITLE') }}
        </span>
        <span class="text-xs text-n-slate-11">
          {{ $t('AI_DEPARTMENTS.FORM.AUTOMATIONS_HINT') }}
        </span>
      </div>

      <p v-if="!draft.automations.length" class="text-xs text-n-slate-11 mb-0">
        {{ $t('AI_DEPARTMENTS.FORM.AUTOMATION_EMPTY') }}
      </p>

      <div
        v-for="(automation, index) in draft.automations"
        :key="index"
        class="flex flex-col gap-2 rounded-lg border border-n-weak bg-n-solid-2 p-3"
      >
        <div class="flex items-center justify-between gap-2">
          <label class="flex flex-col gap-1 text-xs text-n-slate-11">
            {{ $t('AI_DEPARTMENTS.FORM.AUTOMATION_TYPE') }}
            <Select
              v-model="automation.type"
              :options="typeOptions"
              @update:model-value="onTypeChange(index)"
            />
          </label>
          <button
            type="button"
            class="shrink-0 text-xs text-n-ruby-11 hover:underline"
            @click="removeAutomation(index)"
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
            :placeholder="$t('AI_DEPARTMENTS.FORM.AUTOMATION_TAG_PLACEHOLDER')"
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
                $t('AI_DEPARTMENTS.FORM.AUTOMATION_WEBHOOK_HEADERS_PLACEHOLDER')
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
            :placeholder="$t('AI_DEPARTMENTS.FORM.AUTOMATION_TEAM_PLACEHOLDER')"
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
