<script>
import { mapGetters } from 'vuex';
import { useAlert } from 'dashboard/composables';
import inboxMixin from 'shared/mixins/inboxMixin';
import SettingsToggleSection from 'dashboard/components-next/Settings/SettingsToggleSection.vue';
import SettingsFieldSection from 'dashboard/components-next/Settings/SettingsFieldSection.vue';
import DayPeriodsRow from './DayPeriodsRow.vue';
import HolidaysTab from './HolidaysTab.vue';
import ExceptionsTab from './ExceptionsTab.vue';
import AutoMessagesTab from './AutoMessagesTab.vue';
import NextButton from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import {
  periodsFromApi,
  periodsToApi,
  defaultDaySlots,
  timeZoneOptions,
  computeInboxStatus,
} from '../helpers/businessHour';

const DEFAULT_TIMEZONE = {
  label: 'Pacific Time (US & Canada) (GMT-07:00)',
  value: 'America/Los_Angeles',
};

const DAY_NAMES = ['Domingo', 'Segunda-feira', 'Terça-feira', 'Quarta-feira', 'Quinta-feira', 'Sexta-feira', 'Sábado'];

export default {
  components: {
    SettingsToggleSection,
    SettingsFieldSection,
    DayPeriodsRow,
    HolidaysTab,
    ExceptionsTab,
    AutoMessagesTab,
    NextButton,
    ComboBox,
  },
  mixins: [inboxMixin],
  props: {
    inbox: { type: Object, default: () => ({}) },
  },
  data() {
    return {
      activeTab: 'hours',
      isBusinessHoursEnabled: false,
      outOfOfficeMessage: '',
      intervalMessage: '',
      holidayMessage: '',
      timeZone: DEFAULT_TIMEZONE,
      daySlots: defaultDaySlots(),
      holidays: [],
      exceptions: [],
    };
  },
  computed: {
    ...mapGetters({ uiFlags: 'inboxes/getUIFlags' }),
    timeZones() {
      return [...timeZoneOptions()];
    },
    timeZoneValue: {
      get() { return this.timeZone.value; },
      set(value) {
        const match = this.timeZones.find(tz => tz.value === value);
        if (match) this.timeZone = match;
      },
    },
    isRichEditorEnabled() {
      if (this.isATwilioChannel || this.isATwitterInbox || this.isAFacebookInbox) return false;
      return true;
    },
    hasError() {
      if (!this.isBusinessHoursEnabled) return false;
      return this.daySlots.some(slot =>
        slot.enabled && slot.periods.some(p => {
          if (!p.from || !p.to) return true;
          const toMin = s => {
            const d = new Date(`1970-01-01 ${s}`);
            return d.getHours() * 60 + d.getMinutes();
          };
          return toMin(p.to) <= toMin(p.from);
        })
      );
    },
    inboxStatus() {
      if (!this.isBusinessHoursEnabled) return null;
      return computeInboxStatus(
        this.daySlots,
        this.timeZone.value,
        this.holidays,
        this.isBusinessHoursEnabled,
        this.exceptions
      );
    },
    statusLabel() {
      if (!this.inboxStatus) return null;
      const s = this.inboxStatus.status;
      const map = {
        open:     this.$t('INBOX_MGMT.BUSINESS_HOURS.STATUS.OPEN'),
        interval: this.$t('INBOX_MGMT.BUSINESS_HOURS.STATUS.INTERVAL'),
        closed:   this.$t('INBOX_MGMT.BUSINESS_HOURS.STATUS.CLOSED'),
        holiday:  this.$t('INBOX_MGMT.BUSINESS_HOURS.STATUS.HOLIDAY'),
      };
      return map[s] ?? null;
    },
    statusColor() {
      const s = this.inboxStatus?.status;
      if (s === 'open')     return 'text-n-teal-9 bg-n-teal-3';
      if (s === 'interval') return 'text-n-amber-9 bg-n-amber-3';
      return 'text-n-ruby-9 bg-n-ruby-3';
    },
    statusSubtext() {
      const s = this.inboxStatus;
      if (!s) return '';
      if (s.status === 'open' && s.until)
        return this.$t('INBOX_MGMT.BUSINESS_HOURS.STATUS.CLOSES_AT', { time: this.formatTime(s.until) });
      if ((s.status === 'interval' || s.status === 'closed') && s.nextOpen)
        return this.$t('INBOX_MGMT.BUSINESS_HOURS.STATUS.OPENS_AT', { time: this.formatTime(s.nextOpen) });
      return '';
    },
  },
  watch: {
    inbox() { this.setDefaults(); },
  },
  mounted() {
    this.setDefaults();
  },
  methods: {
    setDefaults() {
      const {
        working_hours_enabled: isEnabled = false,
        out_of_office_message: outOfOfficeMessage,
        interval_message: intervalMessage,
        holiday_message: holidayMessage,
        working_periods: workingPeriods = [],
        holidays = [],
        exceptions = [],
        timezone: timeZone,
      } = this.inbox;

      this.isBusinessHoursEnabled = isEnabled;
      this.outOfOfficeMessage  = outOfOfficeMessage || '';
      this.intervalMessage     = intervalMessage    || '';
      this.holidayMessage      = holidayMessage     || '';
      this.holidays            = holidays           || [];
      this.exceptions          = exceptions         || [];
      this.daySlots            = (workingPeriods || []).length ? periodsFromApi(workingPeriods) : defaultDaySlots();
      this.timeZone            = this.timeZones.find(item => timeZone === item.value) || DEFAULT_TIMEZONE;
    },
    onSlotUpdate(day, newSlot) {
      this.daySlots = this.daySlots.map(s => s.day === day ? newSlot : s);
    },
    onCopyTo({ from, to }) {
      const sourceSlot = this.daySlots.find(s => s.day === from);
      if (!sourceSlot) return;
      this.daySlots = this.daySlots.map(s =>
        to.includes(s.day)
          ? { ...s, enabled: sourceSlot.enabled, periods: sourceSlot.periods.map(p => ({ ...p })) }
          : s
      );
    },
    formatTime(date) {
      if (!date) return '';
      return date.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' });
    },
    async updateInbox() {
      try {
        const payload = {
          id: this.inbox.id,
          formData: false,
          working_hours_enabled: this.isBusinessHoursEnabled,
          out_of_office_message: this.outOfOfficeMessage,
          interval_message:      this.intervalMessage,
          holiday_message:       this.holidayMessage,
          working_periods:       periodsToApi(this.daySlots),
          holidays:              this.holidays,
          exceptions:            this.exceptions,
          timezone:              this.timeZone.value,
          channel: {},
        };
        await this.$store.dispatch('inboxes/updateInbox', payload);
        useAlert(this.$t('INBOX_MGMT.EDIT.API.SUCCESS_MESSAGE'));
      } catch (error) {
        useAlert(error.message || this.$t('INBOX_MGMT.EDIT.API.ERROR_MESSAGE'));
      }
    },
  },
};
</script>

