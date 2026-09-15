<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import InboxesAPI from 'dashboard/api/inboxes';
import SettingsFieldSection from 'dashboard/components-next/Settings/SettingsFieldSection.vue';
import LoadingState from 'dashboard/components/widgets/LoadingState.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  inbox: { type: Object, default: () => ({}) },
});

const { t } = useI18n();

const agents = ref([]);
const isFetching = ref(true);
const isSaving = ref(false);

const inboxId = computed(() => props.inbox?.id);

// The Gateway elects by [priority ASC, id ASC], so the first row is the one that answers.
// Saving rewrites priority as 1..N by position, which also clears any pre-existing tie.
const hasTie = computed(() => {
  if (agents.value.length < 2) return false;
  const lowest = Math.min(...agents.value.map(agent => agent.priority));
  return agents.value.filter(agent => agent.priority === lowest).length > 1;
});

const isDirty = computed(() =>
  agents.value.some((agent, index) => agent.priority !== index + 1)
);

const modeLabel = mode =>
  mode === 'live'
    ? t('INBOX_MGMT.AI_PRIORITIES.MODE_LIVE')
    : t('INBOX_MGMT.AI_PRIORITIES.MODE_SHADOW');

const fetchPriorities = async () => {
  isFetching.value = true;
  try {
    const { data } = await InboxesAPI.getAiAgentPriorities(inboxId.value);
    agents.value = data.map(agent => ({
      id: agent.agent_id,
      name: agent.agent_name,
      mode: agent.mode,
      priority: agent.priority,
    }));
  } catch {
    agents.value = [];
  } finally {
    isFetching.value = false;
  }
};

const move = (index, offset) => {
  const target = index + offset;
  if (target < 0 || target >= agents.value.length) return;

  const reordered = [...agents.value];
  [reordered[index], reordered[target]] = [reordered[target], reordered[index]];
  agents.value = reordered;
};

const save = async () => {
  isSaving.value = true;
  try {
    const priorities = agents.value.map((agent, index) => ({
      agent_id: agent.id,
      priority: index + 1,
    }));
    await InboxesAPI.updateAiAgentPriorities(inboxId.value, priorities);
    agents.value = agents.value.map((agent, index) => ({
      ...agent,
      priority: index + 1,
    }));
    useAlert(t('INBOX_MGMT.AI_PRIORITIES.SUCCESS'));
  } catch {
    useAlert(t('INBOX_MGMT.AI_PRIORITIES.ERROR'));
  } finally {
    isSaving.value = false;
  }
};

onMounted(fetchPriorities);
</script>

<template>
  <div class="mx-6 max-w-4xl mt-8">
    <LoadingState v-if="isFetching" />
    <SettingsFieldSection
      v-else
      :label="t('INBOX_MGMT.AI_PRIORITIES.TITLE')"
      :help-text="t('INBOX_MGMT.AI_PRIORITIES.DESC')"
      class="[&>div]:!items-start"
    >
      <p v-if="!agents.length" class="text-sm text-n-slate-11">
        {{ t('INBOX_MGMT.AI_PRIORITIES.EMPTY') }}
      </p>
      <div v-else class="flex flex-col gap-2">
        <div
          v-for="(agent, index) in agents"
          :key="agent.id"
          class="flex items-center gap-3 p-3 border rounded-lg border-n-weak"
        >
          <span class="w-5 text-sm tabular-nums text-n-slate-10">
            {{ index + 1 }}
          </span>
          <span class="flex-1 min-w-0">
            <span class="block font-medium truncate text-n-slate-12">
              {{ agent.name }}
            </span>
            <span class="text-xs text-n-slate-10">
              {{ modeLabel(agent.mode) }}
            </span>
          </span>
          <span
            v-if="index === 0"
            class="px-2 py-0.5 text-xs font-medium rounded-full bg-n-teal-3 text-n-teal-11"
          >
            {{ t('INBOX_MGMT.AI_PRIORITIES.DEFAULT_BADGE') }}
          </span>
          <NextButton
            icon="i-lucide-chevron-up"
            variant="ghost"
            color="slate"
            size="xs"
            :disabled="index === 0"
            @click="move(index, -1)"
          />
          <NextButton
            icon="i-lucide-chevron-down"
            variant="ghost"
            color="slate"
            size="xs"
            :disabled="index === agents.length - 1"
            @click="move(index, 1)"
          />
        </div>
      </div>
      <template #extra>
        <div v-if="agents.length" class="grid grid-cols-1 lg:grid-cols-8 mt-3">
          <div class="col-span-1 lg:col-span-2 invisible" />
          <div class="col-span-1 lg:col-span-6 flex flex-col gap-2 mx-1">
            <p v-if="hasTie" class="text-xs text-n-amber-11">
              {{ t('INBOX_MGMT.AI_PRIORITIES.TIE_WARNING') }}
            </p>
            <div>
              <NextButton
                :label="t('INBOX_MGMT.AI_PRIORITIES.SUBMIT')"
                :is-loading="isSaving"
                :disabled="!isDirty"
                @click="save"
              />
            </div>
          </div>
        </div>
      </template>
    </SettingsFieldSection>
  </div>
</template>
