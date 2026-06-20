<script setup>
/* global axios */
import { ref, reactive, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';

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
};

const openEdit = source => {
  Object.assign(form, blank(), source);
  showForm.value = true;
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
  <div class="flex flex-col gap-5">
    <div class="flex flex-col gap-2">
      <span class="text-sm font-medium text-n-slate-12">
        {{ $t('AI_KNOWLEDGE.DOCS_LABEL') }}
      </span>
      <button
        type="button"
        class="rounded-xl border border-dashed border-n-weak bg-n-solid-2 px-4 py-8 flex flex-col items-center gap-2 text-center hover:border-n-slate-7 transition-colors"
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
    </div>

    <div v-if="sources.length" class="flex flex-wrap gap-2">
      <div
        v-for="source in sources"
        :key="source.id"
        class="flex items-center gap-2 rounded-lg border border-n-weak bg-n-solid-1 pl-3 pr-2 py-2 max-w-xs"
      >
        <span class="i-lucide-file-text size-4 text-n-slate-11 shrink-0" />
        <span class="text-sm text-n-slate-12 truncate">
          {{
            source.title ||
            $t(`AI_KNOWLEDGE.KINDS.${source.kind.toUpperCase()}`)
          }}
        </span>
        <button
          type="button"
          class="shrink-0 text-n-slate-11 hover:text-n-slate-12"
          :aria-label="$t('AI_KNOWLEDGE.FORM.EDIT')"
          @click="openEdit(source)"
        >
          <span class="i-lucide-pencil size-3.5 inline-block" />
        </button>
        <button
          type="button"
          class="shrink-0 text-n-slate-11 hover:text-n-ruby-11"
          :aria-label="$t('AI_KNOWLEDGE.FORM.DELETE')"
          @click="remove(source)"
        >
          <span class="i-lucide-trash-2 size-3.5 inline-block" />
        </button>
      </div>
    </div>

    <div
      v-if="showForm"
      class="border border-n-weak rounded-xl p-5 flex flex-col gap-3 bg-n-solid-2"
    >
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <label class="flex flex-col gap-1 text-sm text-n-slate-12">
          {{ $t('AI_KNOWLEDGE.FORM.KIND') }}
          <select
            v-model="form.kind"
            class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
          >
            <option v-for="k in KINDS" :key="k" :value="k">
              {{ $t(`AI_KNOWLEDGE.KINDS.${k.toUpperCase()}`) }}
            </option>
          </select>
        </label>
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
          class="text-sm font-medium px-3 py-2 rounded-lg bg-n-brand text-white"
          @click="save"
        >
          {{ $t('AI_KNOWLEDGE.FORM.SAVE') }}
        </button>
      </div>
    </div>
  </div>
</template>
