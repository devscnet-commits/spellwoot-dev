import parse from 'date-fns/parse';
import getHours from 'date-fns/getHours';
import getMinutes from 'date-fns/getMinutes';
import { utcToZonedTime } from 'date-fns-tz';
import timeZoneData from './timezones.json';

// ── Time slot generation ──────────────────────────────────────────────────────

export const generateTimeSlots = (step = 15) => {
  const date = new Date(1970, 1, 1);
  const slots = [];
  while (date.getDate() === 1) {
    slots.push(
      date.toLocaleTimeString('en-US', {
        hour: '2-digit',
        minute: '2-digit',
        hour12: true,
      })
    );
    date.setMinutes(date.getMinutes() + step);
  }
  const lastSlot = '11:59 PM';
  if (!slots.includes(lastSlot)) slots.push(lastSlot);
  return slots;
};

export const getTime = (hour, minute) => {
  const meridian = hour > 11 ? 'PM' : 'AM';
  const modHour = hour > 12 ? hour % 12 : hour || 12;
  const parsedHour = modHour < 10 ? `0${modHour}` : modHour;
  const parsedMinute = minute < 10 ? `0${minute}` : minute;
  return `${parsedHour}:${parsedMinute} ${meridian}`;
};

// ── Multi-period schedule ─────────────────────────────────────────────────────

// Default: Mon–Fri 09:00–18:00, weekend closed
const emptyDay = day => ({ day, enabled: false, periods: [] });

export const defaultDaySlots = () =>
  [0, 1, 2, 3, 4, 5, 6].map(d => {
    if (d === 0 || d === 6) return emptyDay(d);
    return { day: d, enabled: true, periods: [{ from: '09:00 AM', to: '06:00 PM' }] };
  });

// Parse API working_periods array into day-indexed slots
export const periodsFromApi = (apiPeriods = []) => {
  const map = {};
  apiPeriods.forEach(p => {
    const day = p.day_of_week;
    if (!map[day]) map[day] = { day, enabled: true, periods: [] };
    map[day].periods.push({
      from: getTime(p.start_hour, p.start_minutes),
      to: getTime(p.end_hour, p.end_minutes),
    });
  });
  return [0, 1, 2, 3, 4, 5, 6].map(d => map[d] || emptyDay(d));
};

// Transform day slots back to API format
export const periodsToApi = (daySlots = []) => {
  const out = [];
  daySlots.forEach(slot => {
    if (!slot.enabled || !slot.periods.length) return;
    slot.periods.forEach((p, idx) => {
      if (!p.from || !p.to) return;
      const fromDate = parse(p.from, 'hh:mm a', new Date());
      const toDate = parse(p.to, 'hh:mm a', new Date());
      out.push({
        day_of_week: slot.day,
        start_hour: getHours(fromDate),
        start_minutes: getMinutes(fromDate),
        end_hour: getHours(toDate),
        end_minutes: getMinutes(toDate),
        position: idx,
      });
    });
  });
  return out;
};

// ── Schedule templates ────────────────────────────────────────────────────────

export const scheduleTemplates = [
  {
    label: '08:00 → 18:00',
    periods: [{ from: '08:00 AM', to: '06:00 PM' }],
  },
  {
    label: '08:00 → 12:00 / 13:00 → 18:00',
    periods: [
      { from: '08:00 AM', to: '12:00 PM' },
      { from: '01:00 PM', to: '06:00 PM' },
    ],
  },
  {
    label: '07:30 → 12:00 / 13:30 → 18:00',
    periods: [
      { from: '07:30 AM', to: '12:00 PM' },
      { from: '01:30 PM', to: '06:00 PM' },
    ],
  },
  {
    label: '24 horas',
    periods: [{ from: '12:00 AM', to: '11:59 PM' }],
  },
];

// ── Status computation ────────────────────────────────────────────────────────

const parseTimeInZone = (timeStr, refDate) =>
  parse(timeStr, 'hh:mm a', refDate);

