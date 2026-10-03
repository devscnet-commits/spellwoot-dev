<script setup>
import { ref, computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { vOnClickOutside } from '@vueuse/components';
import {
  useStore,
  useStoreGetters,
  useMapGetter,
} from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import { useAccount } from 'dashboard/composables/useAccount';
import { FEATURE_FLAGS } from 'dashboard/featureFlags';
import PipelineCardsAPI from 'dashboard/api/pipelineCards';
import {
  TEMPERATURES,
  temperatureOf,
} from 'dashboard/routes/dashboard/crm/helpers';

// Lead temperature chip of the conversation header: the same hot/warm/cold the kanban card
// shows, editable from inside the conversation so agents do not have to open the board.
const store = useStore();
const getters = useStoreGetters();
const { t } = useI18n();
const { accountId } = useAccount();
const isFeatureEnabledonAccount = useMapGetter(
  'accounts/isFeatureEnabledonAccount'
);

const currentChat = computed(() => getters.getSelectedChat.value);
const isDropdownOpen = ref(false);
const isLoading = ref(false);

// Temperature is a kanban concept: group chats never become cards, and without the CRM
// feature there is no board for the value to show up on.
const isVisible = computed(
  () =>
    !!currentChat.value?.id &&
    !currentChat.value.group_chat &&
    isFeatureEnabledonAccount.value(accountId.value, FEATURE_FLAGS.CRM_KANBAN)
);

const temperature = computed(() =>
  temperatureOf(currentChat.value?.temperature)
);

// Picking the current temperature clears it, mirroring the chip on the kanban card.
const selectTemperature = async value => {
  isDropdownOpen.value = false;
  if (isLoading.value) return;
  const chat = currentChat.value;
  const next = value === chat.temperature ? null : value;
  isLoading.value = true;
  try {
    await PipelineCardsAPI.setTemperature(chat.id, next);
    // Refresh the store copy so the chip updates at once instead of on the next reload.
    await store.dispatch('updateConversation', { ...chat, temperature: next });
  } catch {
    useAlert(t('CRM_PIPELINE.BOARD.TEMPERATURE_ERROR'));
  } finally {
    isLoading.value = false;
  }
};
</script>

<template>
  <div
    v-if="isVisible"
    v-on-click-outside="() => (isDropdownOpen = false)"
    class="relative"
  >
    <button
      type="button"
      class="flex items-center gap-1.5 h-10 px-3 rounded-lg text-sm font-medium transition-opacity border border-n-weak bg-n-solid-1"
      :class="[
        temperature ? temperature.textClass : 'text-n-slate-11',
        isLoading ? 'opacity-50 cursor-not-allowed' : 'hover:opacity-80',
      ]"
      :disabled="isLoading"
      @click="isDropdownOpen = !isDropdownOpen"
    >
      <span
        class="size-3.5"
        :class="[temperature ? temperature.icon : 'i-lucide-thermometer']"
      />
      {{
        temperature
          ? $t(`CRM_PIPELINE.TEMPERATURE.${temperature.value}`)
          : $t('CRM_PIPELINE.TEMPERATURE.none')
      }}
      <span class="i-lucide-chevron-down size-3 opacity-70" />
    </button>

    <div
      v-if="isDropdownOpen"
      class="absolute top-full mt-1 right-0 z-50 flex flex-col gap-0.5 p-1 rounded-lg border border-n-weak bg-n-solid-1 shadow-lg min-w-36"
    >
      <button
        v-for="option in TEMPERATURES"
        :key="option.value"
        type="button"
        class="flex items-center gap-2 w-full px-3 py-2 rounded-md text-sm transition-colors text-left hover:bg-n-alpha-2"
        :class="[
          option.value === currentChat.temperature
            ? [option.textClass, 'font-medium bg-n-alpha-1']
            : 'text-n-slate-12',
        ]"
        @click="selectTemperature(option.value)"
      >
        <span
          class="size-4 shrink-0"
          :class="[option.icon, option.textClass]"
        />
        {{ $t(`CRM_PIPELINE.TEMPERATURE.${option.value}`) }}
        <span
          v-if="option.value === currentChat.temperature"
          class="i-lucide-check size-3 ltr:ml-auto rtl:mr-auto"
        />
      </button>
    </div>
  </div>
</template>
