<script setup>
import { ref } from 'vue';
import NextButton from 'dashboard/components-next/button/Button.vue';

const props = defineProps({
  exceptions: { type: Array, default: () => [] },
});
const emit = defineEmits(['update']);

const showForm = ref(false);
const editIdx = ref(null);

const blankForm = () => ({
  name: '',
  exception_date: '',
  closed: false,
  periods: [{ from: '08:00', to: '12:00' }],
});

const form = ref(blankForm());

const pad = n => String(n).padStart(2, '0');

// API shape -> UI time strings
const toUiPeriods = apiPeriods =>
  (apiPeriods || []).map(p => ({
    from: `${pad(p.start_hour)}:${pad(p.start_minutes)}`,
    to: `${pad(p.end_hour)}:${pad(p.end_minutes)}`,
  }));

// UI time strings -> API shape
const toApiPeriods = uiPeriods =>
  (uiPeriods || [])
    .filter(p => p.from && p.to)
    .map(p => {
      const [sh, sm] = p.from.split(':');
      const [eh, em] = p.to.split(':');
      return {
        start_hour: Number(sh),
        start_minutes: Number(sm),
        end_hour: Number(eh),
        end_minutes: Number(em),
      };
    });

function openAdd() {
  editIdx.value = null;
  form.value = blankForm();
  showForm.value = true;
}

function openEdit(idx) {
  const ex = props.exceptions[idx];
  editIdx.value = idx;
  form.value = {
    name: ex.name || '',
    exception_date: String(ex.exception_date || '').slice(0, 10),
    closed: !!ex.closed,
    periods: ex.closed || !ex.periods?.length ? blankForm().periods : toUiPeriods(ex.periods),
  };
  showForm.value = true;
}

function addPeriod() {
  form.value.periods.push({ from: '13:30', to: '18:00' });
}

function removePeriod(idx) {
  form.value.periods = form.value.periods.filter((_, i) => i !== idx);
}

function save() {
  const entry = {
    name: form.value.name,
    exception_date: form.value.exception_date,
    closed: form.value.closed,
    periods: form.value.closed ? [] : toApiPeriods(form.value.periods),
  };
  const list = [...props.exceptions];
  if (editIdx.value !== null) list[editIdx.value] = entry;
  else list.push(entry);
  emit('update', list);
  showForm.value = false;
}

function remove(idx) {
  emit(
    'update',
    props.exceptions.filter((_, i) => i !== idx)
  );
}

function formatDate(dateStr) {
  const [y, m, d] = String(dateStr || '').slice(0, 10).split('-');
  return d && m && y ? `${d}/${m}/${y}` : dateStr;
}

function summary(ex) {
  if (ex.closed) return null;
  return (ex.periods || [])
    .map(p => `${pad(p.start_hour)}:${pad(p.start_minutes)} → ${pad(p.end_hour)}:${pad(p.end_minutes)}`)
    .join(' · ');
}
</script>

