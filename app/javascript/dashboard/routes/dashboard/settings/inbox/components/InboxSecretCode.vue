<script setup>
import { ref, computed, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import InboxesAPI from 'dashboard/api/inboxes';
import NextButton from 'dashboard/components-next/button/Button.vue';

// Segredo do canal: a lista de caixas só traz o valor mascarado (não aparece inteiro no "Inspecionar").
// O valor completo é buscado no clique de "Mostrar" (endpoint só de admin) e fica só neste componente.
const props = defineProps({
  inboxId: { type: Number, required: true },
  field: { type: String, required: true },
  maskedValue: { type: String, default: '' },
  lang: { type: String, default: 'javascript' },
});

const { t } = useI18n();
const revealed = ref('');
const isLoading = ref(false);

const displayed = computed(() => revealed.value || props.maskedValue || '');

watch(
  () => [props.inboxId, props.maskedValue],
  () => {
    revealed.value = '';
  }
);

const reveal = async () => {
  isLoading.value = true;
  try {
    const { data } = await InboxesAPI.getSecret(props.inboxId, props.field);
    revealed.value = data.value || '';
  } catch {
    useAlert(t('INBOX_MGMT.SETTINGS_POPUP.SECRET_REVEAL_ERROR'));
  } finally {
    isLoading.value = false;
  }
};
</script>

<template>
  <div class="flex flex-col gap-2">
    <woot-code :script="displayed" :lang="lang" />
    <NextButton
      v-if="!revealed && maskedValue"
      xs
      slate
      faded
      icon="i-lucide-eye"
      class="self-start"
      :is-loading="isLoading"
      :label="t('INBOX_MGMT.SETTINGS_POPUP.SECRET_REVEAL')"
      @click="reveal"
    />
  </div>
</template>
