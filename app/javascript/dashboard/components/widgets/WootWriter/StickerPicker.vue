<script setup>
import { ref, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import StickersAPI from 'dashboard/api/sticker';

const props = defineProps({
  conversationId: { type: [Number, String], required: true },
});
const emit = defineEmits(['close']);
const { t } = useI18n();

const stickers = ref([]);
const isLoading = ref(false);
const sendingId = ref(null);

const fetchStickers = async () => {
  isLoading.value = true;
  try {
    const { data } = await StickersAPI.get();
    stickers.value = Array.isArray(data) ? data : [];
  } catch (error) {
    stickers.value = [];
  } finally {
    isLoading.value = false;
  }
};
onMounted(fetchStickers);

const sendSticker = async sticker => {
  if (sendingId.value) return;
  sendingId.value = sticker.id;
  try {
    await StickersAPI.sendToConversation(props.conversationId, sticker.id);
    emit('close');
  } catch (error) {
    useAlert(t('STICKERS_MGMT.PICKER.SEND_ERROR'));
  } finally {
    sendingId.value = null;
  }
};
</script>

<template>
  <div>
    <!-- backdrop para fechar ao clicar fora -->
    <div class="fixed inset-0 z-40" @click="emit('close')" />
    <div
      class="absolute bottom-full left-0 mb-2 z-50 w-80 max-h-72 overflow-auto rounded-xl border border-n-weak bg-n-solid-1 shadow-lg p-3"
    >
      <p class="text-xs font-medium text-n-slate-11 mb-2">
        {{ $t('STICKERS_MGMT.PICKER.TITLE') }}
      </p>
      <p
        v-if="!isLoading && !stickers.length"
        class="text-xs text-n-slate-11 py-4 text-center mb-0"
      >
        {{ $t('STICKERS_MGMT.PICKER.EMPTY') }}
      </p>
      <div v-else class="grid grid-cols-4 gap-2">
        <button
          v-for="sticker in stickers"
          :key="sticker.id"
          type="button"
          class="aspect-square rounded-lg border border-n-weak bg-n-alpha-1 p-1 flex items-center justify-center hover:border-n-brand disabled:opacity-50"
          :disabled="sendingId === sticker.id"
          @click="sendSticker(sticker)"
        >
          <img
            :src="sticker.file_url"
            :alt="sticker.name"
            class="max-h-full max-w-full object-contain"
            loading="lazy"
          />
        </button>
      </div>
    </div>
  </div>
</template>
