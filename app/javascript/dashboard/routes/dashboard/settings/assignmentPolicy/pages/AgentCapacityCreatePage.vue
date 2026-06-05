<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import camelcaseKeys from 'camelcase-keys';
import { getInboxIconByType } from 'dashboard/helper/inbox';

import Breadcrumb from 'dashboard/components-next/breadcrumb/Breadcrumb.vue';
import SettingsLayout from 'dashboard/routes/dashboard/settings/SettingsLayout.vue';
import AgentCapacityPolicyForm from './components/AgentCapacityPolicyForm.vue';

const router = useRouter();
const store = useStore();
const { t } = useI18n();

const formRef = ref(null);

const uiFlags      = useMapGetter('agentCapacityPolicies/getUIFlags');
const agentsList   = useMapGetter('agents/getAgents');
const labelsList   = useMapGetter('labels/getLabels');
const inboxes      = useMapGetter('inboxes/getAllInboxes');
const inboxesUiFlags = useMapGetter('inboxes/getUIFlags');

const breadcrumbItems = computed(() => [
  {
    label: t('ASSIGNMENT_POLICY.AGENT_CAPACITY_POLICY.INDEX.HEADER.TITLE'),
    routeName: 'agent_capacity_policy_index',
  },
  {
    label: t('ASSIGNMENT_POLICY.AGENT_CAPACITY_POLICY.CREATE.HEADER.TITLE'),
  },
]);

const buildList = items =>
  items?.map(({ name, title, id, email, avatarUrl, thumbnail, color }) => ({
    name: name || title,
    id,
    email,
    avatarUrl: avatarUrl || thumbnail,
    color,
  })) || [];

const allAgents = computed(() => buildList(camelcaseKeys(agentsList.value)));
const allLabels = computed(() => buildList(labelsList.value));

const allInboxes = computed(() =>
  inboxes.value
    ?.slice()
    .sort((a, b) => a.name.localeCompare(b.name))
    .map(({ name, id, email, phoneNumber, channelType, medium }) => ({
      name,
      id,
      email,
      phoneNumber,
      icon: getInboxIconByType(channelType, medium, 'line'),
    })) || []
);

const handleBreadcrumbClick = item => {
  if (item.routeName) router.push({ name: item.routeName });
};

const handleSubmit = async formState => {
  try {
    await store.dispatch('agentCapacityPolicies/create', formState);
    useAlert(t('ASSIGNMENT_POLICY.AGENT_CAPACITY_POLICY.CREATE.API.SUCCESS_MESSAGE'));
    formRef.value?.resetForm();
    router.push({ name: 'agent_capacity_policy_index' });
  } catch {
    useAlert(t('ASSIGNMENT_POLICY.AGENT_CAPACITY_POLICY.CREATE.API.ERROR_MESSAGE'));
  }
};

onMounted(() => {
  store.dispatch('agents/get');
  store.dispatch('labels/get');
  store.dispatch('inboxes/get');
});
</script>

<template>
  <SettingsLayout class="w-full max-w-2xl ltr:mr-auto rtl:ml-auto">
    <template #header>
      <div class="flex items-center gap-2 w-full justify-between mb-4 min-h-10">
        <Breadcrumb :items="breadcrumbItems" @click="handleBreadcrumbClick" />
      </div>
    </template>

    <template #body>
      <AgentCapacityPolicyForm
        ref="formRef"
        mode="CREATE"
        :is-loading="uiFlags.isCreating"
        :agent-list="allAgents"
        :label-list="allLabels"
        :inbox-list="allInboxes"
        :is-inboxes-loading="inboxesUiFlags.isFetching"
        @submit="handleSubmit"
      />
    </template>
  </SettingsLayout>
</template>
