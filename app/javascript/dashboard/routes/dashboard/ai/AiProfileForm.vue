<script setup>
// Extraído de AiProfiles.vue (achado ao vivo, 21/08): o form vivia num bloco único e SEPARADO no fim
// da tela — ao editar um perfil no meio da lista, nada indicava qual linha aquele form pertencia
// (usuária precisou circular a linha manualmente pra explicar). Este componente renderiza SANFONA,
// logo abaixo da própria linha clicada (ou no fim da lista, ao criar) — mesmo padrão de AiStepForm.vue.
// Uma instância NOVA nasce a cada abertura (o pai troca via v-if), então #hydrate roda uma vez em
// onMounted, sem precisar de watch em props.profile.
import { reactive, computed, watch, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import Input from 'dashboard/components-next/input/Input.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import { useFormDirty } from 'dashboard/composables/useFormDirty';

const props = defineProps({
  // null = criando um novo perfil.
  profile: { type: Object, default: null },
});
const emit = defineEmits(['save', 'cancel']);

const { t } = useI18n();

const PROVIDERS = ['anthropic', 'openai', 'google', 'openrouter', 'groq'];
// Pedido do usuário (18/08): só a OpenAI funciona de verdade hoje — o motor Python (orchestrator.py)
// tem um client hardcoded (_client = OpenAI(...)), então escolher qualquer outro provider aqui quebra
// a conversa inteira do agente que usa este perfil, sem aviso nenhum (achado no levantamento,
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

const blank = () => ({
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

// O motor inteiro (supervisor/roteamento/orçamento) vive atrás de UMA sanfona "Avançado" — o fluxo
// principal é só: escolher um nível + nomear.
const sections = reactive({ advanced: false });

// O que cada nível entrega pro cliente — custo/velocidade/qualidade, nunca o motor por trás.
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

// Posição abstrata do slider (0-100). O backend (Ai::TemperatureMapper) traduz para a temperatura
// real de cada provider — o front nunca manda o número cru de temperatura.
const clampPosition = value => {
  const n = Number(value);
  if (Number.isNaN(n)) return 20;
  return Math.min(100, Math.max(0, Math.round(n)));
};

const hydrate = () => {
  if (props.profile) {
    // profile.routing_strategy É preservado no banco (o pai só toca a coluna quando a chave vem no
    // payload) mas esta tela não lê nem edita mais nenhum campo dele: não existe UI pra roteamento
    // por confiança hoje, só o preset "um modelo por nível" (ver Ai::PythonMigrationAuditor pra
    // contexto de por que o roteamento ao vivo ainda não existe no motor Python).
    const budget = props.profile.budget || {};
    Object.assign(form, blank(), {
      preset: props.profile.tier || 'customizado',
      name: props.profile.name,
      supervisor_provider: props.profile.supervisor_provider,
      supervisor_model: props.profile.supervisor_model,
      temperature_position: props.profile.temperature_position ?? 20,
      budget_usd: budget.monthly_usd ?? '',
      on_limit: budget.on_limit || 'downgrade',
    });
  } else {
    Object.assign(form, blank());
    applyPreset('balanceado');
    form.name = '';
  }
  capture();
};

const doSave = () => {
  emit('save', {
    name: form.name,
    tier: form.preset,
    supervisor_provider: form.supervisor_provider,
    supervisor_model: form.supervisor_model,
    temperature_position: clampPosition(form.temperature_position),
    budget_usd: form.budget_usd,
    on_limit: form.on_limit,
  });
};

onMounted(hydrate);
</script>

<template>
  <div
    class="border border-n-weak rounded-xl p-5 flex flex-col gap-6 bg-n-solid-2"
  >
    <!-- Nível de atendimento: o que o cliente escolhe (resultado, não motor) -->
    <section class="flex flex-col gap-2">
      <div class="flex flex-col gap-0.5">
        <span class="text-sm font-medium text-n-slate-12">{{
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

    <!-- Avançado: o motor (supervisor, roteamento, orçamento) -->
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
        <span class="flex flex-col gap-0.5 min-w-0 font-medium">
          <span class="text-sm text-n-slate-12">
            {{ $t('AI_PROFILES.ADVANCED.TITLE') }}
          </span>
          <span class="text-xs text-n-slate-11 font-normal">
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
          <h3 class="text-base font-semibold text-n-slate-12">
            {{ $t('AI_PROFILES.SUPERVISOR.TITLE') }}
          </h3>
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
          <p class="text-xs text-n-slate-11 mb-0">
            {{ $t('AI_PROFILES.BUDGET.DESCRIPTION') }}
          </p>
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
        @click="$emit('cancel')"
      />
      <Button
        :label="$t('AI_PROFILES.FORM.SAVE')"
        :disabled="!isDirty"
        @click="doSave"
      />
    </div>
  </div>
</template>