<template>
  <div class="mx-6 flex flex-col gap-6">
    <!-- Toggle -->
    <SettingsToggleSection
      v-model="isBusinessHoursEnabled"
      :header="$t('INBOX_MGMT.BUSINESS_HOURS.TOGGLE_AVAILABILITY')"
      :description="$t('INBOX_MGMT.BUSINESS_HOURS.TOGGLE_HELP')"
    />

    <template v-if="isBusinessHoursEnabled">
      <!-- Status badge -->
      <div
        v-if="inboxStatus && inboxStatus.status !== 'disabled'"
        class="flex items-center gap-3 rounded-xl px-4 py-3 outline outline-1 -outline-offset-1 outline-n-weak"
      >
        <span
          class="inline-flex items-center gap-1.5 text-label-small font-medium px-2 py-1 rounded-lg"
          :class="statusColor"
        >
          <span class="size-2 rounded-full bg-current opacity-70" />
          {{ statusLabel }}
        </span>
        <span v-if="statusSubtext" class="text-body-main text-n-slate-11">{{ statusSubtext }}</span>
      </div>

      <!-- Sub-tabs -->
      <div class="flex items-center gap-1 border-b border-n-weak">
        <button
          v-for="tab in ['hours', 'holidays', 'exceptions', 'messages']"
          :key="tab"
          class="px-4 py-2 text-body-main font-medium transition-colors border-b-2 -mb-px"
          :class="activeTab === tab
            ? 'border-n-blue-9 text-n-blue-9'
            : 'border-transparent text-n-slate-10 hover:text-n-slate-12'"
          @click="activeTab = tab"
        >
          {{ $t(`INBOX_MGMT.BUSINESS_HOURS.TABS.${tab.toUpperCase()}`) }}
        </button>
      </div>

      <form class="flex flex-col gap-4" @submit.prevent="updateInbox">
        <!-- Tab: Horário Comercial -->
        <template v-if="activeTab === 'hours'">
          <SettingsFieldSection :label="$t('INBOX_MGMT.BUSINESS_HOURS.TIMEZONE_LABEL')">
            <ComboBox
              v-model="timeZoneValue"
              :options="timeZones"
              :placeholder="$t('INBOX_MGMT.BUSINESS_HOURS.DAY.CHOOSE')"
              class="[&>div>button]:!bg-n-alpha-black2"
            />
          </SettingsFieldSection>

          <div class="flex flex-col rounded-xl outline outline-1 -outline-offset-1 outline-n-weak px-4">
            <DayPeriodsRow
              v-for="slot in daySlots"
              :key="slot.day"
              :day-name="DAY_NAMES[slot.day]"
              :day-index="slot.day"
              :slot="slot"
              @update="newSlot => onSlotUpdate(slot.day, newSlot)"
              @copy-to="onCopyTo"
            />
          </div>
        </template>

        <!-- Tab: Feriados -->
        <template v-else-if="activeTab === 'holidays'">
          <HolidaysTab :holidays="holidays" @update="h => (holidays = h)" />
        </template>

        <!-- Tab: Exceções -->
        <template v-else-if="activeTab === 'exceptions'">
          <ExceptionsTab :exceptions="exceptions" @update="e => (exceptions = e)" />
        </template>

        <!-- Tab: Mensagens Automáticas -->
        <template v-else>
          <AutoMessagesTab
            v-model:out-of-office-message="outOfOfficeMessage"
            v-model:interval-message="intervalMessage"
            v-model:holiday-message="holidayMessage"
            :is-rich-editor-enabled="isRichEditorEnabled"
          />
        </template>

        <div class="flex justify-end py-2">
          <NextButton
            type="submit"
            :label="$t('INBOX_MGMT.BUSINESS_HOURS.UPDATE')"
            :is-loading="uiFlags.isUpdating"
            :disabled="hasError"
          />
        </div>
      </form>
    </template>
  </div>
</template>
