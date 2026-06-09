<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useRoute, useRouter } from 'vue-router';
import { useAlert } from 'dashboard/composables';
import { getInboxIconByType } from 'dashboard/helper/inbox';

import Breadcrumb from 'dashboard/components-next/breadcrumb/Breadcrumb.vue';
import SettingsLayout from 'dashboard/routes/dashboard/settings/SettingsLayout.vue';
import AssignmentPolicyForm from './components/AgentAssignmentPolicyForm.vue';

const route  = useRoute();
const router = useRouter();
const store  = useStore();
const { t }  = useI18n();

const formRef    = ref(null);
const uiFlags    = useMapGetter('assignmentPolicies/getUIFlags');
const inboxes    = useMapGetter('inboxes/getAllInboxes');
const inboxUiFlags = useMapGetter('inboxes/getUIFlags');

// When coming from inbox settings, pre-select that inbox
const inboxIdFromQuery = computed(() => {
  const id = route.query.inboxId;
  return id ? Number(id) : null;
});

const breadcrumbItems = computed(() => {
  if (inboxIdFromQuery.value) {
    return [
      {
        label: t('INBOX_MGMT.SETTINGS'),
        routeName: 'settings_inbox_show',
        params: { inboxId: inboxIdFromQuery.value },
      },
      { label: t('ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.CREATE.HEADER.TITLE') },
    ];
  }
  return [
    {
      label: t('ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.INDEX.HEADER.TITLE'),
      routeName: 'agent_assignment_policy_index',
    },
    { label: t('ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.CREATE.HEADER.TITLE') },
  ];
});

const inboxList = computed(() =>
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
  if (item.params) {
    router.push(
      `/app/accounts/${route.params.accountId}/settings/inboxes/${item.params.inboxId}/collaborators`
    );
  } else if (item.routeName) {
    router.push({ name: item.routeName });
  }
};

const handleSubmit = async formState => {
  try {
    const { inboxIds = [], ...policyData } = formState;

    const policy = await store.dispatch('assignmentPolicies/create', policyData);

    // Link selected inboxes in parallel (new policy, no conflict possible)
    if (inboxIds.length) {
      await Promise.allSettled(
        inboxIds.map(inboxId =>
          store.dispatch('assignmentPolicies/setInboxPolicy', {
            inboxId,
            policyId: policy.id,
          })
        )
      );
    }

    useAlert(t('ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.CREATE.API.SUCCESS_MESSAGE'));
    formRef.value?.resetForm();
    router.push({ name: 'agent_assignment_policy_index' });
  } catch {
    useAlert(t('ASSIGNMENT_POLICY.AGENT_ASSIGNMENT_POLICY.CREATE.API.ERROR_MESSAGE'));
  }
};

onMounted(() => {
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
      <AssignmentPolicyForm
        ref="formRef"
        mode="CREATE"
        :is-loading="uiFlags.isCreating"
        :inbox-list="inboxList"
        :is-inbox-loading="inboxUiFlags.isFetching"
        @submit="handleSubmit"
      />
    </template>
  </SettingsLayout>
</template>
