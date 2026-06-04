<script setup>
import { ref, computed, onMounted } from 'vue';
import { useAccount } from 'dashboard/composables/useAccount';
import subDays from 'date-fns/subDays';
import { getUnixStartOfDay, getUnixEndOfDay } from 'helpers/DateHelper';
import axios from 'axios';

const { accountId } = useAccount();

const isLoading = ref(false);
const since = ref(getUnixStartOfDay(subDays(new Date(), 29)));
const until = ref(getUnixEndOfDay(new Date()));
const activeTable = ref('campaign');

const summary = ref({ total: 0, won: 0, lost: 0, open: 0, ai_closed: 0, conversion_rate: 0 });
const byCampaign = ref([]);
const byAgent = ref([]);
const byInbox = ref([]);

const presets = [
  { id: 7,   label: '7 dias' },
  { id: 30,  label: '30 dias' },
  { id: 90,  label: '90 dias' },
  { id: 180, label: '180 dias' },
];
const selectedPreset = ref(30);

const selectPreset = days => {
  selectedPreset.value = days;
  since.value = getUnixStartOfDay(subDays(new Date(), days - 1));
  until.value = getUnixEndOfDay(new Date());
  fetchData();
};

const CHANNEL_LABELS = {
  'Channel::Api':           'WhatsApp (API)',
  'Channel::Whatsapp':      'WhatsApp (Cloud)',
  'Channel::FacebookPage':  'Facebook',
  'Channel::Instagram':     'Instagram',
  'Channel::WebWidget':     'Widget',
  'Channel::Email':         'E-mail',
  'Channel::Sms':           'SMS',
  'Channel::TwilioSms':     'Twilio SMS',
  'Channel::Telegram':      'Telegram',
  'Channel::Line':          'Line',
};
const channelLabel = type => CHANNEL_LABELS[type] || type || '—';

const conversionBg = rate => {
  if (rate >= 60) return 'text-n-teal-11';
  if (rate >= 30) return 'text-n-amber-11';
  return 'text-n-ruby-11';
};

const activeTableData = computed(() => {
  if (activeTable.value === 'campaign') return byCampaign.value;
  if (activeTable.value === 'agent') return byAgent.value;
  return byInbox.value;
});

const activeTableName = computed(() => {
  if (activeTable.value === 'campaign') return item => item.campaign || '—';
  if (activeTable.value === 'agent') return item => item.name || '—';
  return item => `${item.name} (${channelLabel(item.channel_type)})`;
});

const activeTableHeader = computed(() => {
  if (activeTable.value === 'campaign') return 'Campanha';
  if (activeTable.value === 'agent') return 'Agente';
  return 'Caixa de Entrada';
});

