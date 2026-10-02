<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { vOnClickOutside } from '@vueuse/components';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import {
  TEMPERATURES,
  temperatureOf,
  formatDuration,
  formatMoney,
} from '../helpers';

const props = defineProps({
  card: { type: Object, required: true },
  // Minutes of silence after which the stage's AI follow-up starts; null = default threshold.
  aiFollowupDelay: { type: Number, default: null },
  now: { type: Number, required: true },
});

const emit = defineEmits(['open', 'setTemperature', 'aiFollowup']);

const { t } = useI18n();

const DEFAULT_INACTIVITY_MINUTES = 24 * 60;

const showTemperatureMenu = ref(false);

const temperature = computed(() => temperatureOf(props.card.temperature));

const lastAt = computed(
  () => props.card.last_message?.created_at || props.card.last_activity_at
);

const inactiveSeconds = computed(() => props.now / 1000 - lastAt.value);

const isInactive = computed(
  () =>
    inactiveSeconds.value >=
    (props.aiFollowupDelay ?? DEFAULT_INACTIVITY_MINUTES) * 60
);

const sla = computed(() => {
  if (props.card.sla_status === 'none') {
    return { label: t('CRM_PIPELINE.CARD.NO_SLA'), class: 'text-n-slate-10' };
  }
  const remaining = props.card.sla_due_at - props.now / 1000;
  if (remaining <= 0) {
    return {
      label: t('CRM_PIPELINE.CARD.SLA_BREACHED'),
      class: 'text-n-ruby-11 font-medium',
    };
  }
  return {
    label: t('CRM_PIPELINE.CARD.SLA_REMAINING', {
      time: formatDuration(remaining),
    }),
    class: 'text-n-slate-11',
  };
});

const senderName = computed(() => {
  const message = props.card.last_message;
  if (!message) return '';
  return message.sender_name || t('CRM_PIPELINE.CARD.AI_SENDER');
});

const subtitle = computed(() =>
  [props.card.contact.phone_number, props.card.contact.location]
    .filter(Boolean)
    .join(' · ')
);

const pickTemperature = value => {
  showTemperatureMenu.value = false;
  emit('setTemperature', value === props.card.temperature ? null : value);
};
</script>

<template>
  <div
    class="flex flex-col gap-2.5 p-3 rounded-xl border border-n-weak bg-n-solid-2 hover:border-n-strong cursor-grab active:cursor-grabbing"
  >
    <div class="flex items-start gap-2">
      <Avatar
        :name="card.contact.name || ''"
        :src="card.contact.thumbnail"
        :size="28"
        rounded-full
      />
      <div class="flex flex-col min-w-0 flex-1">
        <span class="text-sm font-semibold text-n-slate-12 truncate">
          {{ card.contact.name || card.contact.phone_number }}
        </span>
        <span
          v-if="subtitle"
          class="flex items-center gap-1 text-xs text-n-slate-11 truncate"
        >
          <span class="i-lucide-phone size-3 shrink-0" />
          <span class="truncate">{{ subtitle }}</span>
        </span>
      </div>
      <div class="relative shrink-0">
        <button
          type="button"
          class="flex items-center gap-1 text-xs font-medium px-1.5 py-0.5 rounded-md hover:bg-n-alpha-2"
          :class="temperature ? temperature.textClass : 'text-n-slate-10'"
          @click.stop="showTemperatureMenu = !showTemperatureMenu"
        >
          <span
            :class="temperature ? temperature.icon : 'i-lucide-thermometer'"
            class="size-3.5"
          />
          {{
            temperature
              ? $t(`CRM_PIPELINE.TEMPERATURE.${temperature.value}`)
              : $t('CRM_PIPELINE.TEMPERATURE.none')
          }}
        </button>
        <div
          v-if="showTemperatureMenu"
          v-on-click-outside="() => (showTemperatureMenu = false)"
          class="absolute z-20 mt-1 ltr:right-0 rtl:left-0 w-32 p-1 rounded-lg border border-n-weak bg-n-solid-3 shadow-lg"
        >
          <button
            v-for="option in TEMPERATURES"
            :key="option.value"
            type="button"
            class="flex w-full items-center gap-2 px-2 py-1.5 text-xs rounded-md hover:bg-n-alpha-2"
            :class="option.textClass"
            @click.stop="pickTemperature(option.value)"
          >
            <span :class="option.icon" class="size-3.5" />
            {{ $t(`CRM_PIPELINE.TEMPERATURE.${option.value}`) }}
            <span
              v-if="option.value === card.temperature"
              class="i-lucide-check size-3 ltr:ml-auto rtl:mr-auto"
            />
          </button>
        </div>
      </div>
    </div>

    <p
      v-if="card.last_message"
      class="px-2.5 py-2 mb-0 rounded-lg bg-n-alpha-1 text-xs text-n-slate-11 line-clamp-2 break-words"
    >
      <span class="font-semibold text-n-slate-12">
        {{ $t('CRM_PIPELINE.CARD.SENDER', { name: senderName }) }}
      </span>
      <em class="ltr:ml-1 rtl:mr-1">{{ card.last_message.content }}</em>
    </p>

    <div
      v-if="isInactive"
      class="flex items-center justify-between gap-2 px-2.5 py-1.5 rounded-lg border border-n-amber-6 bg-n-amber-2"
    >
      <span class="flex items-center gap-1.5 text-xs text-n-amber-11">
        <span class="i-lucide-triangle-alert size-3.5" />
        {{
          $t('CRM_PIPELINE.CARD.INACTIVE_FOR', {
            time: formatDuration(inactiveSeconds),
          })
        }}
      </span>
      <button
        type="button"
        class="flex items-center gap-1 px-2 py-0.5 text-xs font-medium rounded-md border border-n-amber-7 text-n-amber-11 hover:bg-n-amber-3"
        @click.stop="emit('aiFollowup')"
      >
        <span class="i-lucide-sparkles size-3" />
        {{ $t('CRM_PIPELINE.CARD.AI_FOLLOWUP') }}
      </button>
    </div>

    <div class="flex items-center justify-between gap-2">
      <div class="flex items-center gap-2 min-w-0">
        <span
          class="flex items-center gap-1 text-xs truncate"
          :class="sla.class"
        >
          <span class="i-lucide-clock size-3 shrink-0" />
          {{ sla.label }}
        </span>
        <span
          v-if="card.deal_value"
          class="text-xs font-medium text-n-teal-11 truncate"
        >
          {{ formatMoney(card.deal_value) }}
        </span>
      </div>
      <div class="flex items-center gap-2 shrink-0">
        <Avatar
          v-if="card.assignee"
          v-tooltip.top="card.assignee.name"
          :name="card.assignee.name"
          :src="card.assignee.thumbnail"
          :size="20"
          rounded-full
        />
        <button
          v-tooltip.top="$t('CRM_PIPELINE.CARD.OPEN_CONVERSATION')"
          type="button"
          class="flex items-center justify-center size-6 rounded-md text-n-slate-11 hover:bg-n-alpha-2 hover:text-n-slate-12"
          @click.stop="emit('open')"
        >
          <span class="i-lucide-message-square size-3.5" />
        </button>
      </div>
    </div>
  </div>
</template>
