<script setup>
/* global axios */
// Slide-over (painel lateral) que sugere um base_prompt ou instruções de etapa a partir de um brief do
// usuário. base_prompt: single-shot, UMA sugestão em texto (não preenche o campo; o usuário copia) —
// o base_prompt não tem "campos" pra aplicar direto. step_instructions: contrato de 3 campos SEPARADOS
// (objective/rules/suggested_script, espelha AiStepForm.vue) — o admin revisa o preview e clica
// "Usar esta sugestão" pra aplicar direto nos 3 campos do form (emit('apply')); nada é salvo sozinho,
// o Salvar da etapa continua sendo o único gesto que persiste. Usa o axios GLOBAL do Chatwoot
// (autenticado) — nunca o import cru.
//
// admin_warnings (4º campo, só em step_instructions): avisos pro ADMIN humano (ex.: "crie a variável
// X antes de publicar"), mostrados num bloco À PARTE (adminWarnings, abaixo) — NUNCA entram em
// `structured` nem no payload do apply(). Bug real que isso corrige: o assistente costumava escrever
// esse aviso DENTRO de objective/rules, a IA lia como se fosse instrução de comportamento e ficava
// confusa (objective/rules/suggested_script vão direto pro system_prompt da IA).
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
const emit = defineEmits(['update:open', 'apply']);

const route = useRoute();
const { t } = useI18n();

const isStepKind = computed(() => props.kind === 'step_instructions');

const brief = ref('');
const suggestion = ref(''); // base_prompt: texto único
const structured = ref(null); // step_instructions: { objective, rules, suggestedScript } — SÓ isso vai pro apply()
const adminWarnings = ref([]); // step_instructions: avisos pro admin humano — NUNCA aplicados ao form
const loading = ref(false);

const title = computed(() =>
  isStepKind.value
    ? t('AI_AGENTS.PROMPT_ASSISTANT.TITLE_STEP_INSTRUCTIONS')
    : t('AI_AGENTS.PROMPT_ASSISTANT.TITLE_BASE_PROMPT')
);

const hasResult = computed(() =>
  isStepKind.value
    ? !!structured.value || adminWarnings.value.length > 0
    : !!suggestion.value
);

const close = () => emit('update:open', false);

const generate = async () => {
  if (loading.value || !brief.value.trim()) return; // mata duplo-clique / brief vazio
  loading.value = true;
  suggestion.value = '';
  structured.value = null;
  adminWarnings.value = [];
  try {
    const { data } = await axios.post(
      `/api/v1/accounts/${route.params.accountId}/ai_prompt_assistant`,
      {
        kind: props.kind,
        brief: brief.value.trim(),
        department_id: props.departmentId || undefined,
      }
    );
    if (isStepKind.value) {
      const warnings = Array.isArray(data?.admin_warnings)
        ? data.admin_warnings
        : [];
      const hasContent =
        data &&
        (data.objective ||
          (data.rules && data.rules.length) ||
          data.suggested_script ||
          warnings.length);
      if (hasContent) {
        // SEMPRE os 3 campos (mesmo vazios) — nunca null enquanto houver algo pra mostrar (evita
        // template quebrar lendo structured.objective quando só veio admin_warnings).
        structured.value = {
          objective: data.objective || '',
          rules: Array.isArray(data.rules) ? data.rules : [],
          suggestedScript: data.suggested_script || '',
        };
        adminWarnings.value = warnings;
      } else {
        useAlert(t('AI_AGENTS.PROMPT_ASSISTANT.ERROR'));
      }
    } else if (data && data.suggestion) {
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

// step_instructions: aplica direto nos 3 campos do AiStepForm (o admin ainda revisa/edita e clica
// Salvar) — em vez de copiar/colar manualmente 3 blocos separados.
const apply = () => {
  if (!structured.value) return;
  emit('apply', structured.value);
  close();
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
            v-if="hasResult"
            class="flex flex-col gap-2 border-t border-n-weak pt-4"
          >
            <div class="flex items-center justify-between gap-2">
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t('AI_AGENTS.PROMPT_ASSISTANT.RESULT_LABEL') }}
              </span>
              <Button
                v-if="!isStepKind"
                variant="ghost"
                color="slate"
                size="sm"
                :label="$t('AI_AGENTS.PROMPT_ASSISTANT.COPY')"
                @click="copy"
              />
              <Button
                v-else
                variant="solid"
                color="blue"
                size="sm"
                :label="$t('AI_AGENTS.PROMPT_ASSISTANT.APPLY')"
                @click="apply"
              />
            </div>

            <!-- base_prompt: texto único, copiável -->
            <pre
              v-if="!isStepKind"
              class="text-sm text-n-slate-12 whitespace-pre-wrap break-words bg-n-solid-2 border border-n-weak rounded-lg p-3 mb-0"
              >{{ suggestion }}</pre
            >

            <!-- step_instructions: preview dos 3 campos SEPARADOS (o que vai ser aplicado no form) -->
            <div v-else class="flex flex-col gap-3">
              <div class="flex flex-col gap-1">
                <span class="text-xs font-medium text-n-slate-11">
                  {{ $t('AI_DEPARTMENTS.FORM.STEP_OBJECTIVE_LABEL') }}
                </span>
                <p
                  class="text-sm text-n-slate-12 bg-n-solid-2 border border-n-weak rounded-lg p-3 mb-0"
                >
                  {{ structured.objective }}
                </p>
              </div>
              <div class="flex flex-col gap-1">
                <span class="text-xs font-medium text-n-slate-11">
                  {{ $t('AI_DEPARTMENTS.FORM.STEP_RULES_LABEL') }}
                </span>
                <ul
                  class="text-sm text-n-slate-12 bg-n-solid-2 border border-n-weak rounded-lg p-3 mb-0 pl-4 list-disc"
                >
                  <li v-for="(rule, i) in structured.rules" :key="i">
                    {{ rule }}
                  </li>
                </ul>
              </div>
              <div class="flex flex-col gap-1">
                <span class="text-xs font-medium text-n-slate-11">
                  {{ $t('AI_DEPARTMENTS.FORM.STEP_SUGGESTED_SCRIPT_LABEL') }}
                </span>
                <p
                  class="text-sm text-n-slate-12 italic bg-n-solid-2 border border-n-weak rounded-lg p-3 mb-0"
                >
                  <q>{{ structured.suggestedScript }}</q>
                </p>
              </div>
            </div>

            <!-- admin_warnings: SÓ pro admin humano ler. Bloco à parte, de propósito — NUNCA entra no
                 apply() (não é conteúdo do form, é uma nota sobre configuração pendente). -->
            <div
              v-if="isStepKind && adminWarnings.length"
              class="flex flex-col gap-1.5 rounded-lg border border-n-amber-6 bg-n-amber-2 p-3"
              data-testid="admin-warnings"
            >
              <span class="text-xs font-medium text-n-amber-11">
                {{ $t('AI_AGENTS.PROMPT_ASSISTANT.ADMIN_WARNINGS_LABEL') }}
              </span>
              <ul class="text-sm text-n-amber-11 mb-0 pl-4 list-disc">
                <li v-for="(warning, i) in adminWarnings" :key="i">
                  {{ warning }}
                </li>
              </ul>
            </div>
          </div>
        </div>
      </aside>
    </Transition>
  </TeleportWithDirection>
</template>
