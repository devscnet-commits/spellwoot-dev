<script setup>
/* global axios */
import { ref, reactive, computed, onMounted } from 'vue';
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

const PROVIDERS = ['anthropic', 'openai', 'google', 'openrouter'];
const providerOptions = PROVIDERS.map(p => ({ value: p, label: p }));
const WORKER_KEYS = ['ocr', 'classification', 'summary', 'translation', 'rag'];
const PRESET_KEYS = ['economico', 'balanceado', 'premium', 'customizado'];

// Default operational strategies. Customizado leaves the form as-is for advanced setups.
const PRESETS = {
  economico: {
    name: 'Econômico',
    supervisor: ['openai', 'gpt-4.1-mini'],
    workers: {
      ocr: ['openai', 'gpt-4.1-mini'],
      classification: ['openai', 'gpt-4.1-mini'],
      summary: ['openai', 'gpt-4.1-mini'],
      translation: ['openai', 'gpt-4.1-mini'],
      rag: ['openai', 'text-embedding-3-small'],
    },
    route: [0.9, 0.78],
    cheap: ['openai', 'gpt-4.1-mini'],
    premium: ['openai', 'gpt-4.1-mini'],
    budget: 50,
    on_limit: 'stop',
  },
  balanceado: {
    name: 'Balanceado',
    supervisor: ['openai', 'gpt-4.1-mini'],
    workers: {
      ocr: ['openai', 'gpt-4.1-mini'],
      classification: ['openai', 'gpt-4.1-mini'],
      summary: ['openai', 'gpt-4.1-mini'],
      translation: ['openai', 'gpt-4.1-mini'],
      rag: ['openai', 'text-embedding-3-small'],
    },
    route: [0.95, 0.85],
    cheap: ['openai', 'gpt-4.1-mini'],
    premium: ['openai', 'gpt-4.1'],
    budget: 150,
    on_limit: 'downgrade',
  },
  premium: {
    name: 'Premium',
    supervisor: ['anthropic', 'claude-3-5-sonnet-latest'],
    workers: {
      ocr: ['openai', 'gpt-4.1'],
      classification: ['openai', 'gpt-4.1-mini'],
      summary: ['openai', 'gpt-4.1'],
      translation: ['openai', 'gpt-4.1'],
      rag: ['openai', 'text-embedding-3-large'],
    },
    route: [0.97, 0.88],
    cheap: ['openai', 'gpt-4.1-mini'],
    premium: ['anthropic', 'claude-3-5-sonnet-latest'],
    budget: 500,
    on_limit: 'alert',
  },
  customizado: null,
};

const profiles = ref([]);
const isLoading = ref(false);
const showForm = ref(false);

const emptyWorkers = () =>
  WORKER_KEYS.reduce((acc, k) => {
    acc[k] = { provider: 'openai', model: '' };
    return acc;
  }, {});

const blank = () => ({
  id: null,
  preset: 'balanceado',
  name: '',
  supervisor_provider: 'anthropic',
  supervisor_model: '',
  workers: emptyWorkers(),
  route_high: 0.95,
  route_low: 0.85,
  cheap_provider: 'openai',
  cheap_model: '',
  premium_provider: 'anthropic',
  premium_model: '',
  budget_usd: '',
  on_limit: 'downgrade',
});
const form = reactive(blank());
const { isDirty, capture } = useFormDirty(() => ({ ...form }));

// The whole engine (supervisor/workers/routing/budget) lives behind a single
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
  [form.supervisor_provider, form.supervisor_model] = preset.supervisor;
  WORKER_KEYS.forEach(w => {
    form.workers[w] = {
      provider: preset.workers[w][0],
      model: preset.workers[w][1],
    };
  });
  [form.route_high, form.route_low] = preset.route;
  [form.cheap_provider, form.cheap_model] = preset.cheap;
  [form.premium_provider, form.premium_model] = preset.premium;
  form.budget_usd = preset.budget;
  form.on_limit = preset.on_limit;
};

const profileSubtitle = p => {
  const base = `${p.supervisor_provider} / ${p.supervisor_model}`;
  return p.budget?.monthly_usd
    ? `${base} · $${p.budget.monthly_usd}/mês`
    : base;
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
  const routing = profile.routing_strategy || {};
  const workers = profile.worker_overrides || {};
  const budget = profile.budget || {};
  Object.assign(form, blank(), {
    id: profile.id,
    preset: 'customizado',
    name: profile.name,
    supervisor_provider: profile.supervisor_provider,
    supervisor_model: profile.supervisor_model,
    workers: WORKER_KEYS.reduce((acc, k) => {
      acc[k] = {
        provider: workers[k]?.provider || 'openai',
        model: workers[k]?.model || '',
      };
      return acc;
    }, {}),
    route_high: routing.high_threshold ?? 0.95,
    route_low: routing.low_threshold ?? 0.85,
    cheap_provider: routing.cheap_provider || 'openai',
    cheap_model: routing.cheap_model || '',
    premium_provider: routing.premium_provider || 'anthropic',
    premium_model: routing.premium_model || '',
    budget_usd: budget.monthly_usd ?? '',
    on_limit: budget.on_limit || 'downgrade',
  });
  showForm.value = true;
  capture();
};

