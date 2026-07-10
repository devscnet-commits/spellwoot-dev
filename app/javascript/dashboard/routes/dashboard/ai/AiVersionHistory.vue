<script setup>
// Reusable "Histórico de versões" panel (list + Restaurar). Extracted from the duplicated inline
// blocks of AiAgentDetail.vue and AiDepartmentDetail.vue. The three things that used to differ
// between the copies are now props/events: the endpoint (baseUrl), the error i18n key (errorKey)
// and the post-restore refresh of the parent record (@restored). The version object shape
// { id, version_number, note, created_at } and the AI_AGENTS.VERSIONS.* i18n namespace are shared.
/* global axios */
import { ref, onMounted } from 'vue';
import { useAlert } from 'dashboard/composables';
import { useI18n } from 'vue-i18n';
import Button from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  // Versions collection endpoint, e.g. `.../ai_agents/:id/ai_agent_versions`.
  baseUrl: { type: String, required: true },
  // i18n key for the restore-failure alert (agent vs department scopes differ here).
  errorKey: { type: String, default: 'AI_AGENTS.ERROR' },
});
const emit = defineEmits(['restored']);

const { t } = useI18n();
const versions = ref([]);
const showVersions = ref(false);

const fetchVersions = async () => {
  try {
    const { data } = await axios.get(props.baseUrl);
    versions.value = Array.isArray(data) ? data : [];
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error(
      '[AiVersionHistory] falha ao buscar versões:',
      props.baseUrl,
      error?.response?.status,
      error
    );
    useAlert(t(props.errorKey));
    versions.value = [];
  }
};

const restoreVersion = async v => {
  // eslint-disable-next-line no-alert
  if (!window.confirm(t('AI_AGENTS.VERSIONS.CONFIRM', { n: v.version_number })))
    return;
  try {
    await axios.post(`${props.baseUrl}/${v.id}/restore`);
    useAlert(t('AI_AGENTS.VERSIONS.RESTORED'));
    emit('restored');
    await fetchVersions();
  } catch (error) {
    useAlert(t(props.errorKey));
  }
};

const formatVersionDate = iso => (iso ? new Date(iso).toLocaleString() : '');

onMounted(fetchVersions);
</script>

<template>
  <div class="border-t border-n-weak pt-4 flex flex-col gap-3">
    <button
      type="button"
      class="flex items-center gap-2 text-sm font-medium text-n-slate-12"
      @click="showVersions = !showVersions"
    >
      <span
        class="size-4 inline-block"
        :class="
          showVersions ? 'i-lucide-chevron-down' : 'i-lucide-chevron-right'
        "
      />
      {{ $t('AI_AGENTS.VERSIONS.TITLE') }}
      <span class="text-n-slate-11 font-normal">{{
        `(${versions.length})`
      }}</span>
    </button>
    <div
      v-if="showVersions"
      class="border border-n-weak rounded-xl divide-y divide-n-weak max-h-72 overflow-auto"
    >
      <p v-if="!versions.length" class="text-sm text-n-slate-11 px-4 py-3 mb-0">
        {{ $t('AI_AGENTS.VERSIONS.EMPTY') }}
      </p>
      <div
        v-for="v in versions"
        :key="v.id"
        class="flex items-center justify-between gap-3 px-4 py-2.5"
      >
        <div class="min-w-0">
          <p class="text-sm text-n-slate-12 mb-0">
            {{ `v${v.version_number}` }}
            <span v-if="v.note" class="text-n-slate-11">{{
              ` · ${v.note}`
            }}</span>
          </p>
          <p class="text-xs text-n-slate-11 mb-0">
            {{ formatVersionDate(v.created_at) }}
          </p>
        </div>
        <Button
          variant="ghost"
          color="slate"
          size="sm"
          :label="$t('AI_AGENTS.VERSIONS.RESTORE')"
          @click="restoreVersion(v)"
        />
      </div>
    </div>
  </div>
</template>
