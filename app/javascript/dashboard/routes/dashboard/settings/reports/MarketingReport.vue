<script setup>
import { ref, computed, onMounted } from 'vue';
import { useAccount } from 'dashboard/composables/useAccount';
import { useMapGetter } from 'dashboard/composables/store';
import subDays from 'date-fns/subDays';
import format from 'date-fns/format';
import { getUnixStartOfDay, getUnixEndOfDay } from 'helpers/DateHelper';
import axios from 'axios';

const { accountId } = useAccount();

const inboxes = useMapGetter('inboxes/getInboxes');

const today = new Date();

// Date state
const since = ref(getUnixStartOfDay(subDays(today, 29)));
const until = ref(getUnixEndOfDay(today));
const customSince = ref(format(subDays(today, 29), 'yyyy-MM-dd'));
const customUntil = ref(format(today, 'yyyy-MM-dd'));
const selectedPreset = ref(30);

// Filter state
const filterInboxId = ref('');

// Data
const isLoading = ref(false);
const summary = ref({ total: 0, won: 0, lost: 0, open: 0, ai_closed: 0, pending: 0, attended: 0, revenue: 0, conversion_rate: 0 });
const byCampaign = ref([]);
const byMedia = ref([]);
const byAd = ref([]);
const byAgent = ref([]);
const byInbox = ref([]);

// Table state
const activeTab = ref('campaign');
const sortKey = ref('total');
const sortDir = ref(-1);

const PRESETS = [
  { id: 'today',     label: 'Hoje' },
  { id: 'yesterday', label: 'Ontem' },
  { id: 7,           label: '7d' },
  { id: 30,          label: '30d' },
  { id: 90,          label: '90d' },
  { id: 'custom',    label: 'Personalizado' },
];

const TABS = [
  { id: 'campaign', label: 'Por Campanha',    icon: 'i-lucide-megaphone' },
  { id: 'media',    label: 'Por Tipo de Mídia', icon: 'i-lucide-layers' },
  { id: 'ad',       label: 'Por Anúncio',     icon: 'i-lucide-image' },
  { id: 'agent',    label: 'Por Agente',      icon: 'i-lucide-user' },
  { id: 'inbox',    label: 'Por Caixa',       icon: 'i-lucide-inbox' },
];

const CHANNEL_LABELS = {
  'Channel::Api':          'WhatsApp API',
  'Channel::Whatsapp':     'WhatsApp Cloud',
  'Channel::FacebookPage': 'Facebook',
  'Channel::Instagram':    'Instagram',
  'Channel::WebWidget':    'Widget',
  'Channel::Email':        'E-mail',
};

const channelLabel = type => CHANNEL_LABELS[type] || type || '—';

const selectPreset = id => {
  selectedPreset.value = id;
  if (id === 'today') {
    since.value = getUnixStartOfDay(new Date());
    until.value = getUnixEndOfDay(new Date());
  } else if (id === 'yesterday') {
    const y = subDays(new Date(), 1);
    since.value = getUnixStartOfDay(y);
    until.value = getUnixEndOfDay(y);
  } else if (typeof id === 'number') {
    since.value = getUnixStartOfDay(subDays(new Date(), id - 1));
    until.value = getUnixEndOfDay(new Date());
  }
  if (id !== 'custom') fetchData();
};

const applyCustomRange = () => {
  since.value = getUnixStartOfDay(new Date(customSince.value));
  until.value = getUnixEndOfDay(new Date(customUntil.value));
  fetchData();
};

const showRevenue = computed(() => (summary.value.revenue || 0) > 0);

const avgTicket = computed(() => {
  const won = summary.value.won || 0;
  const rev = summary.value.revenue || 0;
  return won > 0 ? (rev / won) : 0;
});

const fmtCurrency = val =>
  new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(val || 0);

const funnelPct = (val, base) => (base > 0 ? Math.round((val / base) * 100) : 0);

const rawTableData = computed(() => {
  if (activeTab.value === 'campaign') return byCampaign.value;
  if (activeTab.value === 'media')    return byMedia.value;
  if (activeTab.value === 'ad')       return byAd.value;
  if (activeTab.value === 'agent')    return byAgent.value;
  return byInbox.value;
});

const sortedTableData = computed(() => {
  const data = [...rawTableData.value];
  return data.sort((a, b) => {
    const va = a[sortKey.value] ?? 0;
    const vb = b[sortKey.value] ?? 0;
    if (typeof va === 'string') return sortDir.value * va.localeCompare(vb);
    return sortDir.value * (vb - va);
  });
});

