<script setup>
import { ref, computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import AccountPlanAPI from 'dashboard/api/account/plan';

// Upgrade de plano SEMPRE passa por pagamento: o plano só muda quando o pagamento é confirmado (hoje
// pela equipe Conexiia no Super Admin). Sem provedor de pagamento integrado ainda, esta tela só coloca o
// cliente em contato com a equipe: WhatsApp quando há número configurado, senão um pedido por e-mail.
const props = defineProps({
  upgradePlan: { type: Object, default: null },
  priceLabel: { type: String, default: '' },
  currentPlanName: { type: String, default: '' },
  accountId: { type: [Number, String], required: true },
  accountName: { type: String, default: '' },
  whatsappNumber: { type: String, default: null },
  emailRequest: { type: Boolean, default: false },
});

const { t } = useI18n();
const dialogRef = ref(null);
const isSending = ref(false);

const whatsappUrl = computed(() => {
  if (!props.whatsappNumber || !props.upgradePlan) return null;

  const text = t('PLAN.UPGRADE.WHATSAPP_MESSAGE', {
    accountId: props.accountId,
    accountName: props.accountName,
    currentPlan: props.currentPlanName,
    targetPlan: props.upgradePlan.name,
  });
  return `https://wa.me/${props.whatsappNumber}?text=${encodeURIComponent(text)}`;
});

const canRequestByEmail = computed(
  () => !whatsappUrl.value && props.emailRequest
);

const confirmLabel = computed(() =>
  whatsappUrl.value
    ? t('PLAN.UPGRADE.PAYMENT.CONTINUE_WHATSAPP')
    : t('PLAN.UPGRADE.PAYMENT.REQUEST')
);

const open = () => dialogRef.value?.open();

const requestByEmail = async () => {
  isSending.value = true;
  try {
    await AccountPlanAPI.requestUpgrade(props.upgradePlan.slug);
    useAlert(t('PLAN.UPGRADE.PAYMENT.REQUEST_SENT'));
    dialogRef.value?.close();
  } catch {
    useAlert(t('PLAN.UPGRADE.PAYMENT.REQUEST_ERROR'));
  } finally {
    isSending.value = false;
  }
};

const confirm = () => {
  if (whatsappUrl.value) {
    window.open(whatsappUrl.value, '_blank', 'noopener,noreferrer');
    dialogRef.value?.close();
  } else if (canRequestByEmail.value) {
    requestByEmail();
  }
};

defineExpose({ open });
</script>

<template>
  <Dialog
    ref="dialogRef"
    :title="$t('PLAN.UPGRADE.PAYMENT.TITLE', { name: upgradePlan?.name })"
    :description="priceLabel"
    :confirm-button-label="confirmLabel"
    :show-confirm-button="!!whatsappUrl || canRequestByEmail"
    :is-loading="isSending"
    @confirm="confirm"
  >
    <p class="text-body-main text-n-slate-11">
      {{
        whatsappUrl || canRequestByEmail
          ? $t('PLAN.UPGRADE.PAYMENT.INFO')
          : $t('PLAN.UPGRADE.PAYMENT.NO_CONTACT')
      }}
    </p>
  </Dialog>
</template>
