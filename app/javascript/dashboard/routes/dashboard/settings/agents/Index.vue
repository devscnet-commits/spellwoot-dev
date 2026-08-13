<script setup>
import { useAlert } from 'dashboard/composables';
import { computed, onMounted, ref } from 'vue';
import Avatar from 'next/avatar/Avatar.vue';
import { useI18n } from 'vue-i18n';
import { picoSearch } from '@scmmishra/pico-search';
import {
  useStoreGetters,
  useStore,
  useMapGetter,
} from 'dashboard/composables/store';

import AddAgent from './AddAgent.vue';
import EditAgent from './EditAgent.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import SettingsLayout from '../SettingsLayout.vue';
import Button from 'dashboard/components-next/button/Button.vue';

const getters = useStoreGetters();
const store = useStore();
const { t } = useI18n();

const loading = ref({});
const showAddPopup = ref(false);
const showDeactivatePopup = ref(false);
const showEditPopup = ref(false);
const agentAPI = ref({ message: '' });
const currentAgent = ref({});
const searchQuery = ref('');

const deactivateConfirmText = computed(
  () => `${t('AGENT_MGMT.DEACTIVATE.CONFIRM.YES')} ${currentAgent.value.name}`
);
const deactivateRejectText = computed(
  () => `${t('AGENT_MGMT.DEACTIVATE.CONFIRM.NO')} ${currentAgent.value.name}`
);
const deactivateMessage = computed(() => ` ${currentAgent.value.name}?`);

const agentList = computed(() => getters['agents/getAgents'].value);

const filteredAgentList = computed(() => {
  const query = searchQuery.value.trim();
  if (!query) return agentList.value;
  return picoSearch(agentList.value, query, ['name', 'email']);
});

const uiFlags = computed(() => getters['agents/getUIFlags'].value);
const currentUserId = computed(() => getters.getCurrentUserID.value);
const customRoles = useMapGetter('customRole/getCustomRoles');

onMounted(() => {
  store.dispatch('agents/get');
  store.dispatch('customRole/getCustomRole');
});

const findCustomRole = agent =>
  customRoles.value.find(role => role.id === agent.custom_role_id);

const getAgentRoleName = agent => {
  if (!agent.custom_role_id) {
    return t(`AGENT_MGMT.AGENT_TYPES.${agent.role.toUpperCase()}`);
  }
  const customRole = findCustomRole(agent);
  return customRole ? customRole.name : '';
};

const getAgentRolePermissions = agent => {
  if (!agent.custom_role_id) {
    return [];
  }
  const customRole = findCustomRole(agent);
  return customRole?.permissions || [];
};

const verifiedAdministrators = computed(() => {
  return agentList.value.filter(
    agent => agent.role === 'administrator' && agent.confirmed
  );
});

const showEditAction = agent => {
  return currentUserId.value !== agent.id;
};

const showDeactivateAction = agent => {
  if (currentUserId.value === agent.id) return false;
  if (agent.role === 'administrator' && verifiedAdministrators.value.length === 1) return false;
  return true;
};

const showAlertMessage = message => {
  loading.value[currentAgent.value.id] = false;
  currentAgent.value = {};
  agentAPI.value.message = message;
  useAlert(message);
};

const openAddPopup = () => {
  showAddPopup.value = true;
};
const hideAddPopup = () => {
  showAddPopup.value = false;
};

const openEditPopup = agent => {
  showEditPopup.value = true;
  currentAgent.value = agent;
};
const hideEditPopup = () => {
  showEditPopup.value = false;
};

const openDeactivatePopup = agent => {
  showDeactivatePopup.value = true;
  currentAgent.value = agent;
};
const closeDeactivatePopup = () => {
  showDeactivatePopup.value = false;
};

const toggleAgentActive = async agent => {
  try {
    if (agent.active === false) {
      await store.dispatch('agents/reactivate', agent.id);
      showAlertMessage(t('AGENT_MGMT.DEACTIVATE.API.REACTIVATE_SUCCESS_MESSAGE'));
    } else {
      loading.value[agent.id] = true;
      closeDeactivatePopup();
      await store.dispatch('agents/deactivate', agent.id);
      showAlertMessage(t('AGENT_MGMT.DEACTIVATE.API.SUCCESS_MESSAGE'));
    }
  } catch (error) {
    showAlertMessage(t('AGENT_MGMT.DEACTIVATE.API.ERROR_MESSAGE'));
  } finally {
    loading.value[currentAgent.value.id] = false;
    currentAgent.value = {};
  }
};

const confirmDeactivation = () => {
  loading.value[currentAgent.value.id] = true;
  toggleAgentActive(currentAgent.value);
};
</script>

