<script setup>
/* global axios */
import { ref, reactive, computed, watch, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import ConfirmDeleteModal from 'dashboard/components/widgets/modal/ConfirmDeleteModal.vue';
import { useFormDirty } from 'dashboard/composables/useFormDirty';

const route = useRoute();
const { t } = useI18n();

const PROVIDERS = ['anthropic', 'openai', 'google', 'openrouter', 'groq'];
// Pedido do usuário (18/08): só a OpenAI funciona de verdade hoje — o motor Python (orchestrator.py)
// tem um client hardcoded (_client = OpenAI(...)), então escolher qualquer outro provider aqui quebra
// a conversa inteira do department que usa este perfil, sem aviso nenhum (achado no levantamento,
// docs/ai-operation-profiles-screen-assessment.md §3). Trava o dropdown: os outros ficam visíveis mas
// desabilitados com "(em breve)" — não precisa desligar mais nada em outro lugar, eles simplesmente
// não são selecionáveis por aqui.
const AVAILABLE_PROVIDERS = ['openai'];
const providerOptions = PROVIDERS.map(p => ({
  value: p,
  label: AVAILABLE_PROVIDERS.includes(p)
    ? p
    : `${p} (${t('AI_PROFILES.FORM.PROVIDER_SOON')})`,
  disabled: !AVAILABLE_PROVIDERS.includes(p),
}));
// Groq é RESTRITO: só modelos APROVADOS no smoke test. Motivo de SEGURANÇA (não só qualidade): um
// modelo Groq (llama-3.1-8b-instant) recomendou concorrentes da empresa numa resposta de teste. Para
// groq, o campo de modelo vira um dropdown fechado com esta lista (os outros providers seguem texto
// livre). Manter em sincronia com Ai::OperationProfile::GROQ_APPROVED_MODELS (validação server-side).
const GROQ_APPROVED_MODELS = ['openai/gpt-oss-120b'];
const groqModelOptions = GROQ_APPROVED_MODELS.map(m => ({
  value: m,
  label: m,
}));
const PRESET_KEYS = ['economico', 'balanceado', 'premium', 'customizado'];

// Default operational strategies. One model per level (no routing).
// Customizado leaves the form as-is for advanced setups.
const PRESETS = {
  economico: {
    name: 'Econômico',
    model: ['openai', 'gpt-4.1-mini'],
    budget: 50,
    on_limit: 'stop',
  },
  balanceado: {
    name: 'Balanceado',
    model: ['openai', 'gpt-4.1'],
    budget: 150,
    on_limit: 'downgrade',
  },
  premium: {
    name: 'Premium',
    // Pedido do usuário (18/08): Anthropic nunca funcionou de verdade (motor Python só fala com
    // OpenAI — ver AVAILABLE_PROVIDERS acima). GPT-5.6 Terra (lançado 07/2026): "o padrão
    // equilibrado... performance competitiva ao GPT-5.5, 2x mais barato" — o Sol (flagship) mira em
    // codificação/agentic longo, não em atendimento ao cliente; Terra entrega qualidade premium sem
    // pagar o preço do Sol por uma capacidade que este produto não usa. Cai automaticamente na
    // proteção de temperature pra modelo de raciocínio (Ai::TemperatureMapper, mesmo "gpt-5" prefix).
    model: ['openai', 'gpt-5.6-terra'],
    budget: 500,
    on_limit: 'alert',
  },
  customizado: null,
};

const profiles = ref([]);
const isLoading = ref(false);
const showForm = ref(false);

const blank = () => ({
  id: null,
  preset: 'balanceado',
  name: '',
  supervisor_provider: 'openai',
  supervisor_model: '',
  temperature_position: 20,
  budget_usd: '',
  on_limit: 'downgrade',
});
const form = reactive(blank());
const { isDirty, capture } = useFormDirty(() => ({ ...form }));

// Ao trocar o provider do supervisor para 'groq', se o modelo atual não for aprovado, seleciona o
// default aprovado — assim o dropdown fechado nunca fica com um valor inválido (e não salva um modelo
// Groq não permitido). Trocar PARA outro provider não mexe no modelo (mantém o comportamento livre).
watch(
  () => form.supervisor_provider,
  provider => {
    if (
      provider === 'groq' &&
      !GROQ_APPROVED_MODELS.includes(form.supervisor_model)
    ) {
      form.supervisor_model = GROQ_APPROVED_MODELS[0];
    }
  }
);

// The whole engine (supervisor/routing/budget) lives behind a single
// "Avançado" disclosure so the main flow is just: pick a level + name it.
const sections = reactive({ advanced: false });

// What each level delivers to the client — cost/speed/quality, never the engine.
const LEVEL_EFFECTS = {
  economico: { cost: 'LOW', speed: 'HIGH', quality: 'MEDIUM' },
  balanceado: { cost: 'MEDIUM', speed: 'HIGH', quality: 'HIGH' },
  premium: { cost: 'HIGH', speed: 'MEDIUM', quality: 'MAX' },
  customizado: null,
};
const levelEffect = computed(() => LEVEL_EFFECTS[form.preset]);

const onLimitOptions = computed(() =>
  ['stop', 'downgrade', 'alert'].map(v => ({
    value: v,
    label: t(`AI_PROFILES.BUDGET.ON_LIMIT_${v.toUpperCase()}`),
  }))
);

const applyPreset = key => {
  form.preset = key;
  const preset = PRESETS[key];
  if (!preset) return;
  form.name = form.name || preset.name;
  [form.supervisor_provider, form.supervisor_model] = preset.model;
  form.budget_usd = preset.budget;
  form.on_limit = preset.on_limit;
};

// Show the effect of the level (cost/quality), never the engine behind it.
const profileSubtitle = p => {
  const tier = p.tier || 'customizado';
  const label = t(`AI_PROFILES.PRESET.${tier.toUpperCase()}`);
  const eff = LEVEL_EFFECTS[tier];
  if (!eff) return label;
  const val = k => t(`AI_PROFILES.LEVELS.VALUE.${k}`);
  return `${label} · ${t('AI_PROFILES.LEVELS.COST')}: ${val(eff.cost)} · ${t('AI_PROFILES.LEVELS.QUALITY')}: ${val(eff.quality)}`;
};

const baseUrl = () =>
  `/api/v1/accounts/${route.params.accountId}/ai_operation_profiles`;

const fetchProfiles = async () => {
  isLoading.value = true;
  try {
    const { data } = await axios.get(baseUrl());
    profiles.value = Array.isArray(data) ? data : [];
  } finally {
    isLoading.value = false;
  }
};

const openNew = () => {
  Object.assign(form, blank());
  applyPreset('balanceado');
  form.name = '';
  showForm.value = true;
  capture();
};

const openEdit = profile => {
  // profile.routing_strategy É preservado no banco (o backend só toca a coluna quando a chave vem no
  // payload — ver #save abaixo) mas esta tela não lê nem edita mais nenhum campo dele: não existe UI
  // pra roteamento por confiança hoje, só o preset "um modelo por nível" (ver Ai::PythonMigrationAuditor
  // pra contexto de por que o roteamento ao vivo ainda não existe no motor Python).
  const budget = profile.budget || {};
  Object.assign(form, blank(), {
    id: profile.id,
    preset: profile.tier || 'customizado',
    name: profile.name,
    supervisor_provider: profile.supervisor_provider,
    supervisor_model: profile.supervisor_model,
    temperature_position: profile.temperature_position ?? 20,
    budget_usd: budget.monthly_usd ?? '',
    on_limit: budget.on_limit || 'downgrade',
  });
  showForm.value = true;
  capture();
};

// Posição abstrata do slider (0-100). O backend (Ai::TemperatureMapper) traduz para a temperatura
// real de cada provider — o front nunca manda o número cru de temperatura.
const clampPosition = value => {
  const n = Number(value);
  if (Number.isNaN(n)) return 20;
  return Math.min(100, Math.max(0, Math.round(n)));
};

const save = async () => {
  const payload = {
    ai_operation_profile: {
      name: form.name,
      tier: form.preset,
      supervisor_provider: form.supervisor_provider,
      supervisor_model: form.supervisor_model,
      temperature_position: clampPosition(form.temperature_position),
      // worker_overrides E routing_strategy NÃO entram no payload de propósito (nem {} nem um valor
      // parcial): esta tela não edita mais nenhuma chave de worker (OCR/Summary/Tradução/RAG/Juiz de
      // captura removidos — a OpenAI faz Visão e Memória nativamente no path novo) nem de roteamento
      // por confiança (nunca teve UI real — ver docs/ai-operation-profiles-screen-assessment.md §2). O
      // controller só toca essas colunas quando a chave está PRESENTE no payload (Api::V1::Accounts::
      // AiOperationProfilesController#jsonb_params) — omitir preserva o que já está salvo (inclusive
      // chaves sem UI nenhuma, como trivial_gate/native_tools, ou um routing_strategy antigo que uma
      // conta já tinha) em vez de sobrescrever com um hash vazio.
      budget: {
        monthly_usd: Number(form.budget_usd) || 0,
        on_limit: form.on_limit,
      },
    },
  };
  try {
    if (form.id) {
      await axios.patch(`${baseUrl()}/${form.id}`, payload);
    } else {
      await axios.post(baseUrl(), payload);
    }
    useAlert(t('AI_PROFILES.SAVED'));
    showForm.value = false;
    fetchProfiles();
  } catch (error) {
    // Achado ao vivo (18/08): "erro genérico" sem detalhe nenhum (ex.: nome duplicado) deixava o
    // usuário sem saber o que corrigir. Mesmo padrão já usado em AiKnowledge.vue/AiStepForm.vue —
    // mostra a mensagem REAL de validação do backend quando existe.
    useAlert(
      error.response?.data?.errors?.join('. ') || t('AI_PROFILES.ERROR')
    );
  }
};

const deleteTarget = ref(null);
const confirmRemove = async () => {
  try {
    await axios.delete(`${baseUrl()}/${deleteTarget.value.id}`);
    useAlert(t('AI_PROFILES.DELETED'));
    deleteTarget.value = null;
    fetchProfiles();
  } catch (error) {
    useAlert(t('AI_PROFILES.ERROR'));
  }
};

onMounted(fetchProfiles);
</script>

<template>
  <div class="w-full h-full overflow-auto bg-n-background p-4 sm:p-6">
    <div class="max-w-4xl mx-auto flex flex-col gap-3">
      <div
        class="rounded-2xl border border-n-weak bg-n-solid-1 px-4 sm:px-8 py-6 flex flex-col gap-4"
      >
        <div class="flex items-start justify-between gap-4">
          <div class="flex flex-col gap-1 min-w-0">
            <h1 class="text-xl font-semibold text-n-slate-12">
              {{ $t('AI_PROFILES.TITLE') }}
            </h1>
            <p class="text-sm text-n-slate-11 mb-0">
              {{ $t('AI_PROFILES.DESCRIPTION') }}
            </p>
          </div>
          <div class="shrink-0">
            <Button
              icon="i-lucide-plus"
              :label="$t('AI_PROFILES.NEW')"
              @click="openNew"
            />
          </div>
        </div>

        <p
          v-if="!isLoading && !profiles.length"
          class="text-sm text-n-slate-11 py-8 text-center"
        >
          {{ $t('AI_PROFILES.EMPTY') }}
        </p>
        <div
          v-else
          class="border border-n-weak rounded-xl divide-y divide-n-weak"
        >
          <div
            v-for="profile in profiles"
            :key="profile.id"
            class="flex items-center justify-between px-4 py-3 gap-3"
          >
            <div class="min-w-0">
              <p class="text-sm font-medium text-n-slate-12">
                {{ profile.name }}
              </p>
              <p class="text-xs text-n-slate-11 truncate">
                {{ profileSubtitle(profile) }}
              </p>
            </div>
            <div class="shrink-0 flex items-center gap-1">
              <Button
                variant="ghost"
                color="slate"
                size="sm"
                icon="i-lucide-pencil"
                @click="openEdit(profile)"
              />
              <Button
                variant="ghost"
                color="ruby"
                size="sm"
                icon="i-lucide-trash-2"
                @click="deleteTarget = profile"
              />
            </div>
          </div>
        </div>

        <div
          v-if="showForm"
          class="border border-n-weak rounded-xl p-5 flex flex-col gap-6 bg-n-solid-2"
        >
          <!-- Nível de atendimento: o que o cliente escolhe (resultado, não motor) -->
          <section class="flex flex-col gap-2">
            <div class="flex flex-col gap-0.5">
              <span class="text-sm font-semibold text-n-slate-12">{{
                $t('AI_PROFILES.PRESET.LABEL')
              }}</span>
              <p class="text-xs text-n-slate-11 mb-0">
                {{ $t('AI_PROFILES.LEVELS.HINT') }}
              </p>
            </div>
            <div class="grid grid-cols-2 sm:grid-cols-4 gap-2">
              <button
                v-for="key in PRESET_KEYS"
                :key="key"
                type="button"
                class="px-3 py-2 rounded-lg border text-sm font-medium transition-colors"
                :class="
                  form.preset === key
                    ? 'border-n-brand bg-n-brand/5 text-n-slate-12'
                    : 'border-n-weak text-n-slate-11 hover:border-n-slate-7'
                "
                @click="applyPreset(key)"
              >
                {{ $t(`AI_PROFILES.PRESET.${key.toUpperCase()}`) }}
              </button>
            </div>
            <!-- Efeito do nível: custo / velocidade / qualidade -->
            <div
              v-if="levelEffect"
              class="rounded-xl border border-n-weak bg-n-solid-1 p-4 flex flex-col gap-3"
            >
              <p class="text-xs text-n-slate-11 mb-0">
                {{ $t(`AI_PROFILES.LEVELS.${form.preset.toUpperCase()}_DESC`) }}
              </p>
              <div class="grid grid-cols-3 gap-3">
                <div class="flex flex-col gap-0.5">
                  <span class="text-xs text-n-slate-10">{{
                    $t('AI_PROFILES.LEVELS.COST')
                  }}</span>
                  <span class="text-sm font-medium text-n-slate-12">{{
                    $t(`AI_PROFILES.LEVELS.VALUE.${levelEffect.cost}`)
                  }}</span>
                </div>
                <div class="flex flex-col gap-0.5">
                  <span class="text-xs text-n-slate-10">{{
                    $t('AI_PROFILES.LEVELS.SPEED')
                  }}</span>
                  <span class="text-sm font-medium text-n-slate-12">{{
                    $t(`AI_PROFILES.LEVELS.VALUE.${levelEffect.speed}`)
                  }}</span>
                </div>
                <div class="flex flex-col gap-0.5">
                  <span class="text-xs text-n-slate-10">{{
                    $t('AI_PROFILES.LEVELS.QUALITY')
                  }}</span>
                  <span class="text-sm font-medium text-n-slate-12">{{
                    $t(`AI_PROFILES.LEVELS.VALUE.${levelEffect.quality}`)
                  }}</span>
                </div>
              </div>
            </div>
          </section>

          <Input v-model="form.name" :label="$t('AI_PROFILES.FORM.NAME')" />

          <!-- Avançado: o motor (supervisor, workers, roteamento, orçamento) -->
          <section class="border border-n-weak rounded-xl bg-n-solid-1">
            <button
              type="button"
              class="w-full flex items-center gap-2 px-4 py-3 text-left"
              @click="sections.advanced = !sections.advanced"
            >
              <span
                class="size-4 inline-block text-n-slate-11 shrink-0"
                :class="
                  sections.advanced
                    ? 'i-lucide-chevron-down'
                    : 'i-lucide-chevron-right'
                "
              />
              <span class="flex flex-col gap-0.5 min-w-0">
                <span class="text-sm font-semibold text-n-slate-12">
                  {{ $t('AI_PROFILES.ADVANCED.TITLE') }}
                </span>
                <span class="text-xs text-n-slate-11">
                  {{ $t('AI_PROFILES.ADVANCED.DESCRIPTION') }}
                </span>
              </span>
            </button>
            <div
              v-if="sections.advanced"
              class="border-t border-n-weak p-4 flex flex-col gap-6"
            >
              <!-- Supervisor -->
              <div class="flex flex-col gap-2">
                <div class="flex flex-col gap-0.5">
                  <h3 class="text-sm font-semibold text-n-slate-12">
                    {{ $t('AI_PROFILES.SUPERVISOR.TITLE') }}
                  </h3>
                  <p class="text-xs text-n-slate-11 mb-0">
                    {{ $t('AI_PROFILES.SUPERVISOR.DESCRIPTION') }}
                  </p>
                </div>
                <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                  <div class="flex flex-col gap-1.5">
                    <span class="text-sm font-medium text-n-slate-12">{{
                      $t('AI_PROFILES.FORM.PROVIDER')
                    }}</span>
                    <Select
                      v-model="form.supervisor_provider"
                      :options="providerOptions"
                    />
                  </div>
                  <!-- Groq: dropdown FECHADO só com modelos aprovados (segurança). Demais providers: texto livre. -->
                  <div
                    v-if="form.supervisor_provider === 'groq'"
                    class="flex flex-col gap-1.5"
                  >
                    <span class="text-sm font-medium text-n-slate-12">{{
                      $t('AI_PROFILES.FORM.MODEL')
                    }}</span>
                    <Select
                      v-model="form.supervisor_model"
                      :options="groqModelOptions"
                    />
                  </div>
                  <Input
                    v-else
                    v-model="form.supervisor_model"
                    :label="$t('AI_PROFILES.FORM.MODEL')"
                  />
                  <div class="flex flex-col gap-1.5">
                    <label class="text-sm font-medium text-n-slate-12">
                      {{ $t('AI_PROFILES.SUPERVISOR.TEMPERATURE') }}
                    </label>
                    <input
                      v-model.number="form.temperature_position"
                      type="range"
                      min="0"
                      max="100"
                      step="5"
                      class="w-full accent-n-brand"
                    />
                    <div
                      class="flex justify-between text-xs text-n-slate-11 select-none"
                    >
                      <span>{{
                        $t('AI_PROFILES.SUPERVISOR.TEMPERATURE_RIGID')
                      }}</span>
                      <span>{{
                        $t('AI_PROFILES.SUPERVISOR.TEMPERATURE_BALANCED')
                      }}</span>
                      <span>{{
                        $t('AI_PROFILES.SUPERVISOR.TEMPERATURE_CREATIVE')
                      }}</span>
                    </div>
                    <p class="text-xs text-n-slate-11 mb-0">
                      {{ $t('AI_PROFILES.SUPERVISOR.TEMPERATURE_HINT') }}
                    </p>
                  </div>
                </div>
              </div>

              <!-- Budget -->
              <div class="flex flex-col gap-2">
                <div class="flex flex-col gap-0.5">
                  <h3 class="text-sm font-semibold text-n-slate-12">
                    {{ $t('AI_PROFILES.BUDGET.TITLE') }}
                  </h3>
                  <p class="text-xs text-n-slate-11 mb-0">
                    {{ $t('AI_PROFILES.BUDGET.DESCRIPTION') }}
                  </p>
                </div>
                <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                  <Input
                    v-model="form.budget_usd"
                    type="number"
                    :label="$t('AI_PROFILES.BUDGET.MONTHLY')"
                  />
                  <div class="flex flex-col gap-1.5">
                    <span class="text-sm font-medium text-n-slate-12">{{
                      $t('AI_PROFILES.BUDGET.ON_LIMIT')
                    }}</span>
                    <Select v-model="form.on_limit" :options="onLimitOptions" />
                  </div>
                </div>
              </div>
            </div>
          </section>

          <div class="flex justify-end gap-2">
            <Button
              variant="faded"
              color="slate"
              :label="$t('AI_PROFILES.FORM.CANCEL')"
              @click="showForm = false"
            />
            <Button
              :label="$t('AI_PROFILES.FORM.SAVE')"
              :disabled="!isDirty"
              @click="save"
            />
          </div>
        </div>

        <ConfirmDeleteModal
          v-if="deleteTarget"
          show
          :title="$t('AI_PROFILES.DELETE_MODAL.TITLE')"
          :message="
            $t('AI_PROFILES.DELETE_MODAL.MESSAGE', { name: deleteTarget.name })
          "
          :confirm-text="$t('AI_PROFILES.DELETE_MODAL.CONFIRM')"
          :reject-text="$t('AI_PROFILES.DELETE_MODAL.CANCEL')"
          :confirm-value="deleteTarget.name"
          :confirm-place-holder-text="
            $t('AI_PROFILES.DELETE_MODAL.PLACEHOLDER', {
              name: deleteTarget.name,
            })
          "
          @on-confirm="confirmRemove"
          @on-close="deleteTarget = null"
        />
      </div>
    </div>
  </div>
</template>
