<script setup>
import { computed, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore } from 'vuex';
import SettingsLayout from '../SettingsLayout.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import { messageTimestamp } from 'shared/helpers/timeHelper';

const { t } = useI18n();
const store = useStore();

const plan = computed(() => store.getters['plan/getPlan']);
const aiCreditBalance = computed(
  () => store.getters['plan/getAiCreditBalance']
);
const subscription = computed(() => store.getters['plan/getSubscription']);
const limits = computed(() => store.getters['plan/getLimits']);
const overageCharges = computed(() => store.getters['plan/getOverageCharges']);
const uiFlags = computed(() => store.getters['plan/getUIFlags']);

// Preço definido quando pelo menos um dos campos existe (ambos são nullable/provisórios).
const hasPrice = computed(
  () =>
    plan.value &&
    (plan.value.monthly_price_cents != null ||
      plan.value.setup_fee_cents != null)
);

// cents -> R$ no formato brasileiro. Só chamado quando o valor não é nil.
const formatCurrency = cents =>
  new Intl.NumberFormat('pt-BR', {
    style: 'currency',
    currency: 'BRL',
  }).format((cents || 0) / 100);

const formatCycle = charge =>
  `${messageTimestamp(charge.cycle_start, 'dd/MM/yy')} – ${messageTimestamp(
    charge.cycle_end,
    'dd/MM/yy'
  )}`;

const statusLabel = status =>
  status === 'invoiced' ? t('PLAN.STATUS_INVOICED') : t('PLAN.STATUS_PENDING');

const statusClass = status =>
  status === 'invoiced'
    ? 'bg-n-teal-3 text-n-teal-11'
    : 'bg-n-amber-3 text-n-amber-11';

const getPercentageClass = percentageUsed => {
  if (!percentageUsed) return 'text-n-slate-11';
  if (percentageUsed >= 80) return 'text-n-ruby-11';
  if (percentageUsed >= 60) return 'text-n-amber-11';
  return 'text-n-teal-11';
};

const getProgressBarClass = percentageUsed => {
  if (!percentageUsed) return 'bg-n-slate-5';
  if (percentageUsed >= 80) return 'bg-n-ruby-10';
  if (percentageUsed >= 60) return 'bg-n-amber-10';
  return 'bg-n-teal-10';
};

const getLimitLabel = key => {
  const labelMap = {
    users: t('PLAN.LIMIT_USERS'),
    inboxes: t('PLAN.LIMIT_INBOXES'),
    ai_agents: t('PLAN.LIMIT_AI_AGENTS'),
    crm_pipelines: t('PLAN.LIMIT_CRM_PIPELINES'),
  };
  return labelMap[key] || key;
};

onMounted(() => {
  store.dispatch('plan/fetchPlanData');
});
</script>

