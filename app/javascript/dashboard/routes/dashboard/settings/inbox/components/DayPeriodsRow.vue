<script setup>
import { computed, ref } from 'vue';
import { generateTimeSlots, scheduleTemplates } from '../helpers/businessHour';
import NextSelect from 'dashboard/components-next/select/Select.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

const timeSlots = generateTimeSlots(30);

const groupByPeriod = slots =>
  ['AM', 'PM'].map(period => ({
    label: period,
    options: slots.filter(s => s.endsWith(period)).map(s => ({ value: s, label: s })),
  })).filter(g => g.options.length);

const allTimeGroups = groupByPeriod(timeSlots);
const toTimeGroups  = groupByPeriod(timeSlots.filter(s => s !== '12:00 AM'));

const COPY_OPTIONS = [
  { value: 'weekdays',  label: 'Segunda a Sexta' },
  { value: 'all',       label: 'Todos os dias' },
  { value: 'weekend',   label: 'Fim de semana' },
  { value: 'custom',    label: 'Selecionar dias...' },
];

const DAY_LABELS = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb'];

const props = defineProps({
  dayName:  { type: String,  required: true },
  dayIndex: { type: Number,  required: true },
  slot:     { type: Object,  required: true }, // { day, enabled, periods: [{from, to}] }
});

const emit = defineEmits(['update', 'copy-to']);

const showTemplates = ref(false);
const showCopy      = ref(false);
const showCustom    = ref(false);
const customDays    = ref([]);

const enabled = computed({
  get: () => props.slot.enabled,
  set: val => emit('update', { ...props.slot, enabled: val, periods: val && !props.slot.periods.length ? [{ from: '09:00 AM', to: '06:00 PM' }] : props.slot.periods }),
});

function updatePeriod(idx, field, value) {
  const periods = props.slot.periods.map((p, i) => i === idx ? { ...p, [field]: value } : p);
  emit('update', { ...props.slot, periods });
}

function addPeriod() {
  const last = props.slot.periods[props.slot.periods.length - 1];
  const next = last ? { from: last.to, to: '' } : { from: '09:00 AM', to: '06:00 PM' };
  emit('update', { ...props.slot, periods: [...props.slot.periods, next] });
}

function removePeriod(idx) {
  emit('update', { ...props.slot, periods: props.slot.periods.filter((_, i) => i !== idx) });
}

function applyTemplate(tpl) {
  emit('update', { ...props.slot, enabled: true, periods: tpl.periods.map(p => ({ ...p })) });
  showTemplates.value = false;
}

function applyCopy(option) {
  if (option === 'custom') {
    customDays.value = [];
    showCustom.value = true;
    showCopy.value   = false;
    return;
  }
  const targets = {
    weekdays: [1, 2, 3, 4, 5],
    all:      [0, 1, 2, 3, 4, 5, 6],
    weekend:  [0, 6],
  }[option] || [];
  emit('copy-to', { from: props.dayIndex, to: targets.filter(d => d !== props.dayIndex) });
  showCopy.value = false;
}

function applyCustomCopy() {
  emit('copy-to', { from: props.dayIndex, to: customDays.value });
  showCustom.value = false;
}

function hasError(p) {
  if (!p.from || !p.to) return false;
  const toMin = (s) => {
    const d = new Date(`1970-01-01 ${s}`);
    return d.getHours() * 60 + d.getMinutes();
  };
  return toMin(p.to) <= toMin(p.from);
}
</script>