const fetchData = async () => {
  isLoading.value = true;
  try {
    const { data } = await axios.get(
      `/api/v2/accounts/${accountId.value}/reports/marketing_summary`,
      { params: { since: since.value, until: until.value } }
    );
    summary.value   = data.summary    || {};
    byCampaign.value = data.by_campaign || [];
    byAgent.value   = data.by_agent   || [];
    byInbox.value   = data.by_inbox   || [];
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
    <!-- Header -->
    <div class="px-6 pt-6 pb-4 border-b border-n-weak flex items-center justify-between gap-4 flex-wrap">
      <div>
        <h1 class="text-heading-1 font-semibold text-n-slate-12">Relatório de Marketing</h1>
        <p class="text-body-para text-n-slate-11 mt-0.5">
          Leads originados via Meta Ads (WhatsApp Click-to-Chat)
        </p>
      </div>

      <!-- Date range presets -->
      <div class="flex items-center gap-1 bg-n-solid-2 border border-n-weak rounded-lg p-1">
        <button
          v-for="preset in presets"
          :key="preset.id"
          class="px-3 py-1.5 rounded-md text-body-small font-medium transition-colors"
          :class="selectedPreset === preset.id
            ? 'bg-n-brand-9 text-white'
            : 'text-n-slate-11 hover:bg-n-slate-2'"
          @click="selectPreset(preset.id)"
        >
          {{ preset.label }}
        </button>
      </div>
    </div>

    <div class="flex flex-col gap-6 p-6">
      <!-- Loading -->
      <div v-if="isLoading" class="flex items-center gap-2 text-body-para text-n-slate-11 py-4">
        <span class="i-lucide-loader-2 w-4 h-4 animate-spin" />
        Carregando...
      </div>

      <template v-else>
        <!-- Summary Cards -->
        <div class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
          <!-- Total -->
          <div class="flex flex-col gap-1.5 p-4 rounded-xl bg-n-solid-2 border border-n-weak">
            <div class="flex items-center gap-1.5">
              <span class="i-lucide-target w-4 h-4 text-n-slate-9" />
              <span class="text-xs font-medium text-n-slate-11 uppercase tracking-wide">Leads Meta</span>
            </div>
            <span class="text-2xl font-bold text-n-slate-12">{{ summary.total }}</span>
          </div>

          <!-- Won -->
          <div class="flex flex-col gap-1.5 p-4 rounded-xl bg-n-teal-2 border border-n-teal-4">
            <div class="flex items-center gap-1.5">
              <span class="i-lucide-circle-check w-4 h-4 text-n-teal-11" />
              <span class="text-xs font-medium text-n-teal-11 uppercase tracking-wide">Ganhos</span>
            </div>
            <span class="text-2xl font-bold text-n-teal-11">{{ summary.won }}</span>
          </div>

          <!-- Lost -->
          <div class="flex flex-col gap-1.5 p-4 rounded-xl bg-n-ruby-2 border border-n-ruby-4">
            <div class="flex items-center gap-1.5">
              <span class="i-lucide-circle-x w-4 h-4 text-n-ruby-11" />
              <span class="text-xs font-medium text-n-ruby-11 uppercase tracking-wide">Perdidos</span>
            </div>
            <span class="text-2xl font-bold text-n-ruby-11">{{ summary.lost }}</span>
          </div>

          <!-- Open -->
          <div class="flex flex-col gap-1.5 p-4 rounded-xl bg-n-amber-2 border border-n-amber-4">
            <div class="flex items-center gap-1.5">
              <span class="i-lucide-clock w-4 h-4 text-n-amber-11" />
              <span class="text-xs font-medium text-n-amber-11 uppercase tracking-wide">Em Aberto</span>
            </div>
            <span class="text-2xl font-bold text-n-amber-11">{{ summary.open }}</span>
          </div>

          <!-- AI Closed -->
          <div class="flex flex-col gap-1.5 p-4 rounded-xl bg-n-solid-2 border border-n-weak">
            <div class="flex items-center gap-1.5">
              <span class="i-lucide-bot w-4 h-4 text-n-slate-9" />
              <span class="text-xs font-medium text-n-slate-11 uppercase tracking-wide">Fechados IA</span>
            </div>
            <span class="text-2xl font-bold text-n-slate-11">{{ summary.ai_closed }}</span>
          </div>

          <!-- Conversion Rate -->
          <div class="flex flex-col gap-1.5 p-4 rounded-xl bg-n-solid-2 border border-n-weak">
            <div class="flex items-center gap-1.5">
              <span class="i-lucide-percent w-4 h-4 text-n-slate-9" />
              <span class="text-xs font-medium text-n-slate-11 uppercase tracking-wide">Conversão</span>
            </div>
            <span class="text-2xl font-bold" :class="conversionBg(summary.conversion_rate)">
              {{ summary.conversion_rate }}%
            </span>
            <span class="text-xs text-n-slate-11">ganhos / (ganhos+perdidos)</span>
          </div>
        </div>

        <!-- Info banner -->
        <div class="flex items-start gap-2 px-4 py-3 rounded-lg bg-n-brand-2 border border-n-brand-4 text-body-small text-n-brand-11">
          <span class="i-lucide-info w-4 h-4 mt-0.5 shrink-0" />
          <span>
            Apenas conversas originadas por anúncios Meta Ads (Click-to-WhatsApp).
            Os totais aqui são um subconjunto do Relatório de Leads.
          </span>
        </div>

        <!-- Table tabs -->
        <div class="flex flex-col gap-0 rounded-xl bg-n-solid-2 border border-n-weak overflow-hidden">
          <!-- Tab selector -->
          <div class="flex items-center border-b border-n-weak bg-n-solid-1 px-4">
            <button
              v-for="tab in [
                { id: 'campaign', label: 'Por Campanha', icon: 'i-lucide-megaphone' },
                { id: 'agent',    label: 'Por Agente',   icon: 'i-lucide-user' },
                { id: 'inbox',    label: 'Por Caixa',    icon: 'i-lucide-inbox' },
              ]"
              :key="tab.id"
              class="flex items-center gap-1.5 px-4 py-3 text-body-small font-medium border-b-2 transition-colors"
              :class="activeTable === tab.id
                ? 'border-n-brand-9 text-n-brand-11'
                : 'border-transparent text-n-slate-11 hover:text-n-slate-12'"
              @click="activeTable = tab.id"
            >
              <span :class="[tab.icon, 'w-3.5 h-3.5']" />
              {{ tab.label }}
            </button>
          </div>

          <!-- Table -->
          <div v-if="activeTableData.length === 0" class="py-12 text-center text-body-para text-n-slate-11">
            Sem dados para o período selecionado.
          </div>
          <table v-else class="w-full text-left text-body-small">
            <thead class="bg-n-slate-1 text-xs font-medium text-n-slate-11 uppercase tracking-wide">
              <tr>
                <th class="px-4 py-3 w-1/3">{{ activeTableHeader }}</th>
                <th class="px-3 py-3 text-right">Total</th>
                <th class="px-3 py-3 text-right text-n-teal-11">Ganhos</th>
                <th class="px-3 py-3 text-right text-n-ruby-11">Perdidos</th>
                <th class="px-3 py-3 text-right text-n-amber-11">Em Aberto</th>
                <th class="px-3 py-3 text-right">IA</th>
                <th class="px-3 py-3 text-right">Conversão</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-n-weak/50">
              <tr
                v-for="(row, idx) in activeTableData"
                :key="idx"
                class="hover:bg-n-slate-1 transition-colors"
              >
                <td class="px-4 py-3 font-medium text-n-slate-12 max-w-[240px]">
                  <span class="truncate block">{{ activeTableName(row) }}</span>
                </td>
                <td class="px-3 py-3 text-right text-n-slate-12 font-medium">{{ row.total }}</td>
                <td class="px-3 py-3 text-right">
                  <span class="text-n-teal-11 font-medium">{{ row.won }}</span>
                </td>
                <td class="px-3 py-3 text-right">
                  <span class="text-n-ruby-11 font-medium">{{ row.lost }}</span>
                </td>
                <td class="px-3 py-3 text-right">
                  <span class="text-n-amber-11 font-medium">{{ row.open }}</span>
                </td>
                <td class="px-3 py-3 text-right text-n-slate-11">{{ row.ai_closed }}</td>
                <td class="px-3 py-3 text-right">
                  <span
                    class="inline-flex items-center gap-0.5 px-2 py-0.5 rounded-full text-xs font-medium"
                    :class="row.conversion_rate >= 50
                      ? 'bg-n-teal-3 text-n-teal-11'
                      : row.conversion_rate > 0
                        ? 'bg-n-amber-3 text-n-amber-11'
                        : 'bg-n-slate-3 text-n-slate-11'"
                  >
                    {{ row.conversion_rate }}%
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </template>
    </div>
  </div>
</template>
