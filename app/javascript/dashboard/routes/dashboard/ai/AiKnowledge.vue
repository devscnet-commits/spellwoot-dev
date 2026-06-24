<script setup>
/* global axios */
import { ref, reactive, computed, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import ConfirmDeleteModal from 'dashboard/components/widgets/modal/ConfirmDeleteModal.vue';
import { useFormDirty } from 'dashboard/composables/useFormDirty';

const route = useRoute();
const { t } = useI18n();

// A document-like icon per knowledge kind so the list reads as a knowledge base, not a CRUD table.
const KIND_ICONS = {
  faq: 'i-lucide-help-circle',
  produto: 'i-lucide-package',
  promocao: 'i-lucide-tag',
  procedimento: 'i-lucide-list-checks',
  documento: 'i-lucide-file-text',
  website: 'i-lucide-globe',
};
const kindIcon = kind => KIND_ICONS[kind] || 'i-lucide-file-text';
const kindLabel = kind =>
  t(`AI_KNOWLEDGE.KINDS.${(kind || 'documento').toUpperCase()}`);

// The user teaches the company by business source, never by "type". These work today as plain
// text. Documentos (upload) and Site (import) need backend, so they show as "em breve".
const CREATABLE = [
  { kind: 'faq', icon: 'i-lucide-help-circle' },
  { kind: 'produto', icon: 'i-lucide-package' },
  { kind: 'procedimento', icon: 'i-lucide-list-checks' },
];
const COMING_SOON = [
  { key: 'DOCUMENTOS', icon: 'i-lucide-file-text' },
  { key: 'SITE', icon: 'i-lucide-globe' },
];

const sources = ref([]);
const isLoading = ref(false);
const showForm = ref(false);

const blank = () => ({
  id: null,
  kind: 'faq',
  title: '',
  raw: '',
  status: 'active',
});
const form = reactive(blank());
const { isDirty, capture } = useFormDirty(() => ({ ...form }));

// Field labels adapt to the source (FAQ = Pergunta/Resposta, etc.) — no backend change.
const FIELD_LABELS = {
  faq: { title: 'FAQ_QUESTION', raw: 'FAQ_ANSWER' },
  produto: { title: 'PRODUCT_NAME', raw: 'PRODUCT_DESC' },
  procedimento: { title: 'PROC_TITLE', raw: 'PROC_STEPS' },
};
const titleLabel = computed(() =>
  t(`AI_KNOWLEDGE.FORM.${FIELD_LABELS[form.kind]?.title || 'TITLE'}`)
);
const rawLabel = computed(() =>
  t(`AI_KNOWLEDGE.FORM.${FIELD_LABELS[form.kind]?.raw || 'RAW'}`)
);

const baseUrl = () =>
  `/api/v1/accounts/${route.params.accountId}/ai_knowledge_sources`;

const fetchSources = async () => {
  isLoading.value = true;
  try {
    const { data } = await axios.get(baseUrl());
    sources.value = Array.isArray(data) ? data : [];
  } finally {
    isLoading.value = false;
  }
};

const openNew = kind => {
  Object.assign(form, blank(), { kind });
  showForm.value = true;
  capture();
};

const openEdit = source => {
  Object.assign(form, blank(), source);
  showForm.value = true;
  capture();
};

const save = async () => {
  const payload = {
    ai_knowledge_source: {
      kind: form.kind,
      title: form.title,
      raw: form.raw,
      status: form.status,
    },
  };
  try {
    if (form.id) {
      await axios.patch(`${baseUrl()}/${form.id}`, payload);
    } else {
      await axios.post(baseUrl(), payload);
    }
    useAlert(t('AI_KNOWLEDGE.SAVED'));
    showForm.value = false;
    fetchSources();
  } catch (error) {
    useAlert(t('AI_KNOWLEDGE.ERROR'));
  }
};

const deleteTarget = ref(null);
const sourceName = source =>
  source ? source.title || kindLabel(source.kind) : '';
const confirmRemove = async () => {
  try {
    await axios.delete(`${baseUrl()}/${deleteTarget.value.id}`);
    useAlert(t('AI_KNOWLEDGE.DELETED'));
    deleteTarget.value = null;
    fetchSources();
  } catch (error) {
    useAlert(t('AI_KNOWLEDGE.ERROR'));
  }
};

onMounted(fetchSources);
</script>

<template>
  <div class="w-full h-full overflow-auto bg-n-background p-4 sm:p-6">
    <div class="max-w-4xl mx-auto flex flex-col gap-3">
      <div class="flex flex-col gap-1">
        <h1 class="text-xl font-semibold text-n-slate-12">
          {{ $t('AI_KNOWLEDGE.TITLE') }}
        </h1>
        <p class="text-sm text-n-slate-11 mb-0">
          {{ $t('AI_KNOWLEDGE.DESCRIPTION') }}
        </p>
      </div>
      <section
        class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-4"
      >
        <div class="flex flex-col gap-2">
          <span class="text-xs font-medium text-n-slate-11">
            {{ $t('AI_KNOWLEDGE.SOURCES.LABEL') }}
          </span>
          <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-2">
            <button
              v-for="src in CREATABLE"
              :key="src.kind"
              type="button"
              class="rounded-xl border border-n-weak bg-n-solid-1 p-3 flex flex-col items-center gap-1 text-center hover:border-n-brand transition-colors"
              @click="openNew(src.kind)"
            >
              <span :class="src.icon" class="size-5 text-n-brand" />
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t(`AI_KNOWLEDGE.SOURCES.${src.kind.toUpperCase()}`) }}
              </span>
              <span class="text-xs text-n-slate-10">
                {{ $t(`AI_KNOWLEDGE.SOURCES.${src.kind.toUpperCase()}_HINT`) }}
              </span>
            </button>
            <div
              v-for="src in COMING_SOON"
              :key="src.key"
              class="rounded-xl border border-dashed border-n-weak bg-n-alpha-1 p-3 flex flex-col items-center gap-1 text-center opacity-70"
            >
              <span :class="src.icon" class="size-5 text-n-slate-10" />
              <span class="text-sm font-medium text-n-slate-11">
                {{ $t(`AI_KNOWLEDGE.SOURCES.${src.key}`) }}
              </span>
              <span
                class="inline-flex items-center gap-1 text-xs text-n-slate-10"
              >
                <span class="i-lucide-clock size-3" />
                {{ $t('AI_KNOWLEDGE.SOURCES.SOON') }}
              </span>
            </div>
          </div>
        </div>

        <div
          v-if="sources.length"
          class="grid grid-cols-1 sm:grid-cols-2 gap-3"
        >
          <div
            v-for="source in sources"
            :key="source.id"
            class="group rounded-xl border border-n-weak bg-n-solid-1 p-4 flex flex-col gap-2"
          >
            <div class="flex items-start justify-between gap-2">
              <span
                class="shrink-0 size-9 rounded-lg bg-n-brand/10 text-n-brand flex items-center justify-center"
              >
                <span :class="kindIcon(source.kind)" class="size-5" />
              </span>
              <div
                class="shrink-0 flex items-center gap-1 text-n-slate-11 opacity-0 group-hover:opacity-100 transition-opacity"
              >
                <button
                  type="button"
                  class="hover:text-n-slate-12"
                  :aria-label="$t('AI_KNOWLEDGE.FORM.EDIT')"
                  @click="openEdit(source)"
                >
                  <span class="i-lucide-pencil size-4 inline-block" />
                </button>
                <button
                  type="button"
                  class="hover:text-n-ruby-11"
                  :aria-label="$t('AI_KNOWLEDGE.FORM.DELETE')"
                  @click="deleteTarget = source"
                >
                  <span class="i-lucide-trash-2 size-4 inline-block" />
                </button>
              </div>
            </div>
            <div class="min-w-0">
              <p class="text-sm font-medium text-n-slate-12 mb-0 truncate">
                {{ source.title || kindLabel(source.kind) }}
              </p>
              <p
                v-if="source.raw"
                class="text-xs text-n-slate-11 mb-0 line-clamp-2"
              >
                {{ source.raw }}
              </p>
            </div>
            <span
              class="self-start inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-n-alpha-2 text-xs text-n-slate-11"
            >
              <span :class="kindIcon(source.kind)" class="size-3" />
              {{ kindLabel(source.kind) }}
            </span>
          </div>
        </div>

        <div
          v-if="showForm"
          class="border border-n-weak rounded-xl p-5 flex flex-col gap-3 bg-n-solid-1"
        >
          <h3
            class="text-sm font-semibold text-n-slate-12 mb-0 flex items-center gap-2"
          >
            <span :class="kindIcon(form.kind)" class="size-4 text-n-brand" />
            {{ kindLabel(form.kind) }}
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
              rows="8"
              class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-none"
            />
          </label>
          <div class="flex justify-end gap-2">
            <button
              type="button"
              class="text-sm px-3 py-2 rounded-lg bg-n-alpha-2 text-n-slate-12"
              @click="showForm = false"
            >
              {{ $t('AI_KNOWLEDGE.FORM.CANCEL') }}
            </button>
            <button
              type="button"
              :disabled="!isDirty"
              class="text-sm font-medium px-3 py-2 rounded-lg bg-n-brand text-white disabled:opacity-50 disabled:cursor-not-allowed"
              @click="save"
            >
              {{ $t('AI_KNOWLEDGE.FORM.SAVE') }}
            </button>
          </div>
        </div>

        <ConfirmDeleteModal
          v-if="deleteTarget"
          show
          :title="$t('AI_KNOWLEDGE.DELETE_MODAL.TITLE')"
          :message="
            $t('AI_KNOWLEDGE.DELETE_MODAL.MESSAGE', {
              name: sourceName(deleteTarget),
            })
          "
          :confirm-text="$t('AI_KNOWLEDGE.DELETE_MODAL.CONFIRM')"
          :reject-text="$t('AI_KNOWLEDGE.DELETE_MODAL.CANCEL')"
          :confirm-value="sourceName(deleteTarget)"
          :confirm-place-holder-text="
            $t('AI_KNOWLEDGE.DELETE_MODAL.PLACEHOLDER', {
              name: sourceName(deleteTarget),
            })
          "
          @on-confirm="confirmRemove"
          @on-close="deleteTarget = null"
        />
      </section>
    </div>
  </div>
</template>
