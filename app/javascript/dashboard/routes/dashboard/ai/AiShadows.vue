<script setup>
/* global axios */
import { ref, reactive, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import Input from 'dashboard/components-next/input/Input.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import ConfirmDeleteModal from 'dashboard/components/widgets/modal/ConfirmDeleteModal.vue';
import AiShadowRuns from './AiShadowRuns.vue';
import { useFormDirty } from 'dashboard/composables/useFormDirty';

const route = useRoute();
const { t } = useI18n();

// Module tabs: the shadows list + the analysis (submodule), no navigation away.
const activeTab = ref('shadows');

// Quick suggestions: clicking one appends a ready-made line to the evaluation
// instructions. There is a single source of truth — the instructions text.
const SUGGESTION_KEYS = [
  'unanswered',
  'errors',
  'low_confidence',
  'knowledge_gaps',
  'tools_missing',
  'recurring',
];

const shadows = ref([]);
const inboxes = ref([]);
const isLoading = ref(false);
const showForm = ref(false);

const blank = () => ({
  id: null,
  name: '',
  instructions: '',
  status: 'active',
  observe_ai: true,
  observe_human: true,
  inbox_ids: [],
});
const form = reactive(blank());
const { isDirty, capture } = useFormDirty(() => ({ ...form }));

const accountUrl = () => `/api/v1/accounts/${route.params.accountId}`;
const baseUrl = () => `${accountUrl()}/ai_shadows`;

const fetchShadows = async () => {
  isLoading.value = true;
  try {
    const { data } = await axios.get(baseUrl());
    shadows.value = Array.isArray(data) ? data : [];
  } finally {
    isLoading.value = false;
  }
};

const fetchInboxes = async () => {
  try {
    const { data } = await axios.get(`${accountUrl()}/inboxes`);
    inboxes.value = data?.payload || (Array.isArray(data) ? data : []);
  } catch (error) {
    inboxes.value = [];
  }
};

const toggleInbox = id => {
  const i = form.inbox_ids.indexOf(id);
  if (i >= 0) form.inbox_ids.splice(i, 1);
  else form.inbox_ids.push(id);
};

const openNew = () => {
  Object.assign(form, blank());
  showForm.value = true;
  capture();
};

const openEdit = shadow => {
  const scope = shadow.scope || {};
  Object.assign(form, blank(), {
    id: shadow.id,
    name: shadow.name,
    instructions: shadow.instructions || '',
    status: shadow.status || 'active',
    observe_ai: scope.observe_ai !== false,
    observe_human: scope.observe_human !== false,
    inbox_ids: Array.isArray(shadow.inbox_ids) ? [...shadow.inbox_ids] : [],
  });
  showForm.value = true;
  capture();
};

// Append a suggestion line to the instructions (no duplicates).
const addSuggestion = key => {
  const line = t(`AI_SHADOWS.SUGGESTIONS.${key.toUpperCase()}`);
  const current = form.instructions.trim();
  if (current.includes(line)) return;
  form.instructions = current ? `${current}\n${line}` : line;
};

const save = async () => {
  const payload = {
    ai_shadow: {
      name: form.name,
      instructions: form.instructions,
      status: form.status,
      scope: { observe_ai: form.observe_ai, observe_human: form.observe_human },
      inbox_ids: form.inbox_ids,
    },
  };
  try {
    if (form.id) {
      await axios.patch(`${baseUrl()}/${form.id}`, payload);
    } else {
      await axios.post(baseUrl(), payload);
    }
    useAlert(t('AI_SHADOWS.SAVED'));
    showForm.value = false;
    fetchShadows();
  } catch (error) {
    useAlert(t('AI_SHADOWS.ERROR'));
  }
};

const deleteTarget = ref(null);
const confirmRemove = async () => {
  try {
    await axios.delete(`${baseUrl()}/${deleteTarget.value.id}`);
    useAlert(t('AI_SHADOWS.DELETED'));
    deleteTarget.value = null;
    fetchShadows();
  } catch (error) {
    useAlert(t('AI_SHADOWS.ERROR'));
  }
};

onMounted(() => {
  fetchShadows();
  fetchInboxes();
});
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
              {{ $t('AI_SHADOWS.TITLE') }}
            </h1>
            <p class="text-sm text-n-slate-11 mb-0">
              {{ $t('AI_SHADOWS.DESCRIPTION') }}
            </p>
          </div>
          <div class="shrink-0">
            <Button
              v-if="activeTab === 'shadows'"
              icon="i-lucide-plus"
              :label="$t('AI_SHADOWS.NEW')"
              @click="openNew"
            />
          </div>
        </div>

        <!-- Tabs do módulo: Shadows (lista/criação) + Análises (submódulo) -->
        <div class="flex items-center gap-x-5 gap-y-1 border-b border-n-weak">
          <button
            v-for="tab in ['shadows', 'analysis']"
            :key="tab"
            type="button"
            class="pb-2.5 text-sm font-medium border-b-2 -mb-px"
            :class="
              activeTab === tab
                ? 'border-n-brand text-n-brand'
                : 'border-transparent text-n-slate-11 hover:text-n-slate-12'
            "
            @click="activeTab = tab"
          >
            {{ $t(`AI_SHADOWS.TABS.${tab.toUpperCase()}`) }}
          </button>
        </div>

        <AiShadowRuns v-if="activeTab === 'analysis'" embedded />

        <p
          v-else-if="!isLoading && !shadows.length"
          class="text-sm text-n-slate-11 py-8 text-center"
        >
          {{ $t('AI_SHADOWS.EMPTY') }}
        </p>
        <div
          v-else
          class="border border-n-weak rounded-xl divide-y divide-n-weak"
        >
          <div
            v-for="shadow in shadows"
            :key="shadow.id"
            class="flex items-center justify-between px-4 py-3 gap-3"
          >
            <div class="min-w-0">
              <p class="text-sm font-medium text-n-slate-12">
                {{ shadow.name }}
              </p>
              <p class="text-xs text-n-slate-11 truncate">
                {{
                  $t('AI_SHADOWS.INBOX_COUNT', {
                    count: (shadow.inbox_ids || []).length,
                  })
                }}
                ·
                {{
                  shadow.status === 'active'
                    ? $t('AI_SHADOWS.STATUS.ACTIVE')
                    : $t('AI_SHADOWS.STATUS.INACTIVE')
                }}
              </p>
            </div>
            <div class="shrink-0 flex items-center gap-1">
              <Button
                variant="ghost"
                color="slate"
                size="sm"
                icon="i-lucide-pencil"
                @click="openEdit(shadow)"
              />
              <Button
                variant="ghost"
                color="ruby"
                size="sm"
                icon="i-lucide-trash-2"
                @click="deleteTarget = shadow"
              />
            </div>
          </div>
        </div>

        <!-- Form -->
        <div
          v-if="showForm && activeTab === 'shadows'"
          class="border border-n-weak rounded-xl p-5 flex flex-col gap-5 bg-n-solid-2"
        >
          <Input v-model="form.name" :label="$t('AI_SHADOWS.FORM.NAME')" />

          <div class="flex flex-col gap-1.5">
            <span class="text-heading-3 text-n-slate-12">
              {{ $t('AI_SHADOWS.FORM.INSTRUCTIONS') }}
            </span>
            <textarea
              v-model="form.instructions"
              rows="6"
              :placeholder="$t('AI_SHADOWS.FORM.INSTRUCTIONS_PLACEHOLDER')"
              class="px-3 py-2.5 rounded-lg border border-n-weak bg-n-solid-1 resize-y leading-relaxed text-sm text-n-slate-12"
            />
            <span class="text-xs text-n-slate-11">
              {{ $t('AI_SHADOWS.FORM.SUGGESTIONS_HINT') }}
            </span>
            <div class="flex flex-wrap gap-2 pt-1">
              <button
                v-for="key in SUGGESTION_KEYS"
                :key="key"
                type="button"
                class="inline-flex items-center gap-1 px-2.5 py-1 rounded-full border border-n-weak text-xs text-n-slate-11 hover:border-n-brand hover:text-n-brand transition-colors"
                @click="addSuggestion(key)"
              >
                <span class="i-lucide-plus size-3" />
                {{ $t(`AI_SHADOWS.SIGNALS.${key.toUpperCase()}`) }}
              </button>
            </div>
          </div>

          <!-- Caixas observadas -->
          <div class="flex flex-col gap-1.5">
            <span class="text-heading-3 text-n-slate-12">
              {{ $t('AI_SHADOWS.FORM.INBOXES') }}
            </span>
            <p v-if="!inboxes.length" class="text-sm text-n-slate-11 mb-0">
              {{ $t('AI_SHADOWS.FORM.NO_INBOXES') }}
            </p>
            <div v-else class="grid grid-cols-1 sm:grid-cols-2 gap-2">
              <label
                v-for="inbox in inboxes"
                :key="inbox.id"
                class="flex items-center gap-2 text-sm text-n-slate-12 rounded-lg border border-n-weak px-3 py-2"
              >
                <input
                  type="checkbox"
                  :checked="form.inbox_ids.includes(inbox.id)"
                  @change="toggleInbox(inbox.id)"
                />
                <span class="truncate">{{ inbox.name }}</span>
              </label>
            </div>
          </div>

          <!-- O que observar -->
          <div class="flex flex-col gap-1.5">
            <span class="text-heading-3 text-n-slate-12">
              {{ $t('AI_SHADOWS.FORM.SCOPE') }}
            </span>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
              <label
                class="flex items-center gap-2 text-sm text-n-slate-12 rounded-lg border border-n-weak px-3 py-2"
              >
                <input v-model="form.observe_ai" type="checkbox" />
                <span class="truncate">{{
                  $t('AI_SHADOWS.FORM.OBSERVE_AI')
                }}</span>
              </label>
              <label
                class="flex items-center gap-2 text-sm text-n-slate-12 rounded-lg border border-n-weak px-3 py-2"
              >
                <input v-model="form.observe_human" type="checkbox" />
                <span class="truncate">{{
                  $t('AI_SHADOWS.FORM.OBSERVE_HUMAN')
                }}</span>
              </label>
            </div>
          </div>

          <!-- Status -->
          <div class="flex flex-col gap-1.5">
            <span class="text-heading-3 text-n-slate-12">
              {{ $t('AI_SHADOWS.FORM.STATUS') }}
            </span>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
              <label
                class="flex items-center gap-2 text-sm text-n-slate-12 rounded-lg border border-n-weak px-3 py-2"
              >
                <input
                  type="checkbox"
                  :checked="form.status === 'active'"
                  @change="
                    form.status = $event.target.checked ? 'active' : 'inactive'
                  "
                />
                <span class="truncate">{{
                  $t('AI_SHADOWS.STATUS.ACTIVE')
                }}</span>
              </label>
            </div>
          </div>

          <div class="flex justify-end gap-2">
            <Button
              variant="faded"
              color="slate"
              :label="$t('AI_SHADOWS.FORM.CANCEL')"
              @click="showForm = false"
            />
            <Button
              :label="$t('AI_SHADOWS.FORM.SAVE')"
              :disabled="!isDirty || !form.name.trim()"
              @click="save"
            />
          </div>
        </div>
      </div>
    </div>

    <ConfirmDeleteModal
      v-if="deleteTarget"
      show
      :title="$t('AI_SHADOWS.DELETE_MODAL.TITLE')"
      :message="
        $t('AI_SHADOWS.DELETE_MODAL.MESSAGE', { name: deleteTarget.name })
      "
      :confirm-text="$t('AI_SHADOWS.DELETE_MODAL.CONFIRM')"
      :reject-text="$t('AI_SHADOWS.DELETE_MODAL.CANCEL')"
      :confirm-value="deleteTarget.name"
      :confirm-place-holder-text="
        $t('AI_SHADOWS.DELETE_MODAL.PLACEHOLDER', { name: deleteTarget.name })
      "
      @on-confirm="confirmRemove"
      @on-close="deleteTarget = null"
    />
  </div>
</template>