<template>
  <SettingsLayout
    :is-loading="uiFlags.isFetching"
    :loading-message="$t('PLAN.LOADING')"
  >
    <template #header>
      <BaseSettingsHeader
        :title="$t('PLAN.HEADER')"
        :description="$t('PLAN.DESCRIPTION')"
        feature-name="plan"
      />
    </template>
    <template #body>
      <div class="flex flex-col gap-6 w-full max-w-4xl">
        <!-- Current Plan Card -->
        <div
          v-if="plan"
          class="border border-n-slate-6 rounded-lg p-6 bg-n-surface-1"
        >
          <h2 class="text-heading-2 text-n-slate-12 mb-4">
            {{ $t('PLAN.CURRENT_PLAN') }}
          </h2>
          <div class="flex items-center justify-between">
            <div>
              <p class="text-body-small text-n-slate-11 mb-1">
                {{ $t('PLAN.PLAN_NAME') }}
              </p>
              <p class="text-heading-3 text-n-slate-12">{{ plan.name }}</p>
            </div>
            <div v-if="subscription" class="text-right">
              <p class="text-body-small text-n-slate-11 mb-1">
                {{ $t('PLAN.NEXT_RENEWAL') }}
              </p>
              <p class="text-heading-3 text-n-slate-12">
                {{
                  messageTimestamp(subscription.next_renewal_at, 'MMM dd, yyyy')
                }}
              </p>
            </div>
          </div>
        </div>

        <!-- Price Card -->
        <div
          v-if="plan"
          class="border border-n-slate-6 rounded-lg p-6 bg-n-surface-1"
        >
          <h2 class="text-heading-2 text-n-slate-12 mb-4">
            {{ $t('PLAN.PRICE') }}
          </h2>
          <div v-if="hasPrice" class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div v-if="plan.monthly_price_cents != null">
              <p class="text-body-small text-n-slate-11 mb-1">
                {{ $t('PLAN.MONTHLY_PRICE') }}
              </p>
              <p class="text-heading-3 text-n-slate-12">
                {{ formatCurrency(plan.monthly_price_cents) }}
              </p>
            </div>
            <div v-if="plan.setup_fee_cents != null">
              <p class="text-body-small text-n-slate-11 mb-1">
                {{ $t('PLAN.SETUP_FEE') }}
              </p>
              <p class="text-heading-3 text-n-slate-12">
                {{ formatCurrency(plan.setup_fee_cents) }}
              </p>
            </div>
          </div>
          <p v-else class="text-body-small text-n-slate-10">
            {{ $t('PLAN.PRICE_TBD') }}
          </p>
        </div>

        <!-- AI Credits Card -->
        <div
          v-if="aiCreditBalance"
          class="border border-n-slate-6 rounded-lg p-6 bg-n-surface-1"
        >
          <h2 class="text-heading-2 text-n-slate-12 mb-4">
            {{ $t('PLAN.AI_CREDITS') }}
          </h2>
          <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
            <div>
              <p class="text-body-small text-n-slate-11 mb-2">
                {{ $t('PLAN.PLAN_CREDITS') }}
              </p>
              <p class="text-heading-3 text-n-teal-11">
                {{ aiCreditBalance.plan_credits }}
              </p>
              <p class="text-body-small text-n-slate-10 mt-1">
                {{ $t('PLAN.RENEWS_MONTHLY') }}
              </p>
            </div>
            <div>
              <p class="text-body-small text-n-slate-11 mb-2">
                {{ $t('PLAN.EXTRA_CREDITS') }}
              </p>
              <p class="text-heading-3 text-n-blue-11">
                {{ aiCreditBalance.extra_credits }}
              </p>
              <p class="text-body-small text-n-slate-10 mt-1">
                {{ $t('PLAN.PURCHASED_SEPARATELY') }}
              </p>
            </div>
            <div>
              <p class="text-body-small text-n-slate-11 mb-2">
                {{ $t('PLAN.TOTAL_BALANCE') }}
              </p>
              <p class="text-heading-3 text-n-slate-12">
                {{ aiCreditBalance.total }}
              </p>
            </div>
          </div>
        </div>

        <!-- Limits Card -->
        <div
          v-if="limits.length > 0"
          class="border border-n-slate-6 rounded-lg p-6 bg-n-surface-1"
        >
          <h2 class="text-heading-2 text-n-slate-12 mb-4">
            {{ $t('PLAN.ACCOUNT_LIMITS') }}
          </h2>
          <div class="space-y-6">
            <div
              v-for="limit in limits"
              :key="limit.key"
              class="flex flex-col gap-2"
            >
              <div class="flex items-center justify-between">
                <div class="flex items-center gap-2">
                  <span class="text-body-main text-n-slate-12">
                    {{ getLimitLabel(limit.key) }}
                  </span>
                  <Icon
                    v-if="limit.percentage_used && limit.percentage_used >= 80"
                    v-tooltip.right="$t('PLAN.LIMIT_WARNING')"
                    icon="i-lucide-alert-circle"
                    class="size-4 text-n-ruby-11"
                  />
                </div>
                <span :class="getPercentageClass(limit.percentage_used)">
                  {{ limit.current_value }}
                  /
                  {{ limit.unlimited ? $t('PLAN.UNLIMITED') : limit.max_value }}
                </span>
              </div>
              <div
                v-if="!limit.unlimited"
                class="w-full bg-n-slate-4 rounded-full h-2"
              >
                <div
                  :class="getProgressBarClass(limit.percentage_used)"
                  class="h-full rounded-full transition-all"
                  :style="{
                    width: `${Math.min(limit.percentage_used || 0, 100)}%`,
                  }"
                />
              </div>
              <p
                v-if="!limit.unlimited"
                class="text-body-small text-n-slate-10"
              >
                {{ limit.percentage_used || 0 }}% {{ $t('PLAN.USED') }}
              </p>
            </div>
          </div>
        </div>

        <!-- Overage Charges (só aparece se houver cobranças) -->
        <div
          v-if="overageCharges.length > 0"
          class="border border-n-slate-6 rounded-lg p-6 bg-n-surface-1"
        >
          <h2 class="text-heading-2 text-n-slate-12 mb-4">
            {{ $t('PLAN.OVERAGE_CHARGES') }}
          </h2>
          <table class="w-full text-body-small">
            <thead>
              <tr class="text-n-slate-11 text-left">
                <th class="font-medium pb-2">
                  {{ $t('PLAN.OVERAGE_CYCLE') }}
                </th>
                <th class="font-medium pb-2">{{ $t('PLAN.OVERAGE_ITEM') }}</th>
                <th class="font-medium pb-2 text-right">
                  {{ $t('PLAN.OVERAGE_AVG') }}
                </th>
                <th class="font-medium pb-2 text-right">
                  {{ $t('PLAN.OVERAGE_TOTAL') }}
                </th>
                <th class="font-medium pb-2 text-right">
                  {{ $t('PLAN.OVERAGE_STATUS') }}
                </th>
              </tr>
            </thead>
            <tbody>
              <tr
                v-for="(charge, index) in overageCharges"
                :key="`${charge.cycle_end}-${charge.plan_limit_key}-${index}`"
                class="border-t border-n-slate-4"
              >
                <td class="py-2 text-n-slate-12">{{ formatCycle(charge) }}</td>
                <td class="py-2 text-n-slate-12">
                  {{ getLimitLabel(charge.plan_limit_key) }}
                </td>
                <td class="py-2 text-right text-n-slate-12">
                  {{ charge.average_excess }}
                </td>
                <td class="py-2 text-right text-n-slate-12">
                  {{ formatCurrency(charge.total_cents) }}
                </td>
                <td class="py-2 text-right">
                  <span
                    :class="statusClass(charge.status)"
                    class="inline-flex px-2 py-0.5 rounded-full"
                  >
                    {{ statusLabel(charge.status) }}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </template>
  </SettingsLayout>
</template>