const save = async () => {
  const payload = {
    ai_operation_profile: {
      name: form.name,
      supervisor_provider: form.supervisor_provider,
      supervisor_model: form.supervisor_model,
      worker_overrides: form.workers,
      routing_strategy: {
        high_threshold: Number(form.route_high),
        low_threshold: Number(form.route_low),
        cheap_provider: form.cheap_provider,
        cheap_model: form.cheap_model,
        premium_provider: form.premium_provider,
        premium_model: form.premium_model,
      },
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
    useAlert(t('AI_PROFILES.ERROR'));
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
          <div class="flex flex-col gap-1">
            <h1 class="text-xl font-semibold text-n-slate-12">
              {{ $t('AI_PROFILES.TITLE') }}
            </h1>
            <p class="text-sm text-n-slate-11 mb-0">
              {{ $t('AI_PROFILES.DESCRIPTION') }}
            </p>
          </div>
          <Button
            icon="i-lucide-plus"
            :label="$t('AI_PROFILES.NEW')"
            @click="openNew"
          />
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
                  <Input
                    v-model="form.supervisor_model"
                    :label="$t('AI_PROFILES.FORM.MODEL')"
                  />
                </div>
              </div>

              <!-- Workers -->
              <div class="flex flex-col gap-2">
                <div class="flex flex-col gap-0.5">
                  <h3 class="text-sm font-semibold text-n-slate-12">
                    {{ $t('AI_PROFILES.WORKERS.TITLE') }}
                  </h3>
                  <p class="text-xs text-n-slate-11 mb-0">
                    {{ $t('AI_PROFILES.WORKERS.DESCRIPTION') }}
                  </p>
                </div>
                <div
                  v-for="w in WORKER_KEYS"
                  :key="w"
                  class="grid grid-cols-1 sm:grid-cols-[8rem,1fr,1.5fr] gap-2 items-center"
                >
                  <span class="text-sm text-n-slate-12">{{
                    $t(`AI_PROFILES.WORKERS.${w.toUpperCase()}`)
                  }}</span>
                  <Select
                    v-model="form.workers[w].provider"
                    :options="providerOptions"
                  />
                  <Input
                    v-model="form.workers[w].model"
                    :placeholder="$t('AI_PROFILES.FORM.MODEL')"
                  />
                </div>
              </div>

              <!-- Routing -->
              <div class="flex flex-col gap-3">
                <div class="flex flex-col gap-0.5">
                  <h3 class="text-sm font-semibold text-n-slate-12">
                    {{ $t('AI_PROFILES.ROUTING.TITLE') }}
                  </h3>
                  <p class="text-xs text-n-slate-11 mb-0">
                    {{ $t('AI_PROFILES.ROUTING.DESCRIPTION') }}
                  </p>
                </div>
                <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                  <Input
                    v-model="form.route_high"
                    type="number"
                    :label="$t('AI_PROFILES.ROUTING.HIGH')"
                  />
                  <Input
                    v-model="form.route_low"
                    type="number"
                    :label="$t('AI_PROFILES.ROUTING.LOW')"
                  />
                  <div class="flex flex-col gap-1.5">
                    <span class="text-sm font-medium text-n-slate-12">{{
                      $t('AI_PROFILES.ROUTING.CHEAP_PROVIDER')
                    }}</span>
                    <Select
                      v-model="form.cheap_provider"
                      :options="providerOptions"
                    />
                  </div>
                  <Input
                    v-model="form.cheap_model"
                    :label="$t('AI_PROFILES.ROUTING.CHEAP_MODEL')"
                  />
                  <div class="flex flex-col gap-1.5">
                    <span class="text-sm font-medium text-n-slate-12">{{
                      $t('AI_PROFILES.ROUTING.PREMIUM_PROVIDER')
                    }}</span>
                    <Select
                      v-model="form.premium_provider"
                      :options="providerOptions"
                    />
                  </div>
                  <Input
                    v-model="form.premium_model"
                    :label="$t('AI_PROFILES.ROUTING.PREMIUM_MODEL')"
                  />
                </div>
                <div
                  class="text-xs text-n-slate-11 leading-relaxed bg-n-alpha-1 rounded-lg p-3"
                >
                  {{ $t('AI_PROFILES.ROUTING.EXPLAINER') }}
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
