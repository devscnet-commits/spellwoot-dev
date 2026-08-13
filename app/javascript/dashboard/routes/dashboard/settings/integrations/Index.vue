<script setup>
import { useStoreGetters, useStore } from 'dashboard/composables/store';
import { computed, onMounted, ref } from 'vue';
import { useBranding } from 'shared/composables/useBranding';
import { picoSearch } from '@scmmishra/pico-search';
import { frontendURL } from 'dashboard/helper/URLHelper';
import Button from 'dashboard/components-next/button/Button.vue';
import IntegrationItem from './IntegrationItem.vue';
import SettingsLayout from '../SettingsLayout.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';

const store = useStore();
const getters = useStoreGetters();
const { replaceInstallationName } = useBranding();
const accountId = getters.getCurrentAccountId;

// Conector de sistemas da empresa para a IA (ERP/cobrança/CRM), dentro do hub de Integrações.
const aiSystemsUrl = computed(() =>
  frontendURL(`accounts/${accountId.value}/settings/integrations/ai_systems`)
);

const searchQuery = ref('');
const uiFlags = getters['integrations/getUIFlags'];

// A chave OpenAI passou a ser configurada apenas em "APIs & Credentials"
// (integrations-hub) — fonte única lida pelo agente de IA. Por isso o app OpenAI
// clássico não aparece mais aqui (segue existindo para features legadas).
const HIDDEN_INTEGRATIONS = ['openai'];
const integrationList = computed(() =>
  getters['integrations/getAppIntegrations'].value.filter(
    item => !HIDDEN_INTEGRATIONS.includes(item.id)
  )
);

const filteredIntegrationList = computed(() => {
  const query = searchQuery.value.trim();
  if (!query) return integrationList.value;
  return picoSearch(integrationList.value, query, ['name', 'description']);
});

onMounted(() => {
  store.dispatch('integrations/get');
});
</script>

<template>
  <SettingsLayout
    :is-loading="uiFlags.isFetching"
    :loading-message="$t('INTEGRATION_SETTINGS.LOADING')"
  >
    <template #header>
      <BaseSettingsHeader
        v-model:search-query="searchQuery"
        :title="$t('INTEGRATION_SETTINGS.HEADER')"
        :description="
          replaceInstallationName($t('INTEGRATION_SETTINGS.DESCRIPTION'))
        "
        :link-text="$t('INTEGRATION_SETTINGS.LEARN_MORE')"
        :search-placeholder="$t('INTEGRATION_SETTINGS.SEARCH_PLACEHOLDER')"
        feature-name="integrations"
      />
    </template>
    <template #body>
      <div class="flex-grow flex-shrink overflow-auto">
        <span
          v-if="!filteredIntegrationList.length && searchQuery"
          class="flex-1 flex items-center justify-center py-20 text-center text-body-main !text-base text-n-slate-11"
        >
          {{ $t('INTEGRATION_SETTINGS.NO_RESULTS') }}
        </span>
        <div
          v-else
          class="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4"
        >
          <div
            class="flex flex-col flex-1 p-4 m-px outline outline-n-container outline-1 bg-n-card rounded-xl"
          >
            <div class="flex items-start justify-between">
              <div
                class="flex h-12 w-12 mb-2 items-center justify-center rounded-md border border-n-weak bg-n-alpha-2 text-n-brand"
              >
                <span class="i-lucide-plug-zap size-6" />
              </div>
            </div>
            <div class="flex flex-col m-0 flex-1">
              <div
                class="font-medium mb-2 text-n-slate-12 flex justify-between items-center"
              >
                <span class="text-heading-3 text-n-slate-12">
                  {{ $t('AI_INTEGRATIONS.HUB_CARD_NAME') }}
                </span>
                <router-link :to="aiSystemsUrl">
                  <Button
                    :label="$t('INTEGRATION_APPS.CONFIGURE')"
                    icon="i-woot-settings"
                    link
                    xs
                  />
                </router-link>
              </div>
              <p class="text-n-slate-11 text-body-main">
                {{ $t('AI_INTEGRATIONS.HUB_CARD_DESC') }}
              </p>
            </div>
          </div>
          <IntegrationItem
            v-for="item in filteredIntegrationList"
            :id="item.id"
            :key="item.id"
            :logo="item.logo"
            :name="item.name"
            :description="item.description"
            :enabled="item.enabled"
          />
        </div>
      </div>
    </template>
  </SettingsLayout>
</template>
