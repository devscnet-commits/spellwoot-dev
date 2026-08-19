<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Select from 'dashboard/components-next/select/Select.vue';
import { scopeOptionLabel } from './knowledgeScope';

const props = defineProps({
  titleLabel: { type: String, default: '' },
  rawLabel: { type: String, default: '' },
  headingLabel: { type: String, default: '' },
  headingIcon: { type: String, default: '' },
  disableSave: { type: Boolean, default: false },
  agents: { type: Array, default: () => [] },
});
defineEmits(['save', 'cancel']);
// Editor de uma fonte de conhecimento. Reutilizado para criar (acima da lista) e para
// editar no lugar (inline, no próprio card), evitando rolar até o fim da página.
// Objeto reativo compartilhado com o pai (mutação in-place das suas chaves).
const form = defineModel('form', { type: Object, required: true });
const { t } = useI18n();

// "Todos / Compartilhado" (valor '') = fonte account-wide (ai_agent_id nil); ou escopar num
// agente. Valores como String p/ o Select; a conversão de volta ('' -> null) é no save do pai.
const agentOptions = computed(() => [
  { value: '', label: t('AI_KNOWLEDGE.FORM.DEPARTMENT_ALL') },
  ...props.agents.map(d => ({
    value: String(d.id),
    label: scopeOptionLabel(d),
  })),
]);
const selectedAgent = computed({
  get: () => (form.value.ai_agent_id ? String(form.value.ai_agent_id) : ''),
  set: value => {
    form.value.ai_agent_id = value === '' ? null : Number(value);
  },
});
</script>

<template>
  <div
    class="border border-n-weak rounded-xl p-5 flex flex-col gap-3 bg-n-solid-1"
  >
    <h3
      class="text-sm font-semibold text-n-slate-12 mb-0 flex items-center gap-2"
    >
      <span :class="headingIcon" class="size-4 text-n-brand" />
      {{ headingLabel }}
    </h3>
    <label class="flex flex-col gap-1 text-sm text-n-slate-12">
      {{ titleLabel }}
      <input
        v-model="form.title"
        type="text"
        class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
      />
    </label>
    <label class="flex flex-col gap-1 text-sm text-n-slate-12">
      {{ rawLabel }}
      <textarea
        v-model="form.raw"
        rows="10"
        class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-y min-h-40 max-h-[70vh]"
      />
    </label>
    <div class="flex flex-col gap-1 text-sm text-n-slate-12 max-w-xs">
      <span>{{ t('AI_KNOWLEDGE.FORM.DEPARTMENT') }}</span>
      <Select v-model="selectedAgent" :options="agentOptions" />
      <span class="text-xs text-n-slate-11">
        {{ t('AI_KNOWLEDGE.FORM.DEPARTMENT_HINT') }}
      </span>
    </div>
    <label
      v-if="form.kind === 'produto'"
      class="flex flex-col gap-1 text-sm text-n-slate-12 max-w-xs"
    >
      {{ t('AI_KNOWLEDGE.FORM.PRICE') }}
      <input
        v-model="form.price"
        type="text"
        :placeholder="t('AI_KNOWLEDGE.FORM.PRICE_PLACEHOLDER')"
        class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
      />
    </label>
    <div class="flex justify-end gap-2">
      <button
        type="button"
        class="text-sm px-3 py-2 rounded-lg bg-n-alpha-2 text-n-slate-12"
        @click="$emit('cancel')"
      >
        {{ t('AI_KNOWLEDGE.FORM.CANCEL') }}
      </button>
      <button
        type="button"
        :disabled="disableSave"
        class="text-sm font-medium px-3 py-2 rounded-lg bg-n-brand text-white disabled:opacity-50 disabled:cursor-not-allowed"
        @click="$emit('save')"
      >
        {{ t('AI_KNOWLEDGE.FORM.SAVE') }}
      </button>
    </div>
  </div>
</template>