<template>
  <div class="flex flex-col gap-6">
    <p class="text-label-small text-n-slate-10">
      {{ $t('INBOX_MGMT.BUSINESS_HOURS.EXCEPTIONS.HINT') }}
    </p>

    <!-- Exception list -->
    <div
      v-if="exceptions.length"
      class="outline outline-1 -outline-offset-1 outline-n-weak rounded-xl divide-y divide-n-weak"
    >
      <div
        v-for="(ex, idx) in exceptions"
        :key="idx"
        class="flex items-center justify-between px-4 py-3"
      >
        <div class="flex flex-col">
          <span class="text-body-main text-n-slate-12 font-medium">
            {{ formatDate(ex.exception_date) }}
            <span v-if="ex.name" class="text-n-slate-10 font-normal">· {{ ex.name }}</span>
          </span>
          <span class="text-label-small text-n-slate-10">
            <span v-if="ex.closed" class="text-n-ruby-9">
              {{ $t('INBOX_MGMT.BUSINESS_HOURS.EXCEPTIONS.CLOSED') }}
            </span>
            <span v-else>{{ summary(ex) }}</span>
          </span>
        </div>
        <div class="flex items-center gap-2">
          <button type="button" class="text-n-slate-9 hover:text-n-slate-12 transition-colors" @click="openEdit(idx)">
            <span class="i-lucide-pencil size-4" />
          </button>
          <button type="button" class="text-n-slate-9 hover:text-n-ruby-9 transition-colors" @click="remove(idx)">
            <span class="i-lucide-trash-2 size-4" />
          </button>
        </div>
      </div>
    </div>

    <div v-else class="text-body-main text-n-slate-10 text-center py-8">
      {{ $t('INBOX_MGMT.BUSINESS_HOURS.EXCEPTIONS.EMPTY') }}
    </div>

    <!-- Add button -->
    <div>
      <NextButton
        variant="ghost"
        :label="$t('INBOX_MGMT.BUSINESS_HOURS.EXCEPTIONS.ADD')"
        icon="i-lucide-plus"
        @click="openAdd"
      />
    </div>

    <!-- Form -->
    <div v-if="showForm" class="outline outline-1 -outline-offset-1 outline-n-weak rounded-xl p-4 flex flex-col gap-4">
      <p class="text-heading-3 text-n-slate-12 font-medium">
        {{ editIdx !== null
          ? $t('INBOX_MGMT.BUSINESS_HOURS.EXCEPTIONS.EDIT')
          : $t('INBOX_MGMT.BUSINESS_HOURS.EXCEPTIONS.ADD') }}
      </p>

      <div class="flex gap-3">
        <div class="flex flex-col gap-1 flex-1">
          <label class="text-label-small text-n-slate-11">{{ $t('INBOX_MGMT.BUSINESS_HOURS.EXCEPTIONS.DATE') }}</label>
          <input
            v-model="form.exception_date"
            type="date"
            class="border border-n-weak rounded-lg px-3 py-2 text-body-main bg-n-solid-2 text-n-slate-12 focus:outline-none focus:ring-1 focus:ring-n-blue-8"
          />
        </div>
        <div class="flex flex-col gap-1 flex-1">
          <label class="text-label-small text-n-slate-11">{{ $t('INBOX_MGMT.BUSINESS_HOURS.EXCEPTIONS.NAME') }}</label>
          <input
            v-model="form.name"
            type="text"
            class="border border-n-weak rounded-lg px-3 py-2 text-body-main bg-n-solid-2 text-n-slate-12 focus:outline-none focus:ring-1 focus:ring-n-blue-8"
            :placeholder="$t('INBOX_MGMT.BUSINESS_HOURS.EXCEPTIONS.NAME_PLACEHOLDER')"
          />
        </div>
      </div>

      <label class="flex items-center gap-2 cursor-pointer">
        <input v-model="form.closed" type="checkbox" class="m-0" />
        <span class="text-body-main text-n-slate-12">{{ $t('INBOX_MGMT.BUSINESS_HOURS.EXCEPTIONS.CLOSED_ALL_DAY') }}</span>
      </label>

      <div v-if="!form.closed" class="flex flex-col gap-2">
        <label class="text-label-small text-n-slate-11">{{ $t('INBOX_MGMT.BUSINESS_HOURS.EXCEPTIONS.PERIODS') }}</label>
        <div v-for="(period, idx) in form.periods" :key="idx" class="flex items-center gap-2">
          <input
            v-model="period.from"
            type="time"
            class="border border-n-weak rounded-lg px-3 py-2 text-body-main bg-n-solid-2 text-n-slate-12 focus:outline-none focus:ring-1 focus:ring-n-blue-8"
          />
          <span class="text-n-slate-11 text-sm">→</span>
          <input
            v-model="period.to"
            type="time"
            class="border border-n-weak rounded-lg px-3 py-2 text-body-main bg-n-solid-2 text-n-slate-12 focus:outline-none focus:ring-1 focus:ring-n-blue-8"
          />
          <button
            type="button"
            v-if="form.periods.length > 1"
            class="text-n-slate-10 hover:text-n-ruby-9 transition-colors"
            @click="removePeriod(idx)"
          >
            <span class="i-lucide-x size-4" />
          </button>
        </div>
        <button
          type="button"
          class="self-start text-label-small text-n-blue-9 hover:text-n-blue-11 flex items-center gap-1"
          @click="addPeriod"
        >
          <span class="i-lucide-plus size-3.5" />
          {{ $t('INBOX_MGMT.BUSINESS_HOURS.EXCEPTIONS.ADD_PERIOD') }}
        </button>
      </div>

      <div class="flex items-center gap-2 justify-end">
        <button type="button" class="text-body-main text-n-slate-10 hover:text-n-slate-12" @click="showForm = false">
          {{ $t('INBOX_MGMT.BUSINESS_HOURS.CANCEL') }}
        </button>
        <NextButton
          :label="$t('INBOX_MGMT.BUSINESS_HOURS.SAVE')"
          :disabled="!form.exception_date"
          @click="save"
        />
      </div>
    </div>
  </div>
</template>
