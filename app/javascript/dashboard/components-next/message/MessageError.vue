<script setup>
import { computed } from 'vue';
import Icon from 'next/icon/Icon.vue';
import { useI18n } from 'vue-i18n';
import { useMessageContext } from './provider.js';
import { hasOneDayPassed } from 'shared/helpers/timeHelper';
import { ORIENTATION, MESSAGE_STATUS } from './constants';

const props = defineProps({
  error: { type: String, required: true },
});

const emit = defineEmits(['retry']);

const HTTP_ERROR_MAP = {
  '404 Not Found': 'Instância não encontrada — verifique a conexão da caixa',
  '401 Unauthorized': 'Sessão expirada — reconecte a caixa do WhatsApp',
  '403 Forbidden': 'Sem permissão para enviar mensagens nesta conta',
  '405 Method Not Allowed': 'Caixa desconectada — reconecte o WhatsApp',
  '422 Unprocessable Entity':
    'Número de telefone inválido ou não está no WhatsApp',
  '429 Too Many Requests':
    'Limite de mensagens atingido — aguarde alguns minutos',
  '500 Internal Server Error':
    'Erro no servidor do WhatsApp — tente reenviar em instantes',
  '502 Bad Gateway':
    'Erro no servidor do WhatsApp — tente reenviar em instantes',
  '503 Service Unavailable':
    'Erro no servidor do WhatsApp — tente reenviar em instantes',
};

const displayError = computed(() => HTTP_ERROR_MAP[props.error] || props.error);

const { orientation, status, createdAt, content, attachments } =
  useMessageContext();

const { t } = useI18n();

const canRetry = computed(() => {
  const hasContent = content.value !== null;
  const hasAttachments = attachments.value && attachments.value.length > 0;
  return !hasOneDayPassed(createdAt.value) && (hasContent || hasAttachments);
});
</script>

<template>
  <div class="text-xs text-n-ruby-11 flex items-center gap-1.5">
    <span>{{ t('CHAT_LIST.FAILED_TO_SEND') }}</span>
    <div class="relative group">
      <div
        class="bg-n-alpha-2 rounded-md size-5 grid place-content-center cursor-pointer"
      >
        <Icon
          icon="i-lucide-alert-triangle"
          class="text-n-ruby-11 size-[14px]"
        />
      </div>
      <div
        class="absolute bg-n-alpha-3 px-4 py-3 border rounded-xl border-n-strong text-n-slate-12 bottom-6 w-52 text-xs backdrop-blur-[100px] shadow-[0px_0px_24px_0px_rgba(0,0,0,0.12)] opacity-0 invisible group-hover:opacity-100 group-hover:visible transition-all break-all"
        :class="{
          'ltr:left-0 rtl:right-0': orientation === ORIENTATION.LEFT,
          'ltr:right-0 rtl:left-0': orientation === ORIENTATION.RIGHT,
        }"
      >
        {{ displayError }}
      </div>
    </div>
    <button
      v-if="canRetry"
      type="button"
      :disabled="status !== MESSAGE_STATUS.FAILED"
      class="bg-n-alpha-2 rounded-md size-5 grid place-content-center cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed"
      @click="emit('retry')"
    >
      <Icon
        icon="i-lucide-refresh-ccw"
        class="text-n-ruby-11 size-[14px]"
        :class="{ 'animate-spin': status === MESSAGE_STATUS.PROGRESS }"
      />
    </button>
  </div>
</template>
