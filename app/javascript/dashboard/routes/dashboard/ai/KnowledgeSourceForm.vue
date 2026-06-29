<script setup>
import { useI18n } from 'vue-i18n';

defineProps({
  titleLabel: { type: String, default: '' },
  rawLabel: { type: String, default: '' },
  headingLabel: { type: String, default: '' },
  headingIcon: { type: String, default: '' },
  disableSave: { type: Boolean, default: false },
});
defineEmits(['save', 'cancel']);
// Editor de uma fonte de conhecimento. Reutilizado para criar (acima da lista) e para
// editar no lugar (inline, no próprio card), evitando rolar até o fim da página.
// Objeto reativo compartilhado com o pai (mutação in-place das suas chaves).
const form = defineModel('form', { type: Object, required: true });
const { t } = useI18n();
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
