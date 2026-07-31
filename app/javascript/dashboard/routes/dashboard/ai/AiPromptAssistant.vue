<script setup>
/* global axios */
// Slide-over (painel lateral) que sugere um base_prompt ou instruções de etapa a partir de um brief
// do usuário. Single-shot: descreve -> gera -> UMA sugestão (não preenche o campo; o usuário copia).
// Usa o axios GLOBAL do Chatwoot (autenticado) — nunca o import cru.
import { ref, computed } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import Button from 'dashboard/components-next/button/Button.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import TeleportWithDirection from 'dashboard/components-next/TeleportWithDirection.vue';

const props = defineProps({
  open: { type: Boolean, default: false },
  // 'base_prompt' | 'step_instructions'
  kind: { type: String, default: 'base_prompt' },
  // Department em edição: ancora as CAPACIDADES REAIS (tools/knowledge/variáveis) no backend, para o
  // assistente não sugerir consulta sem fonte nem variável inventada. Ausente => o backend degrada.
  departmentId: { type: [String, Number], default: null },
});
const emit = defineEmits(['update:open']);

const route = useRoute();
const { t } = useI18n();

const brief = ref('');
const suggestion = ref('');
const loading = ref(false);

const title = computed(() =>
  props.kind === 'step_instructions'
    ? t('AI_AGENTS.PROMPT_ASSISTANT.TITLE_STEP_INSTRUCTIONS')
    : t('AI_AGENTS.PROMPT_ASSISTANT.TITLE_BASE_PROMPT')
);

const close = () => emit('update:open', false);

const generate = async () => {
  if (loading.value || !brief.value.trim()) return; // mata duplo-clique / brief vazio
  loading.value = true;
  suggestion.value = '';
  try {
    const { data } = await axios.post(
      `/api/v1/accounts/${route.params.accountId}/ai_prompt_assistant`,
      {
        kind: props.kind,
        brief: brief.value.trim(),
        department_id: props.departmentId || undefined,
      }
    );
    if (data && data.suggestion) {
      suggestion.value = data.suggestion;
    } else {
      useAlert(t('AI_AGENTS.PROMPT_ASSISTANT.ERROR'));
    }
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error(
      '[AiPromptAssistant] falha ao gerar:',
      error?.response?.status,
      error
    );
    useAlert(t('AI_AGENTS.PROMPT_ASSISTANT.ERROR'));
  } finally {
    loading.value = false;
  }
};

const copy = async () => {
  if (!suggestion.value) return;
  try {
    await navigator.clipboard.writeText(suggestion.value);
    useAlert(t('AI_AGENTS.PROMPT_ASSISTANT.COPIED'));
  } catch (error) {
    // clipboard indisponível: o usuário seleciona manualmente o texto.
  }
};
</script>

<template>
  <TeleportWithDirection to="body">
    <Transition
      enter-active-class="transition-opacity duration-200"
      enter-from-class="opacity-0"
      leave-active-class="transition-opacity duration-200"
      leave-to-class="opacity-0"
    >
      <div v-if="open" class="fixed inset-0 z-40 bg-black/40" @click="close" />
    </Transition>
    <Transition
      enter-active-class="transition-transform duration-200 ease-out"
      enter-from-class="translate-x-full"
      enter-to-class="translate-x-0"
      leave-active-class="transition-transform duration-200 ease-in"
      leave-from-class="translate-x-0"
      leave-to-class="translate-x-full"
    >
      <aside
        v-if="open"
        class="fixed inset-y-0 right-0 z-50 w-full max-w-[440px] bg-n-solid-1 border-l border-n-weak shadow-xl flex flex-col"
      >
        <header
          class="flex items-start justify-between gap-3 p-5 border-b border-n-weak"
        >
          <div class="flex flex-col gap-1 min-w-0">
            <h3 class="text-base font-medium text-n-slate-12 mb-0">
              {{ title }}
            </h3>
            <p class="text-xs text-n-slate-11 mb-0">
              {{ $t('AI_AGENTS.PROMPT_ASSISTANT.SUBTITLE') }}
            </p>
          </div>
          <button
            type="button"
            class="shrink-0 i-lucide-x size-5 text-n-slate-11"
            :aria-label="$t('AI_AGENTS.PROMPT_ASSISTANT.CLOSE')"
            @click="close"
          />
        </header>

        <div class="flex-1 overflow-y-auto p-5 flex flex-col gap-4">
          <TextArea
            v-model="brief"
            :label="$t('AI_AGENTS.PROMPT_ASSISTANT.BRIEF_LABEL')"
            :placeholder="$t('AI_AGENTS.PROMPT_ASSISTANT.BRIEF_PLACEHOLDER')"
            custom-text-area-class="min-h-24 resize-y"
          />
          <Button
            :label="$t('AI_AGENTS.PROMPT_ASSISTANT.GENERATE')"
            :is-loading="loading"
            :disabled="loading || !brief.trim()"
            class="self-start"
            @click="generate"
          />

          <div
            v-if="suggestion"
            class="flex flex-col gap-2 border-t border-n-weak pt-4"
          >
            <div class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('AI_AGENTS.PROMPT_ASSISTANT.RESULT_LABEL') }}
              </span>
              <Button
                variant="ghost"
                color="slate"
                size="sm"
                :label="$t('AI_AGENTS.PROMPT_ASSISTANT.COPY')"
                @click="copy"
              />
            </div>
            <pre
              class="text-sm text-n-slate-12 whitespace-pre-wrap break-words bg-n-solid-2 border border-n-weak rounded-lg p-3 mb-0"
              >{{ suggestion }}</pre
            >
          </div>
        </div>
      </aside>
    </Transition>
  </TeleportWithDirection>
</template>
