<script setup>
import { ref, computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';

// Upgrade de plano SEMPRE passa por pagamento: o plano só muda quando o pagamento é confirmado (hoje
// pela equipe Conexiia no Super Admin). Sem provedor de pagamento integrado ainda, a forma escolhida
// vai na mensagem de WhatsApp para a equipe combinar o pagamento.
const props = defineProps({
  upgradePlan: { type: Object, default: null },
  priceLabel: { type: String, default: '' },
  currentPlanName: { type: String, default: '' },
  accountId: { type: [Number, String], required: true },
  accountName: { type: String, default: '' },
  whatsappNumber: { type: String, default: null },
});

const { t } = useI18n();
const dialogRef = ref(null);
const paymentMethod = ref('pix');

const paymentOptions = computed(() => [
  { value: 'pix', label: t('PLAN.UPGRADE.PAYMENT.PIX') },
  { value: 'card', label: t('PLAN.UPGRADE.PAYMENT.CARD') },
]);

const whatsappUrl = computed(() => {
  if (!props.whatsappNumber || !props.upgradePlan) return null;

  const method = paymentOptions.value.find(
    o => o.value === paymentMethod.value
  );
  const text = t('PLAN.UPGRADE.WHATSAPP_MESSAGE', {
    accountId: props.accountId,
    accountName: props.accountName,
    currentPlan: props.currentPlanName,
    targetPlan: props.upgradePlan.name,
    paymentMethod: method?.label,
  });
  return `https://wa.me/${props.whatsappNumber}?text=${encodeURIComponent(text)}`;
});

const open = () => {
  paymentMethod.value = 'pix';
  dialogRef.value?.open();
};

const continueOnWhatsapp = () => {
  if (!whatsappUrl.value) return;
  window.open(whatsappUrl.value, '_blank', 'noopener,noreferrer');
  dialogRef.value?.close();
};

defineExpose({ open });
</script>

<template>
  <Dialog
    ref="dialogRef"
    :title="$t('PLAN.UPGRADE.PAYMENT.TITLE', { name: upgradePlan?.name })"
    :description="priceLabel"
    :confirm-button-label="$t('PLAN.UPGRADE.PAYMENT.CONTINUE_WHATSAPP')"
    :show-confirm-button="!!whatsappUrl"
    @confirm="continueOnWhatsapp"
  >
    <div class="flex flex-col gap-4">
      <fieldset class="flex flex-col gap-2">
        <legend class="text-body-small text-n-slate-11 mb-2">
          {{ $t('PLAN.UPGRADE.PAYMENT.METHOD_LABEL') }}
        </legend>
        <label
          v-for="option in paymentOptions"
          :key="option.value"
          class="flex items-center gap-2 border border-n-slate-6 rounded-lg px-3 py-2 cursor-pointer"
          :class="{ 'border-n-brand': paymentMethod === option.value }"
        >
          <input
            v-model="paymentMethod"
            type="radio"
            name="upgrade-payment-method"
            :value="option.value"
          />
          <span class="text-body-main text-n-slate-12">{{ option.label }}</span>
        </label>
      </fieldset>
      <p class="text-body-small text-n-slate-11">
        {{
          whatsappUrl
            ? $t('PLAN.UPGRADE.PAYMENT.WHATSAPP_HINT')
            : $t('PLAN.UPGRADE.PAYMENT.NO_CONTACT')
        }}
      </p>
    </div>
  </Dialog>
</template>
