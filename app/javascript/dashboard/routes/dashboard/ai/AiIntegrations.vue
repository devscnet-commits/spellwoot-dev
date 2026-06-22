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

const KINDS = ['webhook', 'erp', 'bitrix', 'n8n'];
const METHODS = ['GET', 'POST', 'PUT', 'PATCH', 'DELETE'];
const AUTH_TYPES = ['none', 'bearer', 'header'];

const kindOptions = computed(() =>
  KINDS.map(k => ({
    value: k,
    label: t(`AI_INTEGRATIONS.KINDS.${k.toUpperCase()}`),
  }))
);
const methodOptions = METHODS.map(m => ({ value: m, label: m }));
const authOptions = computed(() =>
  AUTH_TYPES.map(a => ({
    value: a,
    label: t(`AI_INTEGRATIONS.FORM.AUTH_${a.toUpperCase()}`),
  }))
);

const integrations = ref([]);
const isLoading = ref(false);
const showForm = ref(false);
const sections = reactive({ advanced: false });

const blank = () => ({
  id: null,
  name: '',
  kind: 'webhook',
  endpoint: '',
  http_method: 'POST',
  auth_type: 'none',
  auth_token: '',
  auth_header: '',
  auth_value: '',
  headers_text: '{}',
  payload_text: '{}',
  timeout_seconds: 10,
  retry_count: 0,
  status: 'active',
});
const form = reactive(blank());
const { isDirty, capture } = useFormDirty(() => ({ ...form }));

const baseUrl = () =>
  `/api/v1/accounts/${route.params.accountId}/ai_integration_links`;

const statusLabel = s =>
  t(`AI_INTEGRATIONS.STATUS.${(s || 'active').toUpperCase()}`);

const fetchIntegrations = async () => {
  isLoading.value = true;
  try {
    const { data } = await axios.get(baseUrl());
    integrations.value = Array.isArray(data) ? data : [];
  } finally {
    isLoading.value = false;
  }
};

const openNew = () => {
  Object.assign(form, blank());
  sections.advanced = false;
  showForm.value = true;
  capture();
};

const openEdit = link => {
  const auth = link.auth || {};
  Object.assign(form, blank(), {
    id: link.id,
    name: link.name,
    kind: link.kind || 'webhook',
    endpoint: link.endpoint || '',
    http_method: link.http_method || 'POST',
    auth_type: auth.type || 'none',
    auth_token: auth.token || '',
    auth_header: auth.header || '',
    auth_value: auth.value || '',
    headers_text: JSON.stringify(link.headers || {}, null, 2),
    payload_text: JSON.stringify(link.payload_template || {}, null, 2),
    timeout_seconds: link.timeout_seconds ?? 10,
    retry_count: link.retry_count ?? 0,
    status: link.status || 'active',
  });
  showForm.value = true;
  capture();
};

const buildAuth = () => {
  if (form.auth_type === 'bearer') {
    return { type: 'bearer', token: form.auth_token };
  }
  if (form.auth_type === 'header') {
    return { type: 'header', header: form.auth_header, value: form.auth_value };
  }
  return {};
};

const save = async () => {
  let headers = {};
  let payload = {};
  try {
    headers = JSON.parse(form.headers_text || '{}');
    payload = JSON.parse(form.payload_text || '{}');
  } catch (error) {
    useAlert(t('AI_INTEGRATIONS.INVALID_JSON'));
    return;
  }
  const body = {
    ai_integration_link: {
      name: form.name,
      kind: form.kind,
      endpoint: form.endpoint,
      http_method: form.http_method,
      status: form.status,
      timeout_seconds: Number(form.timeout_seconds) || 10,
      retry_count: Number(form.retry_count) || 0,
      auth: buildAuth(),
      headers,
      payload_template: payload,
    },
  };
  try {
    if (form.id) {
      await axios.patch(`${baseUrl()}/${form.id}`, body);
    } else {
      await axios.post(baseUrl(), body);
    }
    useAlert(t('AI_INTEGRATIONS.SAVED'));
    showForm.value = false;
    fetchIntegrations();
  } catch (error) {
    useAlert(t('AI_INTEGRATIONS.ERROR'));
  }
};