const rowName = row => {
  if (activeTab.value === 'campaign') return row.campaign || '(sem campanha)';
  if (activeTab.value === 'media')    return row.media_type || 'Não identificado';
  if (activeTab.value === 'ad')       return row.ad_id ? `${row.ad_id} / ${row.campaign || '—'}` : '—';
  if (activeTab.value === 'agent')    return row.name || '(Sem atribuição)';
  return `${row.name} (${channelLabel(row.channel_type)})`;
};

const colHeader = computed(() => {
  if (activeTab.value === 'campaign') return 'Campanha';
  if (activeTab.value === 'media')    return 'Tipo de Mídia';
  if (activeTab.value === 'ad')       return 'Anúncio / Campanha';
  if (activeTab.value === 'agent')    return 'Agente';
  return 'Caixa de Entrada';
});

const setSort = key => {
  if (sortKey.value === key) { sortDir.value *= -1; }
  else { sortKey.value = key; sortDir.value = -1; }
};

const sortIcon = key => {
  if (sortKey.value !== key) return 'i-lucide-chevrons-up-down';
  return sortDir.value === -1 ? 'i-lucide-chevron-down' : 'i-lucide-chevron-up';
};

const exportCsv = () => {
  const hasFmt = showRevenue.value;
  const header = ['Nome', 'Total', 'Atendidos', 'Ganhos', 'Perdidos', 'Em Aberto', 'IA', 'Conversão%', ...(hasFmt ? ['Receita'] : [])];
  const rows = sortedTableData.value.map(r => [
    `"${rowName(r).replace(/"/g, '""')}"`,
    r.total, r.attended, r.won, r.lost, r.open, r.ai_closed, r.conversion_rate,
    ...(hasFmt ? [r.revenue] : []),
  ]);
  const csv = [header.join(';'), ...rows.map(r => r.join(';'))].join('\n');
  const blob = new Blob(['﻿' + csv], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `marketing_${activeTab.value}.csv`;
  a.click();
  URL.revokeObjectURL(url);
};

const fetchData = async () => {
  isLoading.value = true;
  try {
    const params = {
      since: since.value,
      until: until.value,
      ...(filterInboxId.value ? { inbox_id: filterInboxId.value } : {}),
    };
    const { data } = await axios.get(
      `/api/v2/accounts/${accountId.value}/reports/marketing_summary`,
      { params }
    );
    summary.value   = data.summary     || {};
    byCampaign.value = data.by_campaign || [];
    byMedia.value   = data.by_media    || [];
    byAd.value      = data.by_ad       || [];
    byAgent.value   = data.by_agent    || [];
    byInbox.value   = data.by_inbox    || [];
  } catch {
    // silent
  } finally {
    isLoading.value = false;
  }
};

onMounted(fetchData);
</script>

<template>
  <div class="flex flex-col w-full min-h-0 overflow-y-auto">
    <!-- Header & Filters -->
    <div class="px-6 pt-5 pb-4 border-b border-n-weak">
      <div class="flex items-start justify-between gap-4 flex-wrap mb-4">
        <div>
          <h1 class="text-xl font-semibold text-n-slate-12">Relatório de Marketing</h1>
          <p class="text-sm text-n-slate-11 mt-0.5">Leads originados via Meta Ads (Click-to-WhatsApp)</p>
        </div>
        <div class="flex items-center gap-1 bg-n-solid-2 border border-n-weak rounded-lg p-1 flex-wrap">
          <button
            v-for="preset in PRESETS"
            :key="preset.id"
            class="px-3 py-1.5 rounded-md text-xs font-medium transition-colors"
            :class="selectedPreset === preset.id
              ? 'bg-n-brand-9 text-white'
              : 'text-n-slate-11 hover:bg-n-slate-3'"
            @click="selectPreset(preset.id)"
          >
            {{ preset.label }}
          </button>
        </div>
      </div>

      <!-- Custom date pickers -->
      <div v-if="selectedPreset === 'custom'" class="flex items-center gap-2 mb-3 flex-wrap">
        <input
          v-model="customSince"
          type="date"
          class="border border-n-weak rounded-md px-3 py-1.5 text-sm bg-n-solid-2 text-n-slate-12 focus:outline-none focus:border-n-brand-9"
        />
        <span class="text-n-slate-11 text-sm">até</span>
        <input
          v-model="customUntil"
          type="date"
          class="border border-n-weak rounded-md px-3 py-1.5 text-sm bg-n-solid-2 text-n-slate-12 focus:outline-none focus:border-n-brand-9"
        />
        <button
          class="px-4 py-1.5 rounded-md text-xs font-medium bg-n-brand-9 text-white hover:bg-n-brand-10 transition-colors"
          @click="applyCustomRange"
        >
          Aplicar
        </button>
      </div>

      <!-- Secondary filter -->
      <div class="flex items-center gap-2">
        <select
          v-model="filterInboxId"
          class="border border-n-weak rounded-md px-3 py-1.5 text-sm bg-n-solid-2 text-n-slate-12 focus:outline-none focus:border-n-brand-9 min-w-[180px] cursor-pointer"
          @change="fetchData"
        >
          <option value="">Todas as caixas</option>
          <option v-for="inbox in inboxes" :key="inbox.id" :value="inbox.id">{{ inbox.name }}</option>
        </select>
      </div>
    </div>

    <div class="flex flex-col gap-5 p-6">
      <!-- Loading -->
      <div v-if="isLoading" class="flex items-center justify-center gap-2 text-sm text-n-slate-11 py-16">
        <span class="i-lucide-loader-2 w-5 h-5 animate-spin" />
        Carregando...
      </div>

      <template v-else>
        <!-- Info banner -->
        <div class="flex items-start gap-2 px-4 py-3 rounded-lg bg-n-brand-2 border border-n-brand-4 text-sm text-n-brand-11">
          <span class="i-lucide-info w-4 h-4 mt-0.5 shrink-0" />
          <span>
            Apenas conversas originadas por anúncios Meta Ads (Click-to-WhatsApp).
            Os totais aqui são um subconjunto do Relatório de Leads.
          </span>
        </div>

        <!-- KPI Cards -->
        <div class="grid grid-cols-2 gap-3 sm:grid-cols-4 xl:grid-cols-7">
          <div class="flex flex-col gap-1.5 p-4 rounded-xl bg-n-solid-2 border border-n-weak">
            <div class="flex items-center gap-1.5">
              <span class="i-lucide-target w-4 h-4 text-n-slate-9" />
              <span class="text-xs font-medium text-n-slate-11 uppercase tracking-wide">Leads Meta</span>
            </div>
            <span class="text-2xl font-bold text-n-slate-12">{{ summary.total || 0 }}</span>
          </div>

          <div class="flex flex-col gap-1.5 p-4 rounded-xl bg-n-solid-2 border border-n-weak">
            <div class="flex items-center gap-1.5">
              <span class="i-lucide-headphones w-4 h-4 text-n-slate-9" />
              <span class="text-xs font-medium text-n-slate-11 uppercase tracking-wide">Atendidos</span>
            </div>
            <span class="text-2xl font-bold text-n-slate-12">{{ summary.attended || 0 }}</span>
            <span class="text-xs text-n-slate-10">{{ funnelPct(summary.attended, summary.total) }}% do total</span>
          </div>

          <div class="flex flex-col gap-1.5 p-4 rounded-xl bg-n-teal-2 border border-n-teal-4">
            <div class="flex items-center gap-1.5">
              <span class="i-lucide-circle-check w-4 h-4 text-n-teal-11" />
              <span class="text-xs font-medium text-n-teal-11 uppercase tracking-wide">Ganhos</span>
            </div>
            <span class="text-2xl font-bold text-n-teal-11">{{ summary.won || 0 }}</span>
          </div>

          <div class="flex flex-col gap-1.5 p-4 rounded-xl bg-n-ruby-2 border border-n-ruby-4">
            <div class="flex items-center gap-1.5">
              <span class="i-lucide-circle-x w-4 h-4 text-n-ruby-11" />
              <span class="text-xs font-medium text-n-ruby-11 uppercase tracking-wide">Perdidos</span>
            </div>
            <span class="text-2xl font-bold text-n-ruby-11">{{ summary.lost || 0 }}</span>
          </div>

          <div class="flex flex-col gap-1.5 p-4 rounded-xl bg-n-amber-2 border border-n-amber-4">
            <div class="flex items-center gap-1.5">
              <span class="i-lucide-clock w-4 h-4 text-n-amber-11" />
              <span class="text-xs font-medium text-n-amber-11 uppercase tracking-wide">Em Aberto</span>
            </div>
            <span class="text-2xl font-bold text-n-amber-11">{{ summary.open || 0 }}</span>
          </div>

          <div class="flex flex-col gap-1.5 p-4 rounded-xl bg-n-solid-2 border border-n-weak">
            <div class="flex items-center gap-1.5">
              <span class="i-lucide-percent w-4 h-4 text-n-slate-9" />
              <span class="text-xs font-medium text-n-slate-11 uppercase tracking-wide">Conversão</span>
            </div>
            <span
              class="text-2xl font-bold"
              :class="(summary.conversion_rate || 0) >= 60
                ? 'text-n-teal-11'
                : (summary.conversion_rate || 0) >= 30
                  ? 'text-n-amber-11'
                  : 'text-n-ruby-11'"
            >
              {{ summary.conversion_rate || 0 }}%
            </span>
            <span class="text-xs text-n-slate-10">ganhos / (ganhos+perdidos)</span>
          </div>

          <div v-if="showRevenue" class="flex flex-col gap-1.5 p-4 rounded-xl bg-n-solid-2 border border-n-weak">
            <div class="flex items-center gap-1.5">
              <span class="i-lucide-circle-dollar-sign w-4 h-4 text-n-teal-9" />
              <span class="text-xs font-medium text-n-slate-11 uppercase tracking-wide">Receita</span>
            </div>
            <span class="text-xl font-bold text-n-teal-11 leading-tight">{{ fmtCurrency(summary.revenue) }}</span>
            <span class="text-xs text-n-slate-10">ticket médio: {{ fmtCurrency(avgTicket) }}</span>
          </div>
        </div>

        <!-- Funnel -->
        <div class="rounded-xl bg-n-solid-2 border border-n-weak p-5">
          <h2 class="text-sm font-semibold text-n-slate-12 mb-5 flex items-center gap-1.5">
            <span class="i-lucide-filter w-4 h-4 text-n-brand-9" />
            Funil Meta Ads
          </h2>
          <div class="flex items-end gap-0 overflow-x-auto pb-1">
            <div class="flex flex-col items-center gap-2 flex-1 min-w-[100px]">
              <span class="text-xs text-n-slate-11 font-medium">Leads Meta</span>
              <div class="w-full rounded-t-md bg-n-brand-9/20 border border-n-brand-9/40 flex items-end justify-center" style="height:80px;">
                <span class="text-xs font-bold text-n-brand-11 mb-2">100%</span>
              </div>
              <span class="text-lg font-bold text-n-slate-12">{{ summary.total || 0 }}</span>
            </div>

            <div class="flex items-center pb-8 px-1">
              <span class="i-lucide-chevron-right w-5 h-5 text-n-slate-9" />
            </div>

            <div class="flex flex-col items-center gap-2 flex-1 min-w-[100px]">
              <span class="text-xs text-n-slate-11 font-medium">Atendidos</span>
              <div
                class="w-full rounded-t-md bg-n-amber-9/20 border border-n-amber-9/40 flex items-end justify-center"
                :style="`height:${Math.max(24, funnelPct(summary.attended, summary.total) * 0.8)}px`"
              >
                <span class="text-xs font-bold text-n-amber-11 mb-2">{{ funnelPct(summary.attended, summary.total) }}%</span>
              </div>
              <span class="text-lg font-bold text-n-slate-12">{{ summary.attended || 0 }}</span>
            </div>

            <div class="flex items-center pb-8 px-1">
              <span class="i-lucide-chevron-right w-5 h-5 text-n-slate-9" />
            </div>

            <div class="flex flex-col items-center gap-2 flex-1 min-w-[100px]">
              <span class="text-xs text-n-slate-11 font-medium">Ganhos</span>
              <div
                class="w-full rounded-t-md bg-n-teal-9/20 border border-n-teal-9/40 flex items-end justify-center"
                :style="`height:${Math.max(24, funnelPct(summary.won, summary.total) * 0.8)}px`"
              >
                <span class="text-xs font-bold text-n-teal-11 mb-2">{{ funnelPct(summary.won, summary.total) }}%</span>
              </div>
              <span class="text-lg font-bold text-n-teal-11">{{ summary.won || 0 }}</span>
            </div>

            <div class="flex items-center pb-8 px-1">
              <span class="i-lucide-chevron-right w-5 h-5 text-n-slate-9" />
            </div>

            <div class="flex flex-col items-center gap-2 flex-1 min-w-[100px]">
              <span class="text-xs text-n-slate-11 font-medium">Perdidos</span>
              <div
                class="w-full rounded-t-md bg-n-ruby-9/20 border border-n-ruby-9/40 flex items-end justify-center"
                :style="`height:${Math.max(24, funnelPct(summary.lost, summary.total) * 0.8)}px`"
              >
                <span class="text-xs font-bold text-n-ruby-11 mb-2">{{ funnelPct(summary.lost, summary.total) }}%</span>
              </div>
              <span class="text-lg font-bold text-n-ruby-11">{{ summary.lost || 0 }}</span>
            </div>
          </div>
        </div>

        <!-- Rankings Table -->
        <div class="rounded-xl bg-n-solid-2 border border-n-weak overflow-hidden">
          <div class="flex items-center justify-between border-b border-n-weak bg-n-solid-1 px-2">
            <div class="flex items-center overflow-x-auto">
              <button
                v-for="tab in TABS"
                :key="tab.id"
                class="flex items-center gap-1.5 px-3 py-3 text-xs font-medium border-b-2 transition-colors whitespace-nowrap"
                :class="activeTab === tab.id
                  ? 'border-n-brand-9 text-n-brand-11'
                  : 'border-transparent text-n-slate-11 hover:text-n-slate-12'"
                @click="activeTab = tab.id"
              >
                <span :class="[tab.icon, 'w-3.5 h-3.5']" />
                {{ tab.label }}
              </button>
            </div>
            <button
              class="flex items-center gap-1.5 px-3 py-2 text-xs font-medium text-n-slate-11 hover:text-n-slate-12 hover:bg-n-slate-3 rounded-md transition-colors shrink-0 mr-1"
              @click="exportCsv"
            >
              <span class="i-lucide-download w-3.5 h-3.5" />
              CSV
            </button>
          </div>

          <div v-if="sortedTableData.length === 0" class="py-14 text-center text-sm text-n-slate-11">
            Sem dados para o período e filtros selecionados.
          </div>

          <div v-else class="overflow-x-auto">
            <table class="w-full text-left text-sm">
              <thead class="bg-n-slate-2 text-xs font-medium text-n-slate-11 uppercase tracking-wide">
                <tr>
                  <th class="px-4 py-3 w-52">{{ colHeader }}</th>
                  <th
                    v-for="col in [
                      { key: 'total',           label: 'Total' },
                      { key: 'attended',        label: 'Atendidos' },
                      { key: 'won',             label: 'Ganhos',    cls: 'text-n-teal-11' },
                      { key: 'lost',            label: 'Perdidos',  cls: 'text-n-ruby-11' },
                      { key: 'open',            label: 'Em Aberto', cls: 'text-n-amber-11' },
                      { key: 'ai_closed',       label: 'IA' },
                      { key: 'conversion_rate', label: 'Conversão' },
                    ]"
                    :key="col.key"
                    class="px-3 py-3 text-right cursor-pointer select-none hover:text-n-slate-12 transition-colors"
                    :class="col.cls || ''"
                    @click="setSort(col.key)"
                  >
                    <span class="inline-flex items-center gap-1 justify-end">
                      {{ col.label }}
                      <span :class="[sortIcon(col.key), 'w-3 h-3 opacity-60']" />
                    </span>
                  </th>
                  <th
                    v-if="showRevenue"
                    class="px-3 py-3 text-right cursor-pointer select-none hover:text-n-slate-12 transition-colors"
                    @click="setSort('revenue')"
                  >
                    <span class="inline-flex items-center gap-1 justify-end">
                      Receita
                      <span :class="[sortIcon('revenue'), 'w-3 h-3 opacity-60']" />
                    </span>
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-n-weak/50">
                <tr
                  v-for="(row, idx) in sortedTableData"
                  :key="idx"
                  class="hover:bg-n-slate-1 transition-colors"
                >
                  <td class="px-4 py-3 font-medium text-n-slate-12 max-w-[220px]">
                    <span class="truncate block">{{ rowName(row) }}</span>
                  </td>
                  <td class="px-3 py-3 text-right font-medium text-n-slate-12">{{ row.total }}</td>
                  <td class="px-3 py-3 text-right text-n-slate-11">{{ row.attended }}</td>
                  <td class="px-3 py-3 text-right font-medium text-n-teal-11">{{ row.won }}</td>
                  <td class="px-3 py-3 text-right font-medium text-n-ruby-11">{{ row.lost }}</td>
                  <td class="px-3 py-3 text-right font-medium text-n-amber-11">{{ row.open }}</td>
                  <td class="px-3 py-3 text-right text-n-slate-11">{{ row.ai_closed }}</td>
                  <td class="px-3 py-3 text-right">
                    <span
                      class="inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium"
                      :class="row.conversion_rate >= 50
                        ? 'bg-n-teal-3 text-n-teal-11'
                        : row.conversion_rate > 0
                          ? 'bg-n-amber-3 text-n-amber-11'
                          : 'bg-n-slate-3 text-n-slate-11'"
                    >
                      {{ row.conversion_rate }}%
                    </span>
                  </td>
                  <td v-if="showRevenue" class="px-3 py-3 text-right text-n-teal-11 font-medium text-xs">
                    {{ fmtCurrency(row.revenue) }}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </template>
    </div>
  </div>
</template>
