<script setup>
/* global axios */
import { ref, reactive, computed, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import { useFormDirty } from 'dashboard/composables/useFormDirty';
import KnowledgeSourceForm from './KnowledgeSourceForm.vue';
import Select from 'dashboard/components-next/select/Select.vue';
import {
  scopeOptionLabel,
  sourceScope,
  buildScopeChips,
} from './knowledgeScope';

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
// Os cards do topo selecionam o tipo (kind) que dirige tanto o import quanto o "adicionar manual".
const CREATABLE = [
  { kind: 'faq', icon: 'i-lucide-help-circle' },
  { kind: 'produto', icon: 'i-lucide-package' },
  { kind: 'procedimento', icon: 'i-lucide-list-checks' },
  { kind: 'documento', icon: 'i-lucide-file-text' },
];

const sources = ref([]);
const departments = ref([]); // opções do seletor de escopo (departamentos da conta)
const isLoading = ref(false);
const showForm = ref(false); // formulário de criação (acima da lista)
const editingId = ref(null); // id da fonte em edição inline (no próprio card)

const blank = () => ({
  id: null,
  kind: 'faq',
  title: '',
  raw: '',
  price: '',
  status: 'active',
  ai_department_id: null,
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

const fetchDepartments = async () => {
  try {
    const { data } = await axios.get(`${baseUrl()}/departments`);
    departments.value = Array.isArray(data) ? data : [];
  } catch (error) {
    departments.value = [];
  }
};

// Escopo do PRÓXIMO import (CSV/website/documento). '' = compartilhado (ai_department_id nil).
const importDepartmentId = ref('');
const importDepartmentOptions = computed(() => [
  { value: '', label: t('AI_KNOWLEDGE.FORM.DEPARTMENT_ALL') },
  ...departments.value.map(d => ({
    value: String(d.id),
    label: scopeOptionLabel(d),
  })),
]);
const importDeptId = () =>
  importDepartmentId.value ? Number(importDepartmentId.value) : null;

// Badge de escopo do card: compartilhado (neutro), restrito a um agente (marca) ou órfão (aviso —
// aponta para um department que não existe mais). Ver sourceScope em ./knowledgeScope.
const scopeBadge = source => {
  const scope = sourceScope(source, departments.value);
  if (scope.status === 'scoped') {
    return {
      text: scope.label,
      icon: 'i-lucide-layers',
      class: 'bg-n-brand/10 text-n-brand',
    };
  }
  if (scope.status === 'orphan') {
    return {
      text: t('AI_KNOWLEDGE.ORPHAN'),
      icon: 'i-lucide-alert-triangle',
      class: 'bg-n-amber-3 text-n-amber-11',
    };
  }
  return {
    text: t('AI_KNOWLEDGE.SHARED'),
    icon: 'i-lucide-layers',
    class: 'bg-n-alpha-2 text-n-slate-11',
  };
};

// Documentos: drag-and-drop or click to upload a TXT/CSV file; the backend extracts its text.
const fileInput = ref(null);
const dragActive = ref(false);
const triggerUpload = () => fileInput.value?.click();
const uploadFile = async file => {
  if (!file) return;
  const fd = new FormData();
  fd.append('file', file);
  if (importDeptId() != null) fd.append('ai_department_id', importDeptId());
  try {
    await axios.post(baseUrl(), fd);
    useAlert(t('AI_KNOWLEDGE.SAVED'));
    fetchSources();
  } catch (error) {
    useAlert(error.response?.data?.errors?.[0] || t('AI_KNOWLEDGE.ERROR'));
  }
};
// Importar como: estruturados (CSV -> N entradas) ou Documento (arquivo único).
const importKind = ref('faq');
const IMPORT_COLUMNS = {
  faq: ['pergunta', 'resposta'],
  produto: ['nome', 'descricao', 'preco'],
  procedimento: ['titulo', 'passos'],
};

// Parser CSV minimalista (aspas, vírgula dentro de aspas, \n e \r\n).
const parseCsv = text => {
  const rows = [];
  let row = [];
  let field = '';
  let quoted = false;
  const endField = () => {
    row.push(field);
    field = '';
  };
  const endRow = () => {
    endField();
    rows.push(row);
    row = [];
  };
  for (let i = 0; i < text.length; i += 1) {
    const c = text[i];
    if (quoted) {
      if (c === '"' && text[i + 1] === '"') {
        field += '"';
        i += 1;
      } else if (c === '"') quoted = false;
      else field += c;
    } else if (c === '"') quoted = true;
    else if (c === ',') endField();
    else if (c === '\n') endRow();
    else if (c !== '\r') field += c;
  }
  if (field.length || row.length) endRow();
  return rows.filter(r => r.some(cell => cell.trim() !== ''));
};

// Linhas -> fontes de conhecimento conforme o tipo (pula cabeçalho se reconhecido).
const rowsToSources = (rows, kind) => {
  const cols = IMPORT_COLUMNS[kind] || IMPORT_COLUMNS.faq;
  const first = (rows[0] || []).map(c => c.trim().toLowerCase());
  const data = cols.every((c, i) => (first[i] || '').includes(c))
    ? rows.slice(1)
    : rows;
  return data
    .map(r => {
      const title = (r[0] || '').trim();
      if (!title) return null;
      const src = {
        kind,
        title,
        raw: (r[1] || '').trim(),
        status: 'active',
        ai_department_id: importDeptId(),
      };
      if (kind === 'produto') src.price = (r[2] || '').trim();
      return src;
    })
    .filter(Boolean);
};

// Lê o arquivo respeitando acentuação: tenta UTF-8 e, se vier caractere de
// substituição (�), reinterpreta como Windows-1252/ISO-8859-1 (padrão do Excel no BR).
const decodeFileText = async file => {
  const bytes = new Uint8Array(await file.arrayBuffer());
  const utf8 = new TextDecoder('utf-8').decode(bytes);
  return utf8.includes('�')
    ? new TextDecoder('windows-1252').decode(bytes)
    : utf8;
};

const importCsv = async file => {
  const text = await decodeFileText(file);
  const entries = rowsToSources(parseCsv(text), importKind.value);
  if (!entries.length) {
    useAlert(t('AI_KNOWLEDGE.IMPORT_EMPTY'));
    return;
  }
  try {
    await Promise.all(
      entries.map(src => axios.post(baseUrl(), { ai_knowledge_source: src }))
    );
    useAlert(t('AI_KNOWLEDGE.IMPORTED', { count: entries.length }));
    fetchSources();
  } catch (error) {
    useAlert(error.response?.data?.errors?.[0] || t('AI_KNOWLEDGE.ERROR'));
  }
};

const handleFile = file => {
  if (!file) return;
  if (importKind.value === 'documento') uploadFile(file);
  else importCsv(file);
};
const onFilePick = e => {
  const file = e.target.files?.[0];
  e.target.value = '';
  handleFile(file);
};
const onDrop = e => {
  dragActive.value = false;
  handleFile(e.dataTransfer?.files?.[0]);
};

// Baixa um CSV modelo (cabeçalho + 1 exemplo) do tipo selecionado.
const IMPORT_EXAMPLES = {
  faq: ['Qual o horário de atendimento?', 'Seg a sex, das 8h às 18h.'],
  produto: ['Plano Pro', 'Plano completo com suporte', 'R$ 99/mês'],
  procedimento: [
    'Troca de produto',
    '1. Solicite no app; 2. Envie o item; 3. Receba o novo',
  ],
};
const downloadModel = () => {
  const kind = importKind.value;
  if (kind === 'documento') return;
  const csv = `${IMPORT_COLUMNS[kind].join(',')}\n${IMPORT_EXAMPLES[kind]
    .map(v => `"${v}"`)
    .join(',')}\n`;
  // BOM UTF-8 para o Excel abrir os acentos corretamente (e devolver UTF-8 ao reimportar).
  const blob = new Blob(['﻿', csv], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = `modelo-${kind}.csv`;
  link.click();
  URL.revokeObjectURL(url);
};

// Website: cadastra a URL como fonte de conhecimento. A extração/crawl do conteúdo
// da página fica pendente no backend (por ora guarda a URL).
const websiteUrl = ref('');
const addWebsite = async () => {
  const url = websiteUrl.value.trim();
  if (!url) return;
  try {
    await axios.post(baseUrl(), {
      ai_knowledge_source: {
        kind: 'website',
        title: url,
        raw: url,
        status: 'active',
        ai_department_id: importDeptId(),
      },
    });
    useAlert(t('AI_KNOWLEDGE.SAVED'));
    websiteUrl.value = '';
    fetchSources();
  } catch (error) {
    useAlert(error.response?.data?.errors?.[0] || t('AI_KNOWLEDGE.ERROR'));
  }
};

const openNew = kind => {
  Object.assign(form, blank(), { kind });
  editingId.value = null;
  showForm.value = true;
  capture();
};

const openEdit = source => {
  Object.assign(form, blank(), source);
  showForm.value = false;
  editingId.value = source.id; // edita no próprio card
  capture();
};

const closeForm = () => {
  showForm.value = false;
  editingId.value = null;
};

const save = async () => {
  const payload = {
    ai_knowledge_source: {
      kind: form.kind,
      title: form.title,
      raw: form.raw,
      price: form.kind === 'produto' ? form.price : '',
      status: form.status,
      ai_department_id: form.ai_department_id || null,
    },
  };
  try {
    if (form.id) {
      await axios.patch(`${baseUrl()}/${form.id}`, payload);
    } else {
      await axios.post(baseUrl(), payload);
    }
    useAlert(t('AI_KNOWLEDGE.SAVED'));
    closeForm();
    fetchSources();
  } catch (error) {
    useAlert(t('AI_KNOWLEDGE.ERROR'));
  }
};

// Filtro client-side da listagem (escopo + tipo). Dataset pequeno → filtra o array já carregado,
// sem ida ao backend. Escopo: 'all' | 'shared' | 'orphan' | '<deptId>'. Tipo: 'all' | kind.
const scopeFilter = ref('all');
const kindFilter = ref('all');

const isOrphan = source =>
  source.ai_department_id != null &&
  !departments.value.some(d => d.id === source.ai_department_id);

// Chips de escopo: Todos + Compartilhado + TODOS os agentes da conta (mesma lista do dropdown de
// criação, não só os presentes nas fontes) + "Fonte órfã" quando houver. Cada chip traz a contagem
// (0 inclusive). Ver buildScopeChips em ./knowledgeScope.
const scopeChips = computed(() =>
  buildScopeChips(departments.value, sources.value, {
    all: t('AI_KNOWLEDGE.FILTER.SCOPE_ALL'),
    shared: t('AI_KNOWLEDGE.SHARED'),
    orphan: t('AI_KNOWLEDGE.ORPHAN'),
  })
);

// Dropdown de tipo: Todos + tipos presentes nas fontes.
const kindFilterOptions = computed(() => [
  { value: 'all', label: t('AI_KNOWLEDGE.FILTER.KIND_ALL') },
  ...[...new Set(sources.value.map(s => s.kind))].map(k => ({
    value: k,
    label: kindLabel(k),
  })),
]);

const matchesScope = source => {
  if (scopeFilter.value === 'all') return true;
  if (scopeFilter.value === 'shared') return source.ai_department_id == null;
  if (scopeFilter.value === 'orphan') return isOrphan(source);
  return String(source.ai_department_id) === scopeFilter.value;
};
const filteredSources = computed(() =>
  sources.value.filter(
    s =>
      matchesScope(s) &&
      (kindFilter.value === 'all' || s.kind === kindFilter.value)
  )
);

// Seleção em massa: marcar vários e excluir de uma vez (sem digitar o texto a cada item).
const selectedIds = ref([]);
const isSelected = id => selectedIds.value.includes(id);
const toggleSelect = id => {
  const i = selectedIds.value.indexOf(id);
  if (i >= 0) selectedIds.value.splice(i, 1);
  else selectedIds.value.push(id);
};
const clearSelection = () => {
  selectedIds.value = [];
};
const allSelected = computed(
  () =>
    filteredSources.value.length > 0 &&
    filteredSources.value.every(s => selectedIds.value.includes(s.id))
);
const toggleSelectAll = () => {
  selectedIds.value = allSelected.value
    ? []
    : filteredSources.value.map(s => s.id);
};

// Exclusão padronizada (individual E lote) no MESMO modal simples — sem digitar o nome do item.
// `deleteTargets` guarda as sources a excluir: 1 = individual (via card), >1 = lote (via seleção).
// [] = fechado. Um único componente evita a inconsistência de dois modais separados voltar a surgir.
const deleteTargets = ref([]);
const sourceName = source =>
  source ? source.title || kindLabel(source.kind) : '';
const deleteCount = computed(() => deleteTargets.value.length);
const deleteModalOpen = computed({
  get: () => deleteCount.value > 0,
  set: open => {
    if (!open) deleteTargets.value = [];
  },
});
const deleteTitle = computed(() =>
  deleteCount.value > 1
    ? t('AI_KNOWLEDGE.BULK.CONFIRM_TITLE')
    : t('AI_KNOWLEDGE.DELETE_MODAL.TITLE')
);
const deleteMessage = computed(() =>
  deleteCount.value > 1
    ? t('AI_KNOWLEDGE.BULK.CONFIRM_MESSAGE', { count: deleteCount.value })
    : t('AI_KNOWLEDGE.DELETE_MODAL.MESSAGE', {
        name: sourceName(deleteTargets.value[0]),
      })
);
const askDeleteSingle = source => {
  deleteTargets.value = [source];
};
const askDeleteBulk = () => {
  deleteTargets.value = sources.value.filter(s =>
    selectedIds.value.includes(s.id)
  );
};
const closeDelete = () => {
  deleteTargets.value = [];
};
const confirmDelete = async () => {
  const ids = deleteTargets.value.map(s => s.id);
  try {
    await Promise.all(ids.map(id => axios.delete(`${baseUrl()}/${id}`)));
    useAlert(
      ids.length > 1
        ? t('AI_KNOWLEDGE.BULK.DELETED', { count: ids.length })
        : t('AI_KNOWLEDGE.DELETED')
    );
  } catch (error) {
    useAlert(t('AI_KNOWLEDGE.ERROR'));
  } finally {
    deleteTargets.value = [];
    clearSelection();
    fetchSources();
  }
};

onMounted(() => {
  fetchSources();
  fetchDepartments();
});
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
        <!-- O que você quer ensinar? — seleciona o tipo que vai importar/adicionar -->
        <div class="flex flex-col gap-2">
          <span class="text-xs font-medium text-n-slate-11">
            {{ $t('AI_KNOWLEDGE.SOURCES.LABEL') }}
          </span>
          <div class="grid grid-cols-2 sm:grid-cols-4 gap-2">
            <button
              v-for="src in CREATABLE"
              :key="src.kind"
              type="button"
              class="rounded-xl border p-3 flex flex-col items-center gap-1 text-center transition-colors"
              :class="
                importKind === src.kind
                  ? 'border-n-brand bg-n-brand/10'
                  : 'border-n-weak bg-n-solid-1 hover:border-n-slate-7'
              "
              @click="importKind = src.kind"
            >
              <span :class="src.icon" class="size-5 text-n-brand" />
              <span class="text-sm font-medium text-n-slate-12">
                {{ $t(`AI_KNOWLEDGE.SOURCES.${src.kind.toUpperCase()}`) }}
              </span>
              <span class="text-xs text-n-slate-10">
                {{ $t(`AI_KNOWLEDGE.SOURCES.${src.kind.toUpperCase()}_HINT`) }}
              </span>
            </button>
          </div>
        </div>

        <!-- Escopo: para qual departamento este import vai (ou compartilhado) -->
        <div class="flex flex-col gap-1.5 max-w-sm">
          <span class="text-xs font-medium text-n-slate-11">
            {{ $t('AI_KNOWLEDGE.FORM.DEPARTMENT') }}
          </span>
          <Select
            v-model="importDepartmentId"
            :options="importDepartmentOptions"
          />
          <span class="text-xs text-n-slate-10">
            {{ $t('AI_KNOWLEDGE.FORM.DEPARTMENT_HINT') }}
          </span>
        </div>

        <!-- Importar/adicionar para o tipo selecionado acima -->
        <div class="flex flex-col gap-2">
          <input
            ref="fileInput"
            type="file"
            accept=".txt,.csv"
            class="hidden"
            @change="onFilePick"
          />
          <button
            type="button"
            class="rounded-2xl border-2 border-dashed p-8 flex flex-col items-center gap-2 text-center transition-colors"
            :class="
              dragActive
                ? 'border-n-brand bg-n-brand/5'
                : 'border-n-weak bg-n-alpha-1 hover:border-n-slate-7'
            "
            @click="triggerUpload"
            @dragover.prevent="dragActive = true"
            @dragleave.prevent="dragActive = false"
            @drop.prevent="onDrop"
          >
            <span class="i-lucide-upload size-7 text-n-brand" />
            <span class="text-sm text-n-slate-11 max-w-md">
              {{
                importKind === 'documento'
                  ? $t('AI_KNOWLEDGE.DROPZONE.HINT_DOC')
                  : $t('AI_KNOWLEDGE.DROPZONE.HINT')
              }}
            </span>
            <span class="text-xs text-n-brand">
              {{ $t('AI_KNOWLEDGE.DROPZONE.FORMATS') }}
            </span>
          </button>
          <!-- Formato esperado + modelo + adicionar manual (só nos tipos estruturados) -->
          <div
            v-if="importKind !== 'documento'"
            class="flex items-center justify-between gap-3 flex-wrap"
          >
            <span class="text-xs text-n-slate-11">
              {{ $t(`AI_KNOWLEDGE.IMPORT_FORMAT.${importKind.toUpperCase()}`) }}
            </span>
            <div class="shrink-0 flex items-center gap-3">
              <button
                type="button"
                class="text-xs font-medium text-n-brand hover:underline"
                @click="openNew(importKind)"
              >
                {{ $t('AI_KNOWLEDGE.ADD_MANUAL') }}
              </button>
              <button
                type="button"
                class="text-xs font-medium text-n-brand hover:underline"
                @click="downloadModel"
              >
                {{ $t('AI_KNOWLEDGE.DOWNLOAD_MODEL') }}
              </button>
            </div>
          </div>
        </div>

        <!-- Website: importar páginas (em breve) -->
        <div class="flex flex-col gap-1.5">
          <span
            class="inline-flex items-center gap-1.5 text-sm font-medium text-n-slate-12"
          >
            <span class="i-lucide-globe size-4" />
            {{ $t('AI_KNOWLEDGE.SOURCES.SITE') }}
          </span>
          <div class="flex items-stretch gap-2">
            <input
              v-model="websiteUrl"
              type="url"
              :placeholder="$t('AI_KNOWLEDGE.WEBSITE_PLACEHOLDER')"
              class="flex-1 h-10 px-3 rounded-lg border border-n-weak bg-n-solid-1 text-sm"
              @keyup.enter="addWebsite"
            />
            <button
              type="button"
              :disabled="!websiteUrl.trim()"
              class="shrink-0 h-10 text-sm font-medium px-4 rounded-lg bg-n-brand text-white disabled:opacity-50 disabled:cursor-not-allowed"
              @click="addWebsite"
            >
              {{ $t('AI_KNOWLEDGE.SITE_ADD') }}
            </button>
          </div>
          <span class="text-xs text-n-slate-11">
            {{ $t('AI_KNOWLEDGE.SITE_HINT') }}
          </span>
        </div>

        <!-- Criação: aparece no topo da lista (sem rolar) -->
        <KnowledgeSourceForm
          v-if="showForm"
          v-model:form="form"
          :title-label="titleLabel"
          :raw-label="rawLabel"
          :heading-label="kindLabel(form.kind)"
          :heading-icon="kindIcon(form.kind)"
          :disable-save="!isDirty"
          :departments="departments"
          @save="save"
          @cancel="closeForm"
        />

        <!-- Filtro da biblioteca: escopo (compartilhado / por agente / órfã) + tipo -->
        <div
          v-if="sources.length"
          class="flex items-center justify-between gap-3 flex-wrap"
        >
          <div class="flex items-center gap-1.5 flex-wrap">
            <button
              v-for="chip in scopeChips"
              :key="chip.value"
              type="button"
              class="text-xs font-medium px-3 py-1.5 rounded-full border transition-colors"
              :class="
                scopeFilter === chip.value
                  ? 'border-n-brand bg-n-brand/10 text-n-brand'
                  : 'border-n-weak bg-n-solid-1 text-n-slate-11 hover:border-n-slate-7'
              "
              @click="scopeFilter = chip.value"
            >
              {{ chip.label }}
              <span class="ml-1 tabular-nums opacity-60">{{ chip.count }}</span>
            </button>
          </div>
          <div class="shrink-0 flex items-center gap-2">
            <span class="text-xs text-n-slate-11">
              {{ $t('AI_KNOWLEDGE.FILTER.KIND_LABEL') }}
            </span>
            <Select
              v-model="kindFilter"
              :options="kindFilterOptions"
              class="min-w-36"
            />
          </div>
        </div>

        <!-- Seleção em massa -->
        <div
          v-if="filteredSources.length"
          class="flex items-center justify-between gap-3 flex-wrap"
        >
          <label
            class="inline-flex items-center gap-2 text-sm text-n-slate-11 cursor-pointer"
          >
            <input
              type="checkbox"
              :checked="allSelected"
              class="size-4 cursor-pointer"
              @change="toggleSelectAll"
            />
            {{ $t('AI_KNOWLEDGE.BULK.SELECT_ALL') }}
          </label>
          <div v-if="selectedIds.length" class="flex items-center gap-3">
            <span class="text-xs text-n-slate-11">
              {{
                $t('AI_KNOWLEDGE.BULK.SELECTED', { count: selectedIds.length })
              }}
            </span>
            <button
              type="button"
              class="inline-flex items-center gap-1.5 text-sm font-medium px-3 py-1.5 rounded-lg bg-n-ruby-9 text-white hover:bg-n-ruby-10"
              @click="askDeleteBulk"
            >
              <span class="i-lucide-trash-2 size-4" />
              {{ $t('AI_KNOWLEDGE.BULK.DELETE') }}
            </button>
          </div>
        </div>

        <!-- Nenhuma fonte no filtro atual (mas existem fontes) -->
        <p
          v-if="sources.length && !filteredSources.length"
          class="text-sm text-n-slate-11 text-center py-6 mb-0"
        >
          {{ $t('AI_KNOWLEDGE.FILTER.EMPTY') }}
        </p>

        <div
          v-if="filteredSources.length"
          class="grid grid-cols-1 sm:grid-cols-2 gap-3"
        >
          <template v-for="source in filteredSources" :key="source.id">
            <!-- Edição no próprio lugar do card -->
            <KnowledgeSourceForm
              v-if="editingId === source.id"
              v-model:form="form"
              class="sm:col-span-2"
              :title-label="titleLabel"
              :raw-label="rawLabel"
              :heading-label="kindLabel(form.kind)"
              :heading-icon="kindIcon(form.kind)"
              :disable-save="!isDirty"
              :departments="departments"
              @save="save"
              @cancel="closeForm"
            />
            <div
              v-else
              class="group rounded-xl border bg-n-solid-1 p-4 flex flex-col gap-2"
              :class="
                isSelected(source.id) ? 'border-n-brand' : 'border-n-weak'
              "
            >
              <div class="flex items-start justify-between gap-2">
                <div class="flex items-center gap-2">
                  <input
                    type="checkbox"
                    :checked="isSelected(source.id)"
                    class="size-4 cursor-pointer"
                    :aria-label="$t('AI_KNOWLEDGE.BULK.SELECT_ALL')"
                    @change="toggleSelect(source.id)"
                  />
                  <span
                    class="shrink-0 size-9 rounded-lg bg-n-brand/10 text-n-brand flex items-center justify-center"
                  >
                    <span :class="kindIcon(source.kind)" class="size-5" />
                  </span>
                </div>
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
                    @click="askDeleteSingle(source)"
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
                  v-if="source.price"
                  class="text-xs font-medium text-n-brand mb-0"
                >
                  {{ source.price }}
                </p>
                <p
                  v-if="source.raw"
                  class="text-xs text-n-slate-11 mb-0 line-clamp-2"
                >
                  {{ source.raw }}
                </p>
              </div>
              <div class="flex flex-wrap items-center gap-1.5">
                <span
                  class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-n-alpha-2 text-xs text-n-slate-11"
                >
                  <span :class="kindIcon(source.kind)" class="size-3" />
                  {{ kindLabel(source.kind) }}
                </span>
                <span
                  class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs"
                  :class="scopeBadge(source).class"
                >
                  <span :class="scopeBadge(source).icon" class="size-3" />
                  {{ scopeBadge(source).text }}
                </span>
              </div>
            </div>
          </template>
        </div>

        <!-- Modal ÚNICO de exclusão (individual e lote): simples, sem digitar o nome do item. -->
        <woot-delete-modal
          v-model:show="deleteModalOpen"
          :on-close="closeDelete"
          :on-confirm="confirmDelete"
          :title="deleteTitle"
          :message="deleteMessage"
          :confirm-text="$t('AI_KNOWLEDGE.DELETE_MODAL.CONFIRM')"
          :reject-text="$t('AI_KNOWLEDGE.DELETE_MODAL.CANCEL')"
        />
      </section>
    </div>
  </div>
</template>
