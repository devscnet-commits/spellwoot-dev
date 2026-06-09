<script setup>
import { ref, computed, onMounted } from 'vue';
import { useAccount } from 'dashboard/composables/useAccount';
import { useMapGetter } from 'dashboard/composables/store';
import subDays from 'date-fns/subDays';
import format from 'date-fns/format';
import { getUnixStartOfDay, getUnixEndOfDay } from 'helpers/DateHelper';
import axios from 'axios';

const { accountId } = useAccount();
const agents  = useMapGetter('agents/getAgents');
const inboxes = useMapGetter('inboxes/getInboxes');
const teams   = useMapGetter('teams/getTeams');

const today = new Date();
const since           = ref(getUnixStartOfDay(subDays(today, 29)));
const until           = ref(getUnixEndOfDay(today));
const customSince     = ref(format(subDays(today, 29), 'yyyy-MM-dd'));
const customUntil     = ref(format(today, 'yyyy-MM-dd'));
const selectedPreset  = ref(30);
const filterInboxId   = ref('');
const filterTeamId    = ref('');
const filterAgentId   = ref('');

const isLoading   = ref(false);
const byHour      = ref([]);
const responseByHour = ref([]);
const agentByHour = ref([]);
const activeTab   = ref('volume');
const sortKey     = ref('hour');
const sortDir     = ref(1);

const PRESETS = [
  { id: 'today',     label: 'Hoje' },
  { id: 'yesterday', label: 'Ontem' },
  { id: 7,           label: '7d' },
  { id: 30,          label: '30d' },
  { id: 90,          label: '90d' },
  { id: 'custom',    label: 'Personalizado' },
];

const TABS = [
  { id: 'volume',   label: 'Volume por Hora',     icon: 'i-lucide-bar-chart-2' },
  { id: 'response', label: 'Tempo de Resposta',   icon: 'i-lucide-timer' },
  { id: 'agent',    label: 'Agente × Hora',       icon: 'i-lucide-user' },
];

const applyPreset = id => {
  selectedPreset.value = id;
  const now = new Date();
  if (id === 'today') {
    since.value = getUnixStartOfDay(now);
    until.value = getUnixEndOfDay(now);
  } else if (id === 'yesterday') {
    const y = subDays(now, 1);
    since.value = getUnixStartOfDay(y);
    until.value = getUnixEndOfDay(y);
  } else if (typeof id === 'number') {
    since.value = getUnixStartOfDay(subDays(now, id - 1));
    until.value = getUnixEndOfDay(now);
  }
  if (id !== 'custom') fetchData();
};

const applyCustom = () => {
  since.value = getUnixStartOfDay(new Date(customSince.value));
  until.value = getUnixEndOfDay(new Date(customUntil.value));
  fetchData();
};

const buildParams = () => {
  const p = { since: since.value, until: until.value };
  if (filterInboxId.value)  p.inbox_id   = filterInboxId.value;
  if (filterTeamId.value)   p.team_id    = filterTeamId.value;
  if (filterAgentId.value)  p.assignee_id = filterAgentId.value;
  return p;
};

const fetchData = async () => {
  isLoading.value = true;
  try {
    const res = await axios.get(
      `/api/v2/accounts/${accountId.value}/reports/schedule_report`,
      { params: buildParams() }
    );
    byHour.value         = res.data.by_hour          || [];
    responseByHour.value = res.data.response_by_hour || [];
    agentByHour.value    = res.data.agent_by_hour    || [];
  } catch (e) {
    // keep stale data on error
  } finally {
    isLoading.value = false;
  }
};

// Pre-fill all 24 hours so bars always render
const volumeRows = computed(() => {
  const map = Object.fromEntries(byHour.value.map(r => [r.hour, r.total]));
  return Array.from({ length: 24 }, (_, h) => ({ hour: h, total: map[h] || 0 }));
});

const maxVolume = computed(() => Math.max(1, ...volumeRows.value.map(r => r.total)));

const responseRows = computed(() => {
  const map = Object.fromEntries(responseByHour.value.map(r => [r.hour, r.avg_seconds]));
  return Array.from({ length: 24 }, (_, h) => ({ hour: h, avg_seconds: map[h] || 0 }));
});

