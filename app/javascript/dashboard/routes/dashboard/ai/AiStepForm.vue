<script setup>
import { reactive } from 'vue';

// Formulário de uma etapa, usado tanto na edição inline (dentro do card) quanto ao adicionar.
// Mantém um rascunho local e devolve o payload no save (o pai grava em form.steps).
const props = defineProps({
  step: { type: Object, default: null },
  isNew: { type: Boolean, default: false },
});
const emit = defineEmits(['save', 'cancel']);

const draft = reactive({
  name: props.step?.name || '',
  instructions: props.step?.instructions || '',
  group_delay_seconds: props.step?.group_delay_seconds ?? '',
  automation_on_complete: !!props.step?.automation_on_complete,
});

const onSave = () => {
  if (!draft.name.trim()) return;
  emit('save', {
    name: draft.name.trim(),
    instructions: (draft.instructions || '').trim(),
    group_delay_seconds: draft.group_delay_seconds,
    automation_on_complete: !!draft.automation_on_complete,
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
      {{ $t('AI_DEPARTMENTS.FORM.STEP_INSTRUCTIONS') }}
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
    <div class="flex items-center justify-between gap-3 flex-wrap">
      <label class="flex items-center gap-2 text-sm text-n-slate-12">
        <input v-model="draft.automation_on_complete" type="checkbox" />
        {{ $t('AI_DEPARTMENTS.FORM.STEP_AUTOMATION') }}
      </label>
      <div class="flex items-center gap-2">
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
  </div>
</template>
