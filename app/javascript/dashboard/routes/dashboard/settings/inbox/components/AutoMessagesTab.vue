<script setup>
import WootMessageEditor from 'dashboard/components/widgets/WootWriter/Editor.vue';

defineProps({
  outOfOfficeMessage: { type: String, default: '' },
  intervalMessage:    { type: String, default: '' },
  holidayMessage:     { type: String, default: '' },
  isRichEditorEnabled: { type: Boolean, default: true },
});

const emit = defineEmits(['update:outOfOfficeMessage', 'update:intervalMessage', 'update:holidayMessage']);
</script>

<template>
  <div class="flex flex-col gap-6">
    <!-- Out of office -->
    <div class="flex flex-col gap-2">
      <div>
        <p class="text-heading-3 text-n-slate-12 font-medium">
          {{ $t('INBOX_MGMT.BUSINESS_HOURS.MESSAGES.OUT_OF_OFFICE_TITLE') }}
        </p>
        <p class="text-body-main text-n-slate-10 mt-0.5">
          {{ $t('INBOX_MGMT.BUSINESS_HOURS.MESSAGES.OUT_OF_OFFICE_HELP') }}
        </p>
      </div>
      <WootMessageEditor
        v-if="isRichEditorEnabled"
        :model-value="outOfOfficeMessage"
        enable-variables
        is-format-mode
        :placeholder="$t('INBOX_MGMT.BUSINESS_HOURS.UNAVAILABLE_MESSAGE_LABEL')"
        :min-height="3"
        @update:model-value="v => emit('update:outOfOfficeMessage', v)"
      />
      <textarea
        v-else
        :value="outOfOfficeMessage"
        class="min-h-[4rem] mt-1.5"
        @input="e => emit('update:outOfOfficeMessage', e.target.value)"
      />
    </div>

    <div class="h-px bg-n-weak" />

    <!-- Interval (lunch / between periods) -->
    <div class="flex flex-col gap-2">
      <div>
        <p class="text-heading-3 text-n-slate-12 font-medium">
          {{ $t('INBOX_MGMT.BUSINESS_HOURS.MESSAGES.INTERVAL_TITLE') }}
        </p>
        <p class="text-body-main text-n-slate-10 mt-0.5">
          {{ $t('INBOX_MGMT.BUSINESS_HOURS.MESSAGES.INTERVAL_HELP') }}
        </p>
      </div>
      <WootMessageEditor
        v-if="isRichEditorEnabled"
        :model-value="intervalMessage"
        enable-variables
        is-format-mode
        :placeholder="$t('INBOX_MGMT.BUSINESS_HOURS.MESSAGES.INTERVAL_PLACEHOLDER')"
        :min-height="3"
        @update:model-value="v => emit('update:intervalMessage', v)"
      />
      <textarea
        v-else
        :value="intervalMessage"
        class="min-h-[4rem] mt-1.5"
        @input="e => emit('update:intervalMessage', e.target.value)"
      />
    </div>

    <div class="h-px bg-n-weak" />

    <!-- Holiday -->
    <div class="flex flex-col gap-2">
      <div>
        <p class="text-heading-3 text-n-slate-12 font-medium">
          {{ $t('INBOX_MGMT.BUSINESS_HOURS.MESSAGES.HOLIDAY_TITLE') }}
        </p>
        <p class="text-body-main text-n-slate-10 mt-0.5">
          {{ $t('INBOX_MGMT.BUSINESS_HOURS.MESSAGES.HOLIDAY_HELP') }}
        </p>
      </div>
      <WootMessageEditor
        v-if="isRichEditorEnabled"
        :model-value="holidayMessage"
        enable-variables
        is-format-mode
        :placeholder="$t('INBOX_MGMT.BUSINESS_HOURS.MESSAGES.HOLIDAY_PLACEHOLDER')"
        :min-height="3"
        @update:model-value="v => emit('update:holidayMessage', v)"
      />
      <textarea
        v-else
        :value="holidayMessage"
        class="min-h-[4rem] mt-1.5"
        @input="e => emit('update:holidayMessage', e.target.value)"
      />
    </div>
  </div>
</template>
