<script setup>
/* global axios */
import { ref, reactive, computed, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import Select from 'dashboard/components-next/select/Select.vue';
import { useFormDirty } from 'dashboard/composables/useFormDirty';

const props = defineProps({
  // Optional overrides so this view can be embedded inside the agent (default department).
  agentId: { type: [String, Number], default: null },
  departmentId: { type: [String, Number], default: null },
});

const route = useRoute();
const { t } = useI18n();

const KINDS = [
  'faq',
  'produto',
  'promocao',
  'procedimento',
  'documento',
  'website',
];

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
const kindOptions = computed(() =>
  KINDS.map(k => ({ value: k, label: kindLabel(k) }))
);

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

const baseUrl = () => {
  const accountId = route.params.accountId;
  const agentId = props.agentId || route.params.agentId;
  const departmentId = props.departmentId || route.params.departmentId;
  return `/api/v1/accounts/${accountId}/ai_agents/${agentId}/ai_departments/${departmentId}/ai_knowledge_sources`;
};

const fetchSources = async () => {
  isLoading.value = true;
  try {
    const { data } = await axios.get(baseUrl());
    sources.value = Array.isArray(data) ? data : [];
  } finally {
    isLoading.value = false;
  }
};

const openNew = () => {
  Object.assign(form, blank());
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

const remove = async source => {
  // eslint-disable-next-line no-alert
  if (!window.confirm(t('AI_KNOWLEDGE.CONFIRM_DELETE'))) return;
  try {
    await axios.delete(`${baseUrl()}/${source.id}`);
    useAlert(t('AI_KNOWLEDGE.DELETED'));
    fetchSources();
  } catch (error) {
    useAlert(t('AI_KNOWLEDGE.ERROR'));
  }
};

onMounted(fetchSources);
</script>

<template>
  <section
    class="rounded-xl border border-n-weak bg-n-solid-2 p-5 flex flex-col gap-4"
  >
    <div class="flex flex-col gap-0.5">
      <h2 class="text-base font-semibold text-n-slate-12 mb-0">
        {{ $t('AI_KNOWLEDGE.DOCS_LABEL') }}
      </h2>
      <p class="text-xs text-n-slate-11 mb-0">
        {{ $t('AI_KNOWLEDGE.DOCS_HINT') }}
      </p>
    </div>

    <button
      type="button"
      class="rounded-xl border border-dashed border-n-weak bg-n-solid-1 px-4 py-6 flex flex-col items-center gap-2 text-center hover:border-n-brand transition-colors"
      @click="openNew"
    >
      <span class="i-lucide-upload size-6 text-n-brand" />
      <p class="text-sm text-n-slate-11 mb-0">
        {{ $t('AI_KNOWLEDGE.UPLOAD_HINT') }}
      </p>
      <p class="text-xs text-n-slate-10 mb-0">
        {{ $t('AI_KNOWLEDGE.UPLOAD_SUB') }}
      </p>
    </button>

    <div v-if="sources.length" class="grid grid-cols-1 sm:grid-cols-2 gap-3">
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
              @click="remove(source)"
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
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div class="flex flex-col gap-1 text-sm text-n-slate-12">
          <span>{{ $t('AI_KNOWLEDGE.FORM.KIND') }}</span>
          <Select v-model="form.kind" :options="kindOptions" />
        </div>
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_KNOWLEDGE.FORM.TITLE') }}
          <input
            v-model="form.title"
            type="text"
            class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
          />
        </label>
      </div>
      <label class="flex flex-col gap-1 text-sm text-n-slate-12">
        {{ $t('AI_KNOWLEDGE.FORM.RAW') }}
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
  </section>
</template>
