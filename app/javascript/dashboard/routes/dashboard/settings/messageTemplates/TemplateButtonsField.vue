<script setup>
import { ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { vOnClickOutside } from '@vueuse/components';

import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';

const props = defineProps({
  buttonTypeOptions: { type: Array, default: () => [] },
  buttonTypeLabels: { type: Object, default: () => ({}) },
  maxButtons: { type: Number, default: 10 },
});

const buttons = defineModel({ type: Array, default: () => [] });

const BUTTON_TEXT_MAX_LENGTH = 25;
// Meta fixes the button text for these two ("View catalog" / "Copy Pix code") and rejects a
// custom one, so there's nothing to let the user edit here.
const FIXED_TEXT_BUTTON_TYPES = ['CATALOG', 'ORDER_DETAILS'];

const { t } = useI18n();
const isAddMenuOpen = ref(false);

const addMenuItems = () =>
  props.buttonTypeOptions.map(option => ({
    action: 'add_button',
    value: option.value,
    label: option.label,
  }));

const addButton = type => {
  if (buttons.value.length >= props.maxButtons) return;

  buttons.value = [
    ...buttons.value,
    {
      type,
      text: '',
      url: '',
      phone_number: '',
      example: '',
      flow_id: '',
      navigate_screen: '',
    },
  ];
  isAddMenuOpen.value = false;
};

const handleAddMenuAction = ({ value }) => addButton(value);

const removeButton = index => {
  buttons.value = buttons.value.filter((_, i) => i !== index);
};
</script>

<template>
  <div class="space-y-2">
    <div class="flex items-center gap-1.5">
      <h3 class="font-semibold text-n-slate-12">
        {{ t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.TITLE') }}
      </h3>
      <span class="text-caption text-n-slate-10">
        · {{ t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.OPTIONAL_BADGE') }}
      </span>
    </div>
    <p class="text-body-main text-n-slate-11">
      {{
        t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.DESCRIPTION', {
          count: maxButtons,
        })
      }}
    </p>

    <div
      v-if="buttons.length < maxButtons"
      v-on-click-outside="() => (isAddMenuOpen = false)"
      class="relative"
    >
      <Button
        :label="t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.ADD_BUTTON')"
        icon="i-lucide-plus"
        size="sm"
        @click="isAddMenuOpen = !isAddMenuOpen"
      />
      <DropdownMenu
        v-if="isAddMenuOpen"
        class="top-full ltr:left-0 rtl:right-0 mt-1.5 max-w-64"
        :menu-items="addMenuItems()"
        @action="handleAddMenuAction"
      />
    </div>
    <p v-else class="text-body-main text-n-slate-11">
      {{
        t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.MAX_REACHED', {
          count: maxButtons,
        })
      }}
    </p>

    <div
      v-for="(button, index) in buttons"
      :key="index"
      class="p-3 space-y-2 border rounded-lg border-n-weak"
    >
      <div class="flex items-center justify-between">
        <span
          class="flex items-center gap-2 font-medium text-body-main text-n-slate-12"
        >
          <span
            class="flex items-center justify-center flex-shrink-0 text-xs font-semibold rounded-full size-5 bg-n-blue-3 text-n-blue-11"
          >
            {{ index + 1 }}
          </span>
          {{ buttonTypeLabels[button.type] }}
        </span>
        <Button
          icon="i-lucide-trash-2"
          variant="ghost"
          color="ruby"
          size="xs"
          @click="removeButton(index)"
        />
      </div>

      <Input
        v-if="!FIXED_TEXT_BUTTON_TYPES.includes(button.type)"
        v-model="button.text"
        :label="
          t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.TEXT', {
            count: BUTTON_TEXT_MAX_LENGTH,
          })
        "
        :max-length="BUTTON_TEXT_MAX_LENGTH"
      />
      <p v-else class="text-caption text-n-slate-10">
        {{ t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIXED_TEXT_HINT') }}
      </p>

      <Input
        v-if="button.type === 'URL'"
        v-model="button.url"
        :label="t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.URL')"
      />

      <Input
        v-if="button.type === 'PHONE_NUMBER'"
        v-model="button.phone_number"
        :label="
          t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.PHONE_NUMBER')
        "
      />

      <Input
        v-if="button.type === 'COPY_CODE'"
        v-model="button.example"
        :label="
          t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.EXAMPLE_CODE')
        "
      />

      <Input
        v-if="button.type === 'FLOW'"
        v-model="button.flow_id"
        :label="
          t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.FLOW_ID')
        "
        :message="
          t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.FLOW_ID_HINT')
        "
      />
      <Input
        v-if="button.type === 'FLOW'"
        v-model="button.navigate_screen"
        :label="
          t(
            'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.NAVIGATE_SCREEN'
          )
        "
      />
    </div>
  </div>
</template>
