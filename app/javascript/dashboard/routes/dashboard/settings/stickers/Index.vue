<script setup>
import { ref, computed, onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { useAlert } from 'dashboard/composables';
import SettingsLayout from '../SettingsLayout.vue';
import BaseSettingsHeader from '../components/BaseSettingsHeader.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import StickersAPI from 'dashboard/api/sticker';

const { t } = useI18n();

const ACCEPTED_TYPES = ['image/webp', 'image/png', 'image/jpeg', 'image/gif'];
const MAX_SIZE = 2 * 1024 * 1024; // 2MB

const stickers = ref([]);
const isLoading = ref(false);
const isUploading = ref(false);
const fileInput = ref(null);
const showDeletePopup = ref(false);
const activeSticker = ref(null);

const hasStickers = computed(() => stickers.value.length > 0);

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

const triggerUpload = () => fileInput.value?.click();

const onFileSelected = async event => {
  const file = event.target.files?.[0];
  event.target.value = ''; // permite reenviar o mesmo arquivo
  if (!file) return;

  if (!ACCEPTED_TYPES.includes(file.type)) {
    useAlert(t('STICKERS_MGMT.UPLOAD.INVALID_TYPE'));
    return;
  }
  if (file.size > MAX_SIZE) {
    useAlert(t('STICKERS_MGMT.UPLOAD.TOO_LARGE'));
    return;
  }

  isUploading.value = true;
  try {
    const formData = new FormData();
    formData.append('file', file);
    formData.append('name', file.name);
    await StickersAPI.create(formData);
    await fetchStickers();
    useAlert(t('STICKERS_MGMT.UPLOAD.SUCCESS'));
  } catch (error) {
    useAlert(t('STICKERS_MGMT.UPLOAD.ERROR'));
  } finally {
    isUploading.value = false;
  }
};

const openDeletePopup = sticker => {
  activeSticker.value = sticker;
  showDeletePopup.value = true;
};
const closeDeletePopup = () => {
  showDeletePopup.value = false;
  activeSticker.value = null;
};

const confirmDeletion = async () => {
  const sticker = activeSticker.value;
  closeDeletePopup();
  if (!sticker) return;
  try {
    await StickersAPI.delete(sticker.id);
    stickers.value = stickers.value.filter(s => s.id !== sticker.id);
    useAlert(t('STICKERS_MGMT.DELETE.SUCCESS'));
  } catch (error) {
    useAlert(t('STICKERS_MGMT.DELETE.ERROR'));
  }
};
</script>

<template>
  <SettingsLayout
    :is-loading="isLoading"
    :loading-message="$t('STICKERS_MGMT.LOADING')"
    :no-records-found="!hasStickers"
    :no-records-message="$t('STICKERS_MGMT.LIST.404')"
  >
    <template #header>
      <BaseSettingsHeader
        :title="$t('STICKERS_MGMT.HEADER')"
        :description="$t('STICKERS_MGMT.DESCRIPTION')"
      >
        <template v-if="hasStickers" #count>
          <span class="text-body-main text-n-slate-11">
            {{ $t('STICKERS_MGMT.COUNT', { n: stickers.length }) }}
          </span>
        </template>
        <template #actions>
          <Button
            :label="$t('STICKERS_MGMT.HEADER_BTN_TXT')"
            size="sm"
            :is-loading="isUploading"
            @click="triggerUpload"
          />
          <input
            ref="fileInput"
            type="file"
            accept="image/webp,image/png,image/jpeg,image/gif"
            class="hidden"
            @change="onFileSelected"
          />
        </template>
      </BaseSettingsHeader>
    </template>

    <template #body>
      <div
        class="grid grid-cols-3 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8 gap-3"
      >
        <div
          v-for="sticker in stickers"
          :key="sticker.id"
          class="group relative aspect-square rounded-xl border border-n-weak bg-n-alpha-1 p-2 flex items-center justify-center"
        >
          <img
            :src="sticker.file_url"
            :alt="sticker.name"
            class="max-h-full max-w-full object-contain"
            loading="lazy"
          />
          <button
            type="button"
            class="absolute top-1 right-1 hidden group-hover:flex items-center justify-center size-6 rounded-full bg-n-solid-1 border border-n-weak text-n-slate-11 hover:text-n-ruby-11"
            :aria-label="$t('STICKERS_MGMT.DELETE.BUTTON_TEXT')"
            @click="openDeletePopup(sticker)"
          >
            <span class="i-lucide-trash-2 size-3.5" />
          </button>
        </div>
      </div>
    </template>

    <woot-delete-modal
      v-model:show="showDeletePopup"
      :on-close="closeDeletePopup"
      :on-confirm="confirmDeletion"
      :title="$t('STICKERS_MGMT.DELETE.CONFIRM.TITLE')"
      :message="$t('STICKERS_MGMT.DELETE.CONFIRM.MESSAGE')"
      :confirm-text="$t('STICKERS_MGMT.DELETE.CONFIRM.YES')"
      :reject-text="$t('STICKERS_MGMT.DELETE.CONFIRM.NO')"
    />
  </SettingsLayout>
</template>