// --- Teste de conexão ---
const testResult = ref(null);
const testingId = ref(null);
const runTest = async link => {
  testingId.value = link.id;
  testResult.value = null;
  try {
    const { data } = await axios.post(`${baseUrl()}/${link.id}/test`);
    testResult.value = { id: link.id, ...data };
  } catch (error) {
    testResult.value = {
      id: link.id,
      ok: false,
      error: error.response?.data?.error || t('AI_INTEGRATIONS.ERROR'),
    };
  } finally {
    testingId.value = null;
  }
};

const deleteTarget = ref(null);
const confirmRemove = async () => {
  try {
    await axios.delete(`${baseUrl()}/${deleteTarget.value.id}`);
    useAlert(t('AI_INTEGRATIONS.DELETED'));
    deleteTarget.value = null;
    fetchIntegrations();
  } catch (error) {
    useAlert(t('AI_INTEGRATIONS.ERROR'));
  }
};

onMounted(fetchIntegrations);
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
              {{ $t('AI_INTEGRATIONS.TITLE') }}
            </h1>
            <p class="text-sm text-n-slate-11 mb-0">
              {{ $t('AI_INTEGRATIONS.DESCRIPTION') }}
            </p>
          </div>
          <div class="shrink-0">
            <Button
              icon="i-lucide-plus"
              :label="$t('AI_INTEGRATIONS.NEW')"
              @click="openNew"
            />
          </div>
        </div>

        <p
          v-if="!isLoading && !integrations.length"
          class="text-sm text-n-slate-11 py-8 text-center"
        >
          {{ $t('AI_INTEGRATIONS.EMPTY') }}
        </p>
        <div
          v-else
          class="border border-n-weak rounded-xl divide-y divide-n-weak"
        >
          <div
            v-for="link in integrations"
            :key="link.id"
            class="flex flex-col gap-2 px-4 py-3"
          >
            <div class="flex items-center justify-between gap-3">
              <div class="min-w-0">
                <p class="text-sm font-medium text-n-slate-12">
                  {{ link.name }}
                </p>
                <p class="text-xs text-n-slate-11 truncate">
                  {{
                    $t(
                      `AI_INTEGRATIONS.KINDS.${(link.kind || 'webhook').toUpperCase()}`
                    )
                  }}
                  · {{ statusLabel(link.status) }}
                </p>
              </div>
              <div class="shrink-0 flex items-center gap-1">
                <Button
                  variant="faded"
                  color="slate"
                  size="sm"
                  :is-loading="testingId === link.id"
                  :label="$t('AI_INTEGRATIONS.TEST.BUTTON')"
                  @click="runTest(link)"
                />
                <Button
                  variant="ghost"
                  color="slate"
                  size="sm"
                  icon="i-lucide-pencil"
                  @click="openEdit(link)"
                />
                <Button
                  variant="ghost"
                  color="ruby"
                  size="sm"
                  icon="i-lucide-trash-2"
                  @click="deleteTarget = link"
                />
              </div>
            </div>
            <div
              v-if="testResult && testResult.id === link.id"
              class="rounded-lg px-3 py-2 text-xs"
              :class="
                testResult.ok
                  ? 'bg-n-teal-3 text-n-teal-11'
                  : 'bg-n-ruby-3 text-n-ruby-11'
              "
            >
              <span class="font-medium">
                {{
                  testResult.ok
                    ? $t('AI_INTEGRATIONS.TEST.OK')
                    : $t('AI_INTEGRATIONS.TEST.FAIL')
                }}
              </span>
              <span v-if="testResult.ok">
                {{
                  $t('AI_INTEGRATIONS.TEST.OK_DETAIL', {
                    status: testResult.status,
                    ms: testResult.latency_ms,
                  })
                }}
              </span>
              <span v-else>{{ testResult.error }}</span>
            </div>
          </div>
        </div>

        <!-- Form -->
        <div
          v-if="showForm"
          class="border border-n-weak rounded-xl p-5 flex flex-col gap-4 bg-n-solid-2"
        >
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <Input
              v-model="form.name"
              :label="$t('AI_INTEGRATIONS.FORM.NAME')"
            />
            <div class="flex flex-col gap-1.5">
              <span class="text-sm font-medium text-n-slate-12">{{
                $t('AI_INTEGRATIONS.FORM.KIND')
              }}</span>
              <Select v-model="form.kind" :options="kindOptions" />
            </div>
          </div>

          <Input
            v-model="form.endpoint"
            :label="$t('AI_INTEGRATIONS.FORM.ENDPOINT')"
            placeholder="https://..."
          />

          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div class="flex flex-col gap-1.5">
              <span class="text-sm font-medium text-n-slate-12">{{
                $t('AI_INTEGRATIONS.FORM.METHOD')
              }}</span>
              <Select v-model="form.http_method" :options="methodOptions" />
            </div>
            <div class="flex flex-col gap-1.5">
              <span class="text-sm font-medium text-n-slate-12">{{
                $t('AI_INTEGRATIONS.FORM.AUTH')
              }}</span>
              <Select v-model="form.auth_type" :options="authOptions" />
            </div>
          </div>

          <Input
            v-if="form.auth_type === 'bearer'"
            v-model="form.auth_token"
            :label="$t('AI_INTEGRATIONS.FORM.TOKEN')"
          />
          <div
            v-else-if="form.auth_type === 'header'"
            class="grid grid-cols-1 sm:grid-cols-2 gap-4"
          >
            <Input
              v-model="form.auth_header"
              :label="$t('AI_INTEGRATIONS.FORM.HEADER_NAME')"
            />
            <Input
              v-model="form.auth_value"
              :label="$t('AI_INTEGRATIONS.FORM.HEADER_VALUE')"
            />
          </div>

          <!-- Detalhes técnicos -->
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
              <span class="text-sm font-semibold text-n-slate-12">
                {{ $t('AI_INTEGRATIONS.FORM.ADVANCED') }}
              </span>
            </button>
            <div
              v-if="sections.advanced"
              class="border-t border-n-weak p-4 flex flex-col gap-4"
            >
              <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
                {{ $t('AI_INTEGRATIONS.FORM.HEADERS') }}
                <textarea
                  v-model="form.headers_text"
                  rows="3"
                  class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 font-mono text-xs resize-y"
                />
              </label>
              <label class="flex flex-col gap-1.5 text-sm text-n-slate-12">
                {{ $t('AI_INTEGRATIONS.FORM.PAYLOAD') }}
                <textarea
                  v-model="form.payload_text"
                  rows="3"
                  class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 font-mono text-xs resize-y"
                />
              </label>
              <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
                <Input
                  v-model="form.timeout_seconds"
                  type="number"
                  :label="$t('AI_INTEGRATIONS.FORM.TIMEOUT')"
                />
                <Input
                  v-model="form.retry_count"
                  type="number"
                  :label="$t('AI_INTEGRATIONS.FORM.RETRY')"
                />
                <div class="flex flex-col gap-1.5">
                  <span class="text-sm font-medium text-n-slate-12">{{
                    $t('AI_INTEGRATIONS.FORM.STATUS')
                  }}</span>
                  <Select
                    v-model="form.status"
                    :options="[
                      { value: 'active', label: statusLabel('active') },
                      { value: 'inactive', label: statusLabel('inactive') },
                    ]"
                  />
                </div>
              </div>
            </div>
          </section>

          <div class="flex justify-end gap-2">
            <Button
              variant="faded"
              color="slate"
              :label="$t('AI_INTEGRATIONS.FORM.CANCEL')"
              @click="showForm = false"
            />
            <Button
              :label="$t('AI_INTEGRATIONS.FORM.SAVE')"
              :disabled="!isDirty || !form.name.trim() || !form.endpoint.trim()"
              @click="save"
            />
          </div>
        </div>
      </div>
    </div>

    <ConfirmDeleteModal
      v-if="deleteTarget"
      show
      :title="$t('AI_INTEGRATIONS.DELETE_MODAL.TITLE')"
      :message="
        $t('AI_INTEGRATIONS.DELETE_MODAL.MESSAGE', { name: deleteTarget.name })
      "
      :confirm-text="$t('AI_INTEGRATIONS.DELETE_MODAL.CONFIRM')"
      :reject-text="$t('AI_INTEGRATIONS.DELETE_MODAL.CANCEL')"
      :confirm-value="deleteTarget.name"
      :confirm-place-holder-text="
        $t('AI_INTEGRATIONS.DELETE_MODAL.PLACEHOLDER', {
          name: deleteTarget.name,
        })
      "
      @on-confirm="confirmRemove"
      @on-close="deleteTarget = null"
    />
  </div>
</template>