const maxResponse = computed(() => Math.max(1, ...responseRows.value.map(r => r.avg_seconds)));

// Agent × Hour — pivot: rows = agents, columns = hours
const agentNames = computed(() => [...new Set(agentByHour.value.map(r => r.agent))].sort());

const agentHourMatrix = computed(() => {
  return agentNames.value.map(name => {
    const row = { agent: name };
    for (let h = 0; h < 24; h++) {
      const found = agentByHour.value.find(r => r.agent === name && r.hour === h);
      row[h] = found?.total || 0;
    }
    row.total = agentByHour.value.filter(r => r.agent === name).reduce((s, r) => s + r.total, 0);
    return row;
  });
});

const sortedAgentMatrix = computed(() => {
  const dir = sortDir.value;
  return [...agentHourMatrix.value].sort((a, b) =>
    dir * (a[sortKey.value] > b[sortKey.value] ? 1 : -1)
  );
});

const setSort = key => {
  if (sortKey.value === key) { sortDir.value = -sortDir.value; } else { sortKey.value = key; sortDir.value = -1; }
};

const fmtHour = h => {
  const suffix = h < 12 ? 'AM' : 'PM';
  const display = h === 0 ? 12 : h > 12 ? h - 12 : h;
  return `${display}${suffix}`;
};

const fmtDuration = secs => {
  if (!secs) return '—';
  if (secs < 60) return `${secs}s`;
  if (secs < 3600) return `${Math.round(secs / 60)}min`;
  return `${(secs / 3600).toFixed(1)}h`;
};

const heatColor = (val, max) => {
  const pct = max > 0 ? val / max : 0;
  if (pct === 0)    return 'bg-n-slate-2';
  if (pct < 0.25)   return 'bg-n-brand-3';
  if (pct < 0.5)    return 'bg-n-brand-5';
  if (pct < 0.75)   return 'bg-n-brand-7';
  return 'bg-n-brand-9';
};

onMounted(() => fetchData());
</script>

