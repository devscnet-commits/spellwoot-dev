<script setup>
import { ref, computed } from 'vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

const MONTH_NAMES = ['Jan','Fev','Mar','Abr','Mai','Jun','Jul','Ago','Set','Out','Nov','Dez'];

const props = defineProps({
  holidays: { type: Array, default: () => [] },
});
const emit = defineEmits(['update']);

const showForm = ref(false);
const editIdx  = ref(null);

const form = ref({
  name: '',
  holiday_month: 1,
  holiday_day: 1,
  holiday_year: null,
  recurring: true,
});

function openAdd() {
  editIdx.value = null;
  form.value = { name: '', holiday_month: 1, holiday_day: 1, holiday_year: null, recurring: true };
  showForm.value = true;
}

function openEdit(idx) {
  editIdx.value = idx;
  form.value = { ...props.holidays[idx] };
  showForm.value = true;
}

function save() {
  const list = [...props.holidays];
  if (editIdx.value !== null) {
    list[editIdx.value] = { ...form.value };
  } else {
    list.push({ ...form.value });
  }
  emit('update', list);
  showForm.value = false;
}

function remove(idx) {
  emit('update', props.holidays.filter((_, i) => i !== idx));
}

function formatDate(h) {
  const year = !h.recurring && h.holiday_year ? `/${h.holiday_year}` : '';
  return `${String(h.holiday_day).padStart(2,'0')}/${String(h.holiday_month).padStart(2,'0')}${year}`;
}

const yearOptions = computed(() => {
  const current = new Date().getFullYear();
  return [null, current, current + 1, current + 2];
});
</script>

