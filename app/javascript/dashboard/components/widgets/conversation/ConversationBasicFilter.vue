<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useToggle } from '@vueuse/core';
import { vOnClickOutside } from '@vueuse/components';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { useMapGetter, useStore } from 'dashboard/composables/store.js';
import wootConstants from 'dashboard/constants/globals';
import SelectMenu from 'dashboard/components-next/selectmenu/SelectMenu.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

defineProps({
  isOnExpandedLayout: {
    type: Boolean,
    required: true,
  },
});

const emit = defineEmits(['changeFilter']);

const store = useStore();
const { t } = useI18n();

const { updateUISettings } = useUISettings();

const chatStatusFilter = useMapGetter('getChatStatusFilter');
const chatSortFilter = useMapGetter('getChatSortFilter');
const chatReopenedFilter = useMapGetter('getChatReopenedFilter');

const [showActionsDropdown, toggleDropdown] = useToggle();

const currentStatusFilter = computed(() => {
  return chatStatusFilter.value || wootConstants.STATUS_TYPE.OPEN;
});

const currentSortBy = computed(() => {
  return (
    chatSortFilter.value || wootConstants.SORT_BY_TYPE.LAST_ACTIVITY_AT_DESC
  );
});

const currentOriginFilter = computed(() => chatReopenedFilter.value || 'all');

const chatStatusOptions = computed(() => [
  {
    label: t('CHAT_LIST.CHAT_STATUS_FILTER_ITEMS.open.TEXT'),
    value: 'open',
  },
  {
    label: t('CHAT_LIST.CHAT_STATUS_FILTER_ITEMS.resolved.TEXT'),
    value: 'resolved',
  },
  {
    label: t('CHAT_LIST.CHAT_STATUS_FILTER_ITEMS.all.TEXT'),
    value: 'all',
  },
]);

const sortHeader = key => ({
  type: 'header',
  value: `header-${key}`,
  label: t(`CHAT_LIST.SORT_GROUPS.${key}`),
});
const sortItem = value => ({
  value,
  label: t(`CHAT_LIST.SORT_SHORT.${value}`),
});

// Grouped by criterion with short option labels — nine full sentences in a flat
// list were unscannable.
const chatSortOptions = computed(() => [
  sortHeader('last_activity'),
  sortItem('last_activity_at_desc'),
  sortItem('last_activity_at_asc'),
  sortHeader('created_at'),
  sortItem('created_at_desc'),
  sortItem('created_at_asc'),
  sortHeader('priority'),
  sortItem('priority_desc'),
  sortItem('priority_asc'),
  sortItem('priority_desc_created_at_asc'),
  sortHeader('waiting_since'),
  sortItem('waiting_since_asc'),
  sortItem('waiting_since_desc'),
]);

const activeChatStatusLabel = computed(
  () =>
    chatStatusOptions.value.find(m => m.value === chatStatusFilter.value)
      ?.label || ''
);

// The trigger shows the full sentence (group + direction) since the menu groups
// are not visible when closed.
const activeChatSortLabel = computed(() =>
  t(`CHAT_LIST.SORT_ORDER_ITEMS.${currentSortBy.value}.TEXT`)
);

const chatOriginOptions = computed(() => [
  {
    label: t('CHAT_LIST.CHAT_ORIGIN_FILTER_ITEMS.all.TEXT'),
    value: 'all',
  },
  {
    label: t('CHAT_LIST.CHAT_ORIGIN_FILTER_ITEMS.reopened.TEXT'),
    value: 'reopened',
  },
]);

const activeOriginLabel = computed(
  () =>
    chatOriginOptions.value.find(m => m.value === currentOriginFilter.value)
      ?.label || ''
);

const saveSelectedFilter = (type, value) => {
  updateUISettings({
    conversations_filter_by: {
      status: type === 'status' ? value : currentStatusFilter.value,
      order_by: type === 'sort' ? value : currentSortBy.value,
    },
  });
};

const handleStatusChange = value => {
  emit('changeFilter', value, 'status');
  store.dispatch('setChatStatusFilter', value);
  saveSelectedFilter('status', value);
};

const handleSortChange = value => {
  emit('changeFilter', value, 'sort');
  store.dispatch('setChatSortFilter', value);
  saveSelectedFilter('sort', value);
};

const handleOriginChange = value => {
  emit('changeFilter', value, 'origin');
  store.dispatch('setChatReopenedFilter', value);
};
</script>

<template>
  <div class="relative flex">
    <NextButton
      v-tooltip.right="$t('CHAT_LIST.SORT_TOOLTIP_LABEL')"
      icon="i-lucide-arrow-up-down"
      slate
      faded
      xs
      @click="toggleDropdown()"
    />
    <div
      v-if="showActionsDropdown"
      v-on-click-outside="() => toggleDropdown()"
      class="mt-1 bg-n-alpha-3 backdrop-blur-[100px] border border-n-weak w-72 rounded-xl p-4 absolute z-40 top-full"
      :class="{
        'ltr:left-0 rtl:right-0': !isOnExpandedLayout,
        'ltr:right-0 rtl:left-0': isOnExpandedLayout,
      }"
    >
      <div class="flex items-center justify-between last:mt-4 gap-2">
        <span class="text-sm truncate text-n-slate-12">
          {{ $t('CHAT_LIST.CHAT_SORT.STATUS') }}
        </span>
        <SelectMenu
          :model-value="chatStatusFilter"
          :options="chatStatusOptions"
          :label="activeChatStatusLabel"
          :sub-menu-position="isOnExpandedLayout ? 'left' : 'right'"
          @update:model-value="handleStatusChange"
        />
      </div>
      <div class="flex items-center justify-between last:mt-4 gap-2">
        <span class="text-sm truncate text-n-slate-12">
          {{ $t('CHAT_LIST.CHAT_SORT.ORDER_BY') }}
        </span>
        <SelectMenu
          :model-value="chatSortFilter"
          :options="chatSortOptions"
          :label="activeChatSortLabel"
          :sub-menu-position="isOnExpandedLayout ? 'left' : 'right'"
          @update:model-value="handleSortChange"
        />
      </div>
      <div class="flex items-center justify-between last:mt-4 gap-2">
        <span class="text-sm truncate text-n-slate-12">
          {{ $t('CHAT_LIST.CHAT_SORT.ORIGIN') }}
        </span>
        <SelectMenu
          :model-value="currentOriginFilter"
          :options="chatOriginOptions"
          :label="activeOriginLabel"
          :sub-menu-position="isOnExpandedLayout ? 'left' : 'right'"
          @update:model-value="handleOriginChange"
        />
      </div>
    </div>
  </div>
</template>
