<script setup>
// Botão + formulário "Solicitar mais créditos de IA" na tela de plano (billing Fase 1). Cria um
// AiCreditRequest (POST) que vira fila de aprovação da SCNET. Se já houver uma solicitação PENDENTE,
// mostra o status em vez do botão (evita pedido em dobro). Usa o axios GLOBAL (window.axios).
/* global axios */
import { ref, computed, onMounted } from 'vue';
import { useRoute } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import Button from 'dashboard/components-next/button/Button.vue';

const { t } = useI18n();
const route = useRoute();
const baseUrl = computed(
  () => `/api/v1/accounts/${route.params.accountId}/credit_requests`
);

const requests = ref([]);
const showForm = ref(false);
const amount = ref(null);
const reason = ref('');
const isSubmitting = ref(false);

const pendingRequest = computed(() =>
  requests.value.find(r => r.status === 'pending')
);

const fetchRequests = async () => {
  try {
    const { data } = await axios.get(baseUrl.value);
    requests.value = Array.isArray(data) ? data : [];
  } catch (error) {
    requests.value = [];
  }
};

const submit = async () => {
  if (!amount.value || Number(amount.value) <= 0) {
    useAlert(t('PLAN.CREDIT_REQUEST.INVALID_AMOUNT'));
    return;
  }
  isSubmitting.value = true;
  try {
    await axios.post(baseUrl.value, {
      credit_request: {
        amount_requested: Number(amount.value),
        reason: reason.value,
      },
    });
    useAlert(t('PLAN.CREDIT_REQUEST.SENT'));
    showForm.value = false;
    amount.value = null;
    reason.value = '';
    await fetchRequests();
  } catch (error) {
    useAlert(
      error?.response?.data?.errors?.[0] || t('PLAN.CREDIT_REQUEST.ERROR')
    );
  } finally {
    isSubmitting.value = false;
  }
};

onMounted(fetchRequests);
</script>

<template>
  <div class="border-t border-n-slate-4 mt-4 pt-4">
    <!-- Já existe uma solicitação pendente -->
    <div
      v-if="pendingRequest"
      class="flex items-center gap-2 text-body-small text-n-amber-11"
    >
      <span class="i-lucide-clock size-4 shrink-0" />
      {{
        $t('PLAN.CREDIT_REQUEST.PENDING', {
          amount: pendingRequest.amount_requested,
        })
      }}
    </div>

    <!-- Sem pendência: botão ou formulário -->
    <template v-else>
      <Button
        v-if="!showForm"
        variant="outline"
        size="sm"
        :label="$t('PLAN.CREDIT_REQUEST.BUTTON')"
        @click="showForm = true"
      />

      <div v-else class="flex flex-col gap-3 max-w-sm">
        <p class="text-body-main text-n-slate-12 mb-0">
          {{ $t('PLAN.CREDIT_REQUEST.TITLE') }}
        </p>
        <label class="flex flex-col gap-1 text-body-small text-n-slate-11">
          {{ $t('PLAN.CREDIT_REQUEST.AMOUNT_LABEL') }}
          <input
            v-model="amount"
            type="number"
            min="1"
            :placeholder="$t('PLAN.CREDIT_REQUEST.AMOUNT_PLACEHOLDER')"
            class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1"
          />
        </label>
        <label class="flex flex-col gap-1 text-body-small text-n-slate-11">
          {{ $t('PLAN.CREDIT_REQUEST.REASON_LABEL') }}
          <textarea
            v-model="reason"
            rows="2"
            :placeholder="$t('PLAN.CREDIT_REQUEST.REASON_PLACEHOLDER')"
            class="px-3 py-2 rounded-lg border border-n-weak bg-n-solid-1 resize-y"
          />
        </label>
        <div class="flex items-center gap-2">
          <Button
            size="sm"
            :label="$t('PLAN.CREDIT_REQUEST.SUBMIT')"
            :is-loading="isSubmitting"
            @click="submit"
          />
          <Button
            variant="ghost"
            color="slate"
            size="sm"
            :label="$t('PLAN.CREDIT_REQUEST.CANCEL')"
            @click="showForm = false"
          />
        </div>
      </div>
    </template>
  </div>
</template>