<template>
  <div class="flex flex-col gap-6">
    <!-- Holiday list -->
    <div
      v-if="holidays.length"
      class="outline outline-1 -outline-offset-1 outline-n-weak rounded-xl divide-y divide-n-weak"
    >
      <div
        v-for="(h, idx) in holidays"
        :key="idx"
        class="flex items-center justify-between px-4 py-3"
      >
        <div class="flex flex-col">
          <span class="text-body-main text-n-slate-12 font-medium">{{ h.name }}</span>
          <span class="text-label-small text-n-slate-10">
            {{ formatDate(h) }}
            <span v-if="h.recurring" class="ml-1">· {{ $t('INBOX_MGMT.BUSINESS_HOURS.HOLIDAYS.RECURRING') }}</span>
            <span v-else class="ml-1">· {{ $t('INBOX_MGMT.BUSINESS_HOURS.HOLIDAYS.ONE_TIME') }}</span>
          </span>
        </div>
        <div class="flex items-center gap-2">
          <button class="text-n-slate-9 hover:text-n-slate-12 transition-colors" @click="openEdit(idx)">
            <span class="i-lucide-pencil size-4" />
          </button>
          <button class="text-n-slate-9 hover:text-n-ruby-9 transition-colors" @click="remove(idx)">
            <span class="i-lucide-trash-2 size-4" />
          </button>
        </div>
      </div>
    </div>

    <div v-else class="text-body-main text-n-slate-10 text-center py-8">
      {{ $t('INBOX_MGMT.BUSINESS_HOURS.HOLIDAYS.EMPTY') }}
    </div>

    <!-- Add button -->
    <div>
      <NextButton
        variant="ghost"
        :label="$t('INBOX_MGMT.BUSINESS_HOURS.HOLIDAYS.ADD')"
        icon="i-lucide-plus"
        @click="openAdd"
      />
    </div>

    <!-- Form -->
    <div v-if="showForm" class="outline outline-1 -outline-offset-1 outline-n-weak rounded-xl p-4 flex flex-col gap-4">
      <p class="text-heading-3 text-n-slate-12 font-medium">
        {{ editIdx !== null ? $t('INBOX_MGMT.BUSINESS_HOURS.HOLIDAYS.EDIT') : $t('INBOX_MGMT.BUSINESS_HOURS.HOLIDAYS.ADD') }}
      </p>

      <div class="flex flex-col gap-1">
        <label class="text-label-small text-n-slate-11">{{ $t('INBOX_MGMT.BUSINESS_HOURS.HOLIDAYS.NAME') }}</label>
        <input
          v-model="form.name"
          type="text"
          class="border border-n-weak rounded-lg px-3 py-2 text-body-main bg-n-solid-2 text-n-slate-12 focus:outline-none focus:ring-1 focus:ring-n-blue-8"
          :placeholder="$t('INBOX_MGMT.BUSINESS_HOURS.HOLIDAYS.NAME_PLACEHOLDER')"
        />
      </div>

      <div class="flex gap-3">
        <div class="flex flex-col gap-1 flex-1">
          <label class="text-label-small text-n-slate-11">{{ $t('INBOX_MGMT.BUSINESS_HOURS.HOLIDAYS.DAY') }}</label>
          <input
            v-model.number="form.holiday_day"
            type="number"
            min="1"
            max="31"
            class="border border-n-weak rounded-lg px-3 py-2 text-body-main bg-n-solid-2 text-n-slate-12 focus:outline-none focus:ring-1 focus:ring-n-blue-8"
          />
        </div>
        <div class="flex flex-col gap-1 flex-1">
          <label class="text-label-small text-n-slate-11">{{ $t('INBOX_MGMT.BUSINESS_HOURS.HOLIDAYS.MONTH') }}</label>
          <select
            v-model.number="form.holiday_month"
            class="border border-n-weak rounded-lg px-3 py-2 text-body-main bg-n-solid-2 text-n-slate-12 focus:outline-none focus:ring-1 focus:ring-n-blue-8"
          >
            <option v-for="(m, i) in MONTH_NAMES" :key="i" :value="i + 1">{{ m }}</option>
          </select>
        </div>
      </div>

      <div class="flex flex-col gap-2">
        <label class="text-label-small text-n-slate-11">{{ $t('INBOX_MGMT.BUSINESS_HOURS.HOLIDAYS.TYPE') }}</label>
        <div class="flex gap-4">
          <label class="flex items-center gap-2 cursor-pointer">
            <input v-model="form.recurring" type="radio" :value="true" class="m-0" />
            <span class="text-body-main text-n-slate-12">{{ $t('INBOX_MGMT.BUSINESS_HOURS.HOLIDAYS.RECURRING') }}</span>
          </label>
          <label class="flex items-center gap-2 cursor-pointer">
            <input v-model="form.recurring" type="radio" :value="false" class="m-0" />
            <span class="text-body-main text-n-slate-12">{{ $t('INBOX_MGMT.BUSINESS_HOURS.HOLIDAYS.ONE_TIME') }}</span>
          </label>
        </div>
        <div v-if="!form.recurring" class="flex flex-col gap-1 mt-1">
          <label class="text-label-small text-n-slate-11">{{ $t('INBOX_MGMT.BUSINESS_HOURS.HOLIDAYS.YEAR') }}</label>
          <select
            v-model.number="form.holiday_year"
            class="border border-n-weak rounded-lg px-3 py-2 text-body-main bg-n-solid-2 text-n-slate-12 focus:outline-none focus:ring-1 focus:ring-n-blue-8"
          >
            <option v-for="y in yearOptions" :key="y" :value="y">
              {{ y ?? $t('INBOX_MGMT.BUSINESS_HOURS.HOLIDAYS.ANY_YEAR') }}
            </option>
          </select>
        </div>
      </div>

      <div class="flex items-center gap-2 justify-end">
        <button class="text-body-main text-n-slate-10 hover:text-n-slate-12" @click="showForm = false">
          {{ $t('INBOX_MGMT.BUSINESS_HOURS.CANCEL') }}
        </button>
        <NextButton :label="$t('INBOX_MGMT.BUSINESS_HOURS.SAVE')" :disabled="!form.name" @click="save" />
      </div>
    </div>
  </div>
</template>
