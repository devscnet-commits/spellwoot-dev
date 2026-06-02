<script setup>
import { ref, computed, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAccount } from 'dashboard/composables/useAccount';
import ReportHeader from './components/ReportHeader.vue';
import axios from 'axios';

const { t } = useI18n();
const { accountId } = useAccount();

const isLoading = ref(false);
const won = ref(0);
const lost = ref(0);
const aiClosed = ref(0);
const from = ref(0);
const to = ref(0);

const total = computed(() => won.value + lost.value + aiClosed.value);

const wonPercent = computed(() =>
  total.value ? Math.round((won.value / total.value) * 100) : 0
);
const lostPercent = computed(() =>
  total.value ? Math.round((lost.value / total.value) * 100) : 0
);
const aiPercent = computed(() =>
  total.value ? Math.round((aiClosed.value / total.value) * 100) : 0
);

const fetchData = async () => {
  isLoading.value = true;
  try {
    const params = {};
    if (from.value) params.since = from.value;
    if (to.value) params.until = to.value;

    const { data } = await axios.get(
      `/api/v2/accounts/${accountId.value}/reports/leads_summary`,
      { params }
    );
    won.value = data.won || 0;
    lost.value = data.lost || 0;
    aiClosed.value = data.ai_closed || 0;
  } catch {
    // silent
  } finally {
    isLoading.value = false;
  }
};

const onDateRangeChange = ({ from: f, to: tt }) => {
  from.value = f;
  to.value = tt;
  fetchData();
};

onMounted(fetchData);
</script>

<template>
  <div class="flex flex-col w-full">
    <ReportHeader
      :title="$t('CONVERSATION_WORKFLOW.LEADS_REPORT.TITLE')"
      :desc="$t('CONVERSATION_WORKFLOW.LEADS_REPORT.DESCRIPTION')"
      @date-range-change="onDateRangeChange"
    />
    <div class="flex flex-col gap-4 p-6">
      <div v-if="isLoading" class="text-n-slate-11 text-body-para">
        {{ $t('CONVERSATION_WORKFLOW.LEADS_REPORT.LOADING') }}
      </div>
      <div v-else class="grid grid-cols-1 gap-4 sm:grid-cols-3">
        <!-- Won -->
        <div class="flex flex-col gap-2 p-5 rounded-xl bg-n-solid-2 border border-n-weak">
          <div class="flex items-center gap-2">
            <span class="i-lucide-circle-check w-5 h-5 text-n-teal-11" />
            <span class="text-body-para font-medium text-n-slate-12">
              {{ $t('CONVERSATION_WORKFLOW.LEADS_REPORT.WON') }}
            </span>
          </div>
          <span class="text-heading-1 font-bold text-n-teal-11">{{ won }}</span>
          <span class="text-body-small text-n-slate-11">{{ wonPercent }}% {{ $t('CONVERSATION_WORKFLOW.LEADS_REPORT.OF_TOTAL') }}</span>
        </div>

        <!-- Lost -->
        <div class="flex flex-col gap-2 p-5 rounded-xl bg-n-solid-2 border border-n-weak">
          <div class="flex items-center gap-2">
            <span class="i-lucide-circle-x w-5 h-5 text-n-ruby-11" />
            <span class="text-body-para font-medium text-n-slate-12">
              {{ $t('CONVERSATION_WORKFLOW.LEADS_REPORT.LOST') }}
            </span>
          </div>
          <span class="text-heading-1 font-bold text-n-ruby-11">{{ lost }}</span>
          <span class="text-body-small text-n-slate-11">{{ lostPercent }}% {{ $t('CONVERSATION_WORKFLOW.LEADS_REPORT.OF_TOTAL') }}</span>
        </div>

        <!-- AI Closed -->
        <div class="flex flex-col gap-2 p-5 rounded-xl bg-n-solid-2 border border-n-weak">
          <div class="flex items-center gap-2">
            <span class="i-lucide-bot w-5 h-5 text-n-slate-9" />
            <span class="text-body-para font-medium text-n-slate-12">
              {{ $t('CONVERSATION_WORKFLOW.LEADS_REPORT.AI_CLOSED') }}
            </span>
          </div>
          <span class="text-heading-1 font-bold text-n-slate-11">{{ aiClosed }}</span>
          <span class="text-body-small text-n-slate-11">{{ aiPercent }}% {{ $t('CONVERSATION_WORKFLOW.LEADS_REPORT.OF_TOTAL') }}</span>
        </div>
      </div>

      <!-- Total -->
      <div v-if="!isLoading" class="text-body-small text-n-slate-11 mt-2">
        {{ $t('CONVERSATION_WORKFLOW.LEADS_REPORT.TOTAL') }}: <strong>{{ total }}</strong>
      </div>
    </div>
  </div>
</template>