<template>
  <SettingsLayout
    :is-loading="uiFlags.isFetching"
    :loading-message="$t('AGENT_MGMT.LOADING')"
    :no-records-found="!agentList.length"
    :no-records-message="$t('AGENT_MGMT.LIST.404')"
  >
    <template #header>
      <BaseSettingsHeader
        v-model:search-query="searchQuery"
        :title="$t('AGENT_MGMT.HEADER')"
        :description="$t('AGENT_MGMT.DESCRIPTION')"
        :link-text="$t('AGENT_MGMT.LEARN_MORE')"
        :search-placeholder="$t('AGENT_MGMT.SEARCH_PLACEHOLDER')"
        feature-name="agents"
      >
        <template v-if="agentList?.length" #count>
          <span class="text-body-main text-n-slate-11">
            {{ $t('AGENT_MGMT.COUNT', { n: agentList.length }) }}
          </span>
        </template>
        <template #actions>
          <Button
            :label="$t('AGENT_MGMT.HEADER_BTN_TXT')"
            size="sm"
            @click="openAddPopup"
          />
        </template>
      </BaseSettingsHeader>
    </template>
    <template #body>
      <span
        v-if="!filteredAgentList.length && searchQuery"
        class="flex-1 flex items-center justify-center py-20 text-center text-body-main !text-base text-n-slate-11"
      >
        {{ $t('AGENT_MGMT.NO_RESULTS') }}
      </span>
      <div v-else class="divide-y divide-n-weak border-t border-n-weak">
        <div
          v-for="(agent, index) in filteredAgentList"
          :key="agent.email"
          class="flex justify-between flex-row items-start gap-4 py-4"
        >
          <div class="flex items-center gap-4">
            <Avatar
              :src="agent.thumbnail"
              :name="agent.name"
              :status="agent.availability_status"
              :size="40"
              hide-offline-status
            />
            <div class="flex flex-col gap-1.5 items-start">
              <div class="flex items-center gap-2">
                <span class="block text-heading-3 text-n-slate-12 capitalize">
                  {{ agent.name }}
                </span>
                <span
                  v-if="agent.active === false"
                  class="inline-flex text-xs font-semibold text-n-slate-11 bg-n-alpha-2 border border-n-weak px-1.5 rounded leading-5"
                >
                  {{ $t('AGENT_MGMT.LIST.INACTIVE') }}
                </span>
              </div>
              <div class="flex items-center gap-2">
                <span class="text-body-main text-n-slate-11">
                  {{ agent.email }}
                </span>
                <div class="w-px h-3 bg-n-strong rounded-lg" />
                <span
                  class="block w-fit text-body-main text-n-slate-11 relative"
                  :class="{
                    'hover:text-n-slate-12 group cursor-pointer':
                      agent.custom_role_id,
                  }"
                >
                  {{ getAgentRoleName(agent) }}

                  <div
                    class="absolute ltr:left-0 rtl:right-0 z-10 hidden w-[300px] bg-n-alpha-3 backdrop-blur-[100px] rounded-xl outline outline-1 outline-n-container shadow-lg top-14 md:top-12"
                    :class="{ 'group-hover:block': agent.custom_role_id }"
                  >
                    <div class="flex flex-col gap-1 p-4">
                      <span class="text-heading-3 text-n-slate-12">
                        {{ $t('AGENT_MGMT.LIST.AVAILABLE_CUSTOM_ROLE') }}
                      </span>
                      <ul class="ltr:pl-4 rtl:pr-4 mb-0 list-disc">
                        <li
                          v-for="permission in getAgentRolePermissions(agent)"
                          :key="permission"
                          class="text-body-main text-n-slate-11"
                        >
                          {{
                            $t(
                              `CUSTOM_ROLE.PERMISSIONS.${permission.toUpperCase()}`
                            )
                          }}
                        </li>
                      </ul>
                    </div>
                  </div>
                </span>
                <div class="w-px h-3 bg-n-strong rounded-lg" />
                <span
                  v-if="agent.confirmed"
                  class="text-body-main text-n-slate-11"
                >
                  {{ $t('AGENT_MGMT.LIST.VERIFIED') }}
                </span>
                <span
                  v-if="!agent.confirmed"
                  class="text-body-main text-n-slate-11"
                >
                  {{ $t('AGENT_MGMT.LIST.VERIFICATION_PENDING') }}
                </span>
              </div>
            </div>
          </div>
          <div class="flex justify-end gap-3">
            <Button
              v-if="showEditAction(agent)"
              v-tooltip.top="$t('AGENT_MGMT.EDIT.BUTTON_TEXT')"
              icon="i-woot-edit-pen"
              slate
              sm
              @click="openEditPopup(agent)"
            />
            <Button
              v-if="showDeactivateAction(agent) && agent.active === false"
              v-tooltip.top="$t('AGENT_MGMT.DEACTIVATE.REACTIVATE_BUTTON_TEXT')"
              icon="i-lucide-user-check"
              slate
              sm
              :is-loading="loading[agent.id]"
              @click="toggleAgentActive(agent)"
            />
            <Button
              v-else-if="showDeactivateAction(agent)"
              v-tooltip.top="$t('AGENT_MGMT.DEACTIVATE.BUTTON_TEXT')"
              icon="i-lucide-user-x"
              slate
              sm
              class="hover:enabled:text-n-amber-11 hover:enabled:bg-n-amber-2"
              :is-loading="loading[agent.id]"
              @click="openDeactivatePopup(agent)"
            />
          </div>
        </div>
      </div>
    </template>

    <woot-modal v-model:show="showAddPopup" :on-close="hideAddPopup">
      <AddAgent @close="hideAddPopup" />
    </woot-modal>

    <woot-modal v-model:show="showEditPopup" :on-close="hideEditPopup">
      <EditAgent
        v-if="showEditPopup"
        :id="currentAgent.id"
        :name="currentAgent.name"
        :provider="currentAgent.provider"
        :type="currentAgent.role"
        :email="currentAgent.email"
        :custom-role-id="currentAgent.custom_role_id"
        @close="hideEditPopup"
      />
    </woot-modal>

    <woot-delete-modal
      v-model:show="showDeactivatePopup"
      :on-close="closeDeactivatePopup"
      :on-confirm="confirmDeactivation"
      :title="$t('AGENT_MGMT.DEACTIVATE.CONFIRM.TITLE')"
      :message="$t('AGENT_MGMT.DEACTIVATE.CONFIRM.MESSAGE')"
      :message-value="deactivateMessage"
      :confirm-text="deactivateConfirmText"
      :reject-text="deactivateRejectText"
    />
  </SettingsLayout>
</template>