<template>
  <div class="flex flex-col gap-6 p-6">
    <!-- Header -->
    <div class="flex flex-col gap-1">
      <h1 class="text-xl font-semibold text-n-slate-12">Relatório de Horários</h1>
      <p class="text-sm text-n-slate-10">Distribuição de conversas, tempos de resposta e atividade por hora do dia</p>
    </div>

    <!-- Filters -->
    <div class="flex flex-wrap items-end gap-3">
      <!-- Presets -->
      <div class="flex gap-1.5 flex-wrap">
        <button
          v-for="p in PRESETS"
          :key="p.id"
          class="px-3 py-1.5 rounded-lg text-sm font-medium border transition-colors"
          :class="selectedPreset === p.id
            ? 'bg-n-brand-9 text-white border-n-brand-9'
            : 'border-n-weak text-n-slate-11 hover:border-n-brand-8 hover:text-n-brand-9'"
          @click="applyPreset(p.id)"
        >{{ p.label }}</button>
      </div>

      <!-- Custom range -->
      <div v-if="selectedPreset === 'custom'" class="flex items-center gap-2">
        <input v-model="customSince" type="date"
          class="text-sm border border-n-weak rounded-lg px-2 py-1.5 bg-n-solid-2 text-n-slate-12" />
        <span class="text-n-slate-10">–</span>
        <input v-model="customUntil" type="date"
          class="text-sm border border-n-weak rounded-lg px-2 py-1.5 bg-n-solid-2 text-n-slate-12" />
        <button
          class="px-3 py-1.5 rounded-lg text-sm font-medium bg-n-brand-9 text-white"
          @click="applyCustom"
        >Aplicar</button>
      </div>

      <div class="flex gap-2 flex-wrap ml-auto">
        <select v-model="filterInboxId" class="text-sm border border-n-weak rounded-lg px-2 py-1.5 bg-n-solid-2 text-n-slate-12" @change="fetchData">
          <option value="">Todas as caixas</option>
          <option v-for="i in inboxes" :key="i.id" :value="i.id">{{ i.name }}</option>
        </select>
        <select v-model="filterTeamId" class="text-sm border border-n-weak rounded-lg px-2 py-1.5 bg-n-solid-2 text-n-slate-12" @change="fetchData">
          <option value="">Todos os times</option>
          <option v-for="t in teams" :key="t.id" :value="t.id">{{ t.name }}</option>
        </select>
        <select v-model="filterAgentId" class="text-sm border border-n-weak rounded-lg px-2 py-1.5 bg-n-solid-2 text-n-slate-12" @change="fetchData">
          <option value="">Todos os agentes</option>
          <option v-for="a in agents" :key="a.id" :value="a.id">{{ a.name }}</option>
        </select>
      </div>
    </div>

    <!-- Tabs -->
    <div class="flex gap-1 border-b border-n-weak">
      <button
        v-for="tab in TABS"
        :key="tab.id"
        class="flex items-center gap-1.5 px-4 py-2.5 text-sm font-medium border-b-2 -mb-px transition-colors"
        :class="activeTab === tab.id
          ? 'border-n-brand-9 text-n-brand-9'
          : 'border-transparent text-n-slate-10 hover:text-n-slate-12'"
        @click="activeTab = tab.id"
      >
        <span :class="tab.icon" class="text-base" />
        {{ tab.label }}
      </button>
    </div>

    <!-- Loading -->
    <div v-if="isLoading" class="flex items-center justify-center py-16 text-n-slate-10">
      <span class="i-lucide-loader-2 animate-spin text-2xl mr-2" />
      Carregando...
    </div>

    <!-- Volume por hora -->
    <div v-else-if="activeTab === 'volume'" class="flex flex-col gap-4">
      <p class="text-sm text-n-slate-10">Quantidade de conversas iniciadas por hora do dia</p>
      <div class="flex items-end gap-1 h-48 px-1">
        <div
          v-for="row in volumeRows"
          :key="row.hour"
          class="flex flex-col items-center gap-1 flex-1"
        >
          <span v-if="row.total > 0" class="text-xs text-n-slate-10 leading-none">{{ row.total }}</span>
          <div
            class="w-full rounded-t transition-all duration-300"
            :class="heatColor(row.total, maxVolume)"
            :style="{ height: maxVolume > 0 ? `${Math.max(2, (row.total / maxVolume) * 100)}%` : '2px' }"
          />
          <span class="text-xs text-n-slate-9 leading-none whitespace-nowrap">{{ fmtHour(row.hour) }}</span>
        </div>
      </div>

      <!-- Table -->
      <div class="rounded-xl border border-n-weak overflow-hidden mt-2">
        <div class="grid grid-cols-3 px-4 py-2 bg-n-slate-2 border-b border-n-weak text-xs font-medium text-n-slate-11">
          <span>Horário</span>
          <span class="text-right">Conversas</span>
          <span class="text-right">% do total</span>
        </div>
        <div class="max-h-72 overflow-y-auto divide-y divide-n-weak/40">
          <div v-for="row in volumeRows.filter(r => r.total > 0)" :key="row.hour"
            class="grid grid-cols-3 px-4 py-2.5 hover:bg-n-slate-1 text-sm">
            <span class="text-n-slate-12 font-medium">{{ fmtHour(row.hour) }}</span>
            <span class="text-right text-n-slate-11">{{ row.total }}</span>
            <span class="text-right text-n-slate-10">
              {{ byHour.reduce((s, r) => s + r.total, 0) > 0
                ? ((row.total / byHour.reduce((s, r) => s + r.total, 0)) * 100).toFixed(1) + '%'
                : '—' }}
            </span>
          </div>
          <div v-if="byHour.length === 0" class="px-4 py-6 text-sm text-n-slate-10 text-center">
            Nenhum dado no período
          </div>
        </div>
      </div>
    </div>

    <!-- Tempo de resposta por hora -->
    <div v-else-if="activeTab === 'response'" class="flex flex-col gap-4">
      <p class="text-sm text-n-slate-10">Tempo médio de primeira resposta por hora do dia</p>
      <div class="flex items-end gap-1 h-48 px-1">
        <div
          v-for="row in responseRows"
          :key="row.hour"
          class="flex flex-col items-center gap-1 flex-1"
        >
          <span v-if="row.avg_seconds > 0" class="text-xs text-n-slate-10 leading-none">{{ fmtDuration(row.avg_seconds) }}</span>
          <div
            class="w-full rounded-t bg-n-brand-7 transition-all duration-300"
            :style="{ height: maxResponse > 0 ? `${Math.max(2, (row.avg_seconds / maxResponse) * 100)}%` : '2px',
                      opacity: row.avg_seconds > 0 ? 1 : 0.15 }"
          />
          <span class="text-xs text-n-slate-9 leading-none whitespace-nowrap">{{ fmtHour(row.hour) }}</span>
        </div>
      </div>

      <div class="rounded-xl border border-n-weak overflow-hidden mt-2">
        <div class="grid grid-cols-2 px-4 py-2 bg-n-slate-2 border-b border-n-weak text-xs font-medium text-n-slate-11">
          <span>Horário</span>
          <span class="text-right">Tempo médio 1ª resposta</span>
        </div>
        <div class="max-h-72 overflow-y-auto divide-y divide-n-weak/40">
          <div v-for="row in responseRows.filter(r => r.avg_seconds > 0)" :key="row.hour"
            class="grid grid-cols-2 px-4 py-2.5 hover:bg-n-slate-1 text-sm">
            <span class="text-n-slate-12 font-medium">{{ fmtHour(row.hour) }}</span>
            <span class="text-right text-n-slate-11">{{ fmtDuration(row.avg_seconds) }}</span>
          </div>
          <div v-if="responseByHour.length === 0" class="px-4 py-6 text-sm text-n-slate-10 text-center">
            Nenhum dado no período
          </div>
        </div>
      </div>
    </div>

    <!-- Agente × Hora -->
    <div v-else-if="activeTab === 'agent'" class="flex flex-col gap-4">
      <p class="text-sm text-n-slate-10">Conversas atribuídas por agente e faixa horária</p>
      <div v-if="agentNames.length === 0" class="px-4 py-8 text-sm text-n-slate-10 text-center">
        Nenhum dado no período
      </div>
      <div v-else class="overflow-x-auto rounded-xl border border-n-weak">
        <table class="min-w-max w-full text-sm">
          <thead>
            <tr class="bg-n-slate-2 border-b border-n-weak">
              <th class="sticky left-0 bg-n-slate-2 px-3 py-2 text-left text-xs font-medium text-n-slate-11 cursor-pointer select-none min-w-[140px]"
                @click="setSort('agent')">
                Agente
                <span v-if="sortKey === 'agent'" :class="sortDir === 1 ? 'i-lucide-chevron-up' : 'i-lucide-chevron-down'" class="inline-block ml-1 text-xs" />
              </th>
              <th v-for="h in 24" :key="h - 1"
                class="px-1.5 py-2 text-center text-xs font-medium text-n-slate-11 min-w-[36px] cursor-pointer select-none"
                @click="setSort(h - 1)">
                {{ fmtHour(h - 1) }}
                <span v-if="sortKey === h - 1" :class="sortDir === 1 ? 'i-lucide-chevron-up' : 'i-lucide-chevron-down'" class="inline-block ml-0.5 text-xs" />
              </th>
              <th class="px-3 py-2 text-right text-xs font-medium text-n-slate-11 cursor-pointer select-none"
                @click="setSort('total')">
                Total
                <span v-if="sortKey === 'total'" :class="sortDir === 1 ? 'i-lucide-chevron-up' : 'i-lucide-chevron-down'" class="inline-block ml-1 text-xs" />
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-n-weak/40">
            <tr v-for="row in sortedAgentMatrix" :key="row.agent" class="hover:bg-n-slate-1">
              <td class="sticky left-0 bg-n-solid-1 hover:bg-n-slate-1 px-3 py-2 text-n-slate-12 font-medium whitespace-nowrap">
                {{ row.agent }}
              </td>
              <td v-for="h in 24" :key="h - 1" class="px-1 py-1 text-center">
                <span
                  v-if="row[h - 1] > 0"
                  class="inline-flex items-center justify-center text-xs font-medium rounded w-7 h-6"
                  :class="heatColor(row[h - 1], Math.max(...sortedAgentMatrix.map(r => r[h - 1] || 0), 1))"
                >
                  {{ row[h - 1] }}
                </span>
                <span v-else class="inline-block w-7 h-6 rounded bg-n-slate-2 opacity-30" />
              </td>
              <td class="px-3 py-2 text-right text-n-slate-12 font-semibold">{{ row.total }}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
  </div>
</template>