<template>
  <div class="flex flex-col gap-1.5 py-3 border-b border-n-weak last:border-0">
    <div class="flex items-start gap-3">
      <!-- Day toggle -->
      <div class="flex items-center gap-2 w-36 pt-1 flex-shrink-0">
        <input v-model="enabled" type="checkbox" class="m-0" />
        <span class="text-body-main text-n-slate-12 font-medium">{{ dayName }}</span>
      </div>

      <!-- Periods -->
      <div class="flex-1 flex flex-col gap-1.5">
        <template v-if="enabled">
          <div v-for="(period, idx) in slot.periods" :key="idx" class="flex items-center gap-2">
            <NextSelect
              :model-value="period.from"
              :groups="allTimeGroups"
              :placeholder="$t('INBOX_MGMT.BUSINESS_HOURS.DAY.CHOOSE')"
              class="w-32"
              @update:model-value="v => updatePeriod(idx, 'from', v)"
            />
            <span class="text-n-slate-11 text-sm">→</span>
            <NextSelect
              :model-value="period.to"
              :groups="toTimeGroups"
              :placeholder="$t('INBOX_MGMT.BUSINESS_HOURS.DAY.CHOOSE')"
              class="w-32"
              @update:model-value="v => updatePeriod(idx, 'to', v)"
            />
            <button
              type="button"
              v-if="slot.periods.length > 1"
              class="text-n-slate-10 hover:text-n-ruby-9 transition-colors"
              @click="removePeriod(idx)"
            >
              <span class="i-lucide-x size-4" />
            </button>
            <span v-if="hasError(period)" class="text-label-small text-n-ruby-9">
              {{ $t('INBOX_MGMT.BUSINESS_HOURS.DAY.VALIDATION_ERROR') }}
            </span>
          </div>

          <button
            type="button"
            class="self-start text-label-small text-n-blue-9 hover:text-n-blue-11 flex items-center gap-1 mt-0.5"
            @click="addPeriod"
          >
            <span class="i-lucide-plus size-3.5" />
            {{ $t('INBOX_MGMT.BUSINESS_HOURS.ADD_PERIOD') }}
          </button>
        </template>
        <span v-else class="text-body-main text-n-slate-11">
          {{ $t('INBOX_MGMT.BUSINESS_HOURS.DAY.UNAVAILABLE') }}
        </span>
      </div>

      <!-- Actions -->
      <div v-if="enabled" class="flex items-center gap-1 flex-shrink-0 pt-0.5 relative">
        <!-- Templates -->
        <div class="relative">
          <button
            type="button"
            class="text-n-slate-10 hover:text-n-slate-12 transition-colors p-1 rounded"
            :title="$t('INBOX_MGMT.BUSINESS_HOURS.TEMPLATES')"
            @click="showTemplates = !showTemplates; showCopy = false"
          >
            <span class="i-lucide-layout-template size-4" />
          </button>
          <div
            v-if="showTemplates"
            class="absolute right-0 top-full mt-1 z-50 bg-n-solid-3 border border-n-weak rounded-xl shadow-lg min-w-52 py-1"
          >
            <button
              type="button"
              v-for="tpl in scheduleTemplates"
              :key="tpl.label"
              class="w-full text-left px-4 py-2 text-body-main text-n-slate-12 hover:bg-n-alpha-black2 transition-colors"
              @click="applyTemplate(tpl)"
            >
              {{ tpl.label }}
            </button>
          </div>
        </div>

        <!-- Copy to -->
        <div class="relative">
          <button
            type="button"
            class="text-n-slate-10 hover:text-n-slate-12 transition-colors p-1 rounded"
            :title="$t('INBOX_MGMT.BUSINESS_HOURS.COPY_TO')"
            @click="showCopy = !showCopy; showTemplates = false"
          >
            <span class="i-lucide-copy size-4" />
          </button>
          <div
            v-if="showCopy"
            class="absolute right-0 top-full mt-1 z-50 bg-n-solid-3 border border-n-weak rounded-xl shadow-lg min-w-44 py-1"
          >
            <p class="px-4 py-1 text-label-small text-n-slate-10 font-medium uppercase">
              {{ $t('INBOX_MGMT.BUSINESS_HOURS.APPLY_TO') }}
            </p>
            <button
              type="button"
              v-for="opt in COPY_OPTIONS"
              :key="opt.value"
              class="w-full text-left px-4 py-2 text-body-main text-n-slate-12 hover:bg-n-alpha-black2 transition-colors"
              @click="applyCopy(opt.value)"
            >
              {{ opt.label }}
            </button>
          </div>
        </div>
      </div>
    </div>

    <!-- Custom day picker -->
    <div v-if="showCustom" class="ml-36 flex flex-wrap gap-2 items-center mt-1">
      <label
        v-for="(label, idx) in DAY_LABELS"
        :key="idx"
        class="flex items-center gap-1 text-body-main text-n-slate-12 cursor-pointer"
      >
        <input
          v-model="customDays"
          type="checkbox"
          :value="idx"
          :disabled="idx === dayIndex"
          class="m-0"
        />
        {{ label }}
      </label>
      <NextButton
        size="sm"
        :label="$t('INBOX_MGMT.BUSINESS_HOURS.APPLY')"
        @click="applyCustomCopy"
      />
      <button type="button" class="text-label-small text-n-slate-10" @click="showCustom = false">
        {{ $t('INBOX_MGMT.BUSINESS_HOURS.CANCEL') }}
      </button>
    </div>
  </div>
</template>
