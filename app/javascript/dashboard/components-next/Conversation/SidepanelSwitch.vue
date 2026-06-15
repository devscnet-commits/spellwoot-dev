<script setup>
import Button from 'dashboard/components-next/button/Button.vue';
import ButtonGroup from 'dashboard/components-next/buttonGroup/ButtonGroup.vue';
import { useUISettings } from 'dashboard/composables/useUISettings';
import { computed } from 'vue';
import { useKeyboardEvents } from 'dashboard/composables/useKeyboardEvents';

const { updateUISettings } = useUISettings();

const { uiSettings } = useUISettings();
const isContactSidebarOpen = computed(
  () => uiSettings.value.is_contact_sidebar_open
);

// Single toggle: opens the contact panel when closed, closes it when open (so the button
// doubles as the X). Shared by the click and the Alt+O shortcut.
const toggleConversationSidebarToggle = () => {
  updateUISettings({
    is_contact_sidebar_open: !isContactSidebarOpen.value,
    is_copilot_panel_open: false,
  });
};

const keyboardEvents = {
  'Alt+KeyO': {
    action: toggleConversationSidebarToggle,
  },
};
useKeyboardEvents(keyboardEvents);
</script>

<template>
  <ButtonGroup
    class="flex flex-col justify-center items-center absolute top-36 xl:top-24 ltr:right-3 rtl:left-3 bg-n-solid-2/90 backdrop-blur-lg border border-n-weak rounded-full gap-1.5 p-1.5 shadow-md transition-shadow duration-200 hover:shadow-lg !z-20"
  >
    <Button
      v-tooltip.top="$t('CONVERSATION.SIDEBAR.CONTACT')"
      faded
      slate
      md
      class="!rounded-full transition-all duration-[250ms] ease-out active:!scale-95 active:!brightness-105 active:duration-75 [&_.i-ph-user-bold]:size-6"
      :class="{
        '!bg-n-brand/20 !text-n-blue-11': isContactSidebarOpen,
      }"
      icon="i-ph-user-bold"
      @click="toggleConversationSidebarToggle"
    />
  </ButtonGroup>
</template>