export const computeInboxStatus = (daySlots, timezone, holidays = [], workingHoursEnabled) => {
  if (!workingHoursEnabled) return null;

  const now = utcToZonedTime(new Date(), timezone);

  // Check holiday
  const todayMonth = now.getMonth() + 1;
  const todayDay = now.getDate();
  const todayYear = now.getFullYear();
  const isHoliday = holidays.some(h => {
    if (!h.recurring && h.holiday_year && h.holiday_year !== todayYear) return false;
    return h.holiday_month === todayMonth && h.holiday_day === todayDay;
  });
  if (isHoliday) return { status: 'holiday' };

  const todaySlot = daySlots.find(s => s.day === now.getDay());
  if (!todaySlot || !todaySlot.enabled || !todaySlot.periods.length) {
    return { status: 'closed', nextOpen: null };
  }

  const refDate = new Date(now.getFullYear(), now.getMonth(), now.getDate());

  const todayPeriods = todaySlot.periods
    .filter(p => p.from && p.to)
    .map(p => ({
      start: parseTimeInZone(p.from, refDate),
      end: parseTimeInZone(p.to, refDate),
    }));

  // Inside an open period?
  for (const p of todayPeriods) {
    if (now >= p.start && now <= p.end) {
      return { status: 'open', until: p.end };
    }
  }

  // Between periods (interval)?
  const nextPeriod = todayPeriods.find(p => p.start > now);
  if (nextPeriod) {
    return { status: 'interval', nextOpen: nextPeriod.start };
  }

  return { status: 'closed', nextOpen: null };
};

// ── Timezone helpers ──────────────────────────────────────────────────────────

export const timeZoneOptions = () =>
  Object.keys(timeZoneData).map(key => ({ label: key, value: timeZoneData[key] }));

// ── Legacy single-period helpers (kept for backward compat) ──────────────────

const emptySlotLegacy = day => ({ day, from: '', to: '', valid: false, openAllDay: false, hasLunchBreak: false, lunchFrom: '', lunchTo: '' });
export const defaultTimeSlot = [0, 1, 2, 3, 4, 5, 6].map(emptySlotLegacy);

export const timeSlotParse = timeSlots =>
  timeSlots.map(slot => {
    const {
      day_of_week: day, open_hour: openHour, open_minutes: openMinutes,
      close_hour: closeHour, close_minutes: closeMinutes,
      closed_all_day: closedAllDay, open_all_day: openAllDay,
      has_lunch_break: hasLunchBreak, lunch_start_hour: lunchStartHour,
      lunch_start_minutes: lunchStartMinutes, lunch_end_hour: lunchEndHour,
      lunch_end_minutes: lunchEndMinutes,
    } = slot;
    return {
      day,
      from: closedAllDay ? '' : getTime(openHour, openMinutes),
      to: closedAllDay ? '' : getTime(closeHour, closeMinutes),
      valid: !closedAllDay,
      openAllDay: Boolean(openAllDay),
      hasLunchBreak: Boolean(hasLunchBreak),
      lunchFrom: hasLunchBreak && lunchStartHour != null ? getTime(lunchStartHour, lunchStartMinutes ?? 0) : '',
      lunchTo: hasLunchBreak && lunchEndHour != null ? getTime(lunchEndHour, lunchEndMinutes ?? 0) : '',
    };
  });

export const timeSlotTransform = timeSlots =>
  timeSlots.map(slot => {
    const closed = slot.openAllDay ? false : !(slot.to && slot.from);
    let openHour = '', openMinutes = '', closeHour = '', closeMinutes = '';
    if (!closed) {
      const fromDate = parse(slot.from, 'hh:mm a', new Date());
      const toDate = parse(slot.to, 'hh:mm a', new Date());
      openHour = getHours(fromDate); openMinutes = getMinutes(fromDate);
      closeHour = getHours(toDate); closeMinutes = getMinutes(toDate);
    }
    const hasLunchBreak = Boolean(slot.hasLunchBreak && slot.lunchFrom && slot.lunchTo);
    let lunchStartHour = null, lunchStartMinutes = null, lunchEndHour = null, lunchEndMinutes = null;
    if (hasLunchBreak) {
      const lf = parse(slot.lunchFrom, 'hh:mm a', new Date());
      const lt = parse(slot.lunchTo, 'hh:mm a', new Date());
      lunchStartHour = getHours(lf); lunchStartMinutes = getMinutes(lf);
      lunchEndHour = getHours(lt); lunchEndMinutes = getMinutes(lt);
    }
    return {
      day_of_week: slot.day, closed_all_day: closed,
      open_hour: openHour, open_minutes: openMinutes, close_hour: closeHour, close_minutes: closeMinutes,
      open_all_day: slot.openAllDay, has_lunch_break: hasLunchBreak,
      lunch_start_hour: lunchStartHour, lunch_start_minutes: lunchStartMinutes,
      lunch_end_hour: lunchEndHour, lunch_end_minutes: lunchEndMinutes,
    };
  });
