<script setup>
/* global axios */
import { ref, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';
import ConfirmDeleteModal from 'dashboard/components/widgets/modal/ConfirmDeleteModal.vue';
import AiProfileForm from './AiProfileForm.vue';

const route = useRoute();
const { t } = useI18n();

// What each level delivers to the client — cost/speed/quality, never the engine. Mirrored from
// AiProfileForm.vue's LEVEL_EFFECTS (only needed here for the list's subtitle line).
const LEVEL_EFFECTS = {
  economico: { cost: 'LOW', quality: 'MEDIUM' },
  balanceado: { cost: 'MEDIUM', quality: 'HIGH' },
  premium: { cost: 'HIGH', quality: 'MAX' },
  customizado: null,
};

const profiles = ref([]);
const isLoading = ref(false);
// Achado ao vivo (21/08): o form editava/criava num bloco único e SEPARADO no fim da tela — ao editar
// um perfil no meio da lista, nada na tela indicava QUAL linha aquele form pertencia (usuária precisou
// circular a linha manualmente pra explicar). editingId (null = fechado, 'new' = criando, ou o id do
// perfil) faz o AiProfileForm abrir SANFONA logo abaixo da própria linha clicada (ou no fim da lista,
// ao criar) — mesmo padrão de AiStepForm.vue (editingStepIndex).
const editingId = ref(null);

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
  editingId.value = 'new';
};

const openEdit = profile => {
  editingId.value = profile.id;
};

const save = async draft => {
  const payload = {
    ai_operation_profile: {
      name: draft.name,
      tier: draft.tier,
      supervisor_provider: draft.supervisor_provider,
      supervisor_model: draft.supervisor_model,
      temperature_position: draft.temperature_position,
      // worker_overrides E routing_strategy NÃO entram no payload de propósito (nem {} nem um valor
      // parcial): esta tela não edita mais nenhuma chave de worker (OCR/Summary/Tradução/RAG/Juiz de
      // captura removidos — a OpenAI faz Visão e Memória nativamente no path novo) nem de roteamento
      // por confiança (nunca teve UI real — ver docs/ai-operation-profiles-screen-assessment.md §2). O
      // controller só toca essas colunas quando a chave está PRESENTE no payload (Api::V1::Accounts::
      // AiOperationProfilesController#jsonb_params) — omitir preserva o que já está salvo (inclusive
      // chaves sem UI nenhuma, como trivial_gate/native_tools, ou um routing_strategy antigo que uma
      // conta já tinha) em vez de sobrescrever com um hash vazio.
      budget: {
        monthly_usd: Number(draft.budget_usd) || 0,
        on_limit: draft.on_limit,
      },
    },
  };
  try {
    if (editingId.value !== 'new') {
      await axios.patch(`${baseUrl()}/${editingId.value}`, payload);
    } else {
      await axios.post(baseUrl(), payload);
    }
    useAlert(t('AI_PROFILES.SAVED'));
    editingId.value = null;
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
        <div v-else class="flex flex-col gap-2">
          <div
            v-for="profile in profiles"
            :key="profile.id"
            class="rounded-xl border border-n-weak overflow-hidden"
          >
            <div
              class="flex items-center justify-between px-4 py-3 gap-3"
              :class="editingId === profile.id ? 'bg-n-solid-2' : ''"
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
                  :color="editingId === profile.id ? 'blue' : 'slate'"
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
            <!-- Sanfona: abre logo abaixo da PRÓPRIA linha clicada (ver editingId acima) — antes o
                 form vivia num bloco único no fim da tela, sem indicar qual linha estava editando. -->
            <AiProfileForm
              v-if="editingId === profile.id"
              :profile="profile"
              class="border-t border-n-weak bg-n-solid-2"
              @save="save"
              @cancel="editingId = null"
            />
          </div>
        </div>

        <div
          v-if="editingId === 'new'"
          class="rounded-xl border border-n-weak bg-n-solid-2 overflow-hidden"
        >
          <AiProfileForm
            :profile="null"
            @save="save"
            @cancel="editingId = null"
          />
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
