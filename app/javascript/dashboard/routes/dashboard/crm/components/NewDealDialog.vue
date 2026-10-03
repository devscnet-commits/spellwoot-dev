<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { debounce } from '@chatwoot/utils';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import ContactsAPI from 'dashboard/api/contacts';
import PipelinesAPI from 'dashboard/api/pipelines';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';
import Spinner from 'dashboard/components-next/spinner/Spinner.vue';
import FlowSelect from 'dashboard/routes/dashboard/settings/operationalFlows/FlowSelect.vue';
import AttributeField from './AttributeField.vue';
import {
  isOpenStage,
  isBlank,
  formatDuration,
  requirementAppliesToStage,
  requirementConditionMet,
} from '../helpers';

// "Novo negócio": pick (or create) the contact, then the conversation that becomes the card — an
// existing one or a new one in an inbox — plus the starting stage and the fields it requires.
const props = defineProps({
  pipeline: { type: Object, default: null },
  attributes: { type: Array, default: () => [] },
});

const emit = defineEmits(['created']);

const { t } = useI18n();
const store = useStore();
const inboxes = useMapGetter('inboxes/getInboxes');

const dialogRef = ref(null);
const step = ref('contact');

// Step 1: the contact.
const query = ref('');
const results = ref([]);
const isSearching = ref(false);
const hasSearched = ref(false);
const newContact = reactive({ name: '', phone: '' });
const isCreatingContact = ref(false);

// Step 2: conversation, stage and fields.
const contact = ref(null);
const source = ref('existing');
const conversations = ref([]);
const isLoadingConversations = ref(false);
const conversationId = ref(null);
const inboxId = ref(null);
const stageId = ref(null);
const values = reactive({});
const missingKeys = ref([]);
const showErrors = ref(false);
const isSaving = ref(false);

const SOURCES = ['existing', 'new'];

const openStages = computed(() =>
  (props.pipeline?.stages || []).filter(isOpenStage)
);
const stage = computed(() =>
  openStages.value.find(item => item.id === stageId.value)
);

const definitionFor = key =>
  props.attributes.find(attribute => attribute.attributeKey === key) || {
    attributeKey: key,
    attributeDisplayName: key,
    attributeDisplayType: 'text',
  };

// Requirements of the chosen stage whose "if" clause holds, re-evaluated as the form is typed.
const requiredKeys = computed(() => {
  if (!stage.value) return [];
  return (props.pipeline.closing_requirements || [])
    .filter(
      requirement =>
        requirementAppliesToStage(
          requirement,
          stage.value,
          props.pipeline.stages
        ) && requirementConditionMet(requirement, values)
    )
    .map(requirement => requirement.attribute_key);
});

// Deal value first, then the stage requirements, then whatever else the backend flagged as missing.
const fieldKeys = computed(() => {
  const keys = [
    props.pipeline?.value_attribute_key,
    ...requiredKeys.value,
    ...missingKeys.value,
  ].filter(Boolean);
  return [...new Set(keys)];
});

const isRequired = key =>
  requiredKeys.value.includes(key) || missingKeys.value.includes(key);
const isMissing = key => isRequired(key) && isBlank(values[key]);
const hasMissingFields = computed(() => fieldKeys.value.some(isMissing));

const inboxName = id =>
  inboxes.value.find(inbox => inbox.id === id)?.name || '';

const activityAgo = conversation =>
  formatDuration(Date.now() / 1000 - conversation.last_activity_at);

const canSubmit = computed(() => {
  if (!contact.value || !stage.value) return false;
  return source.value === 'existing' ? !!conversationId.value : !!inboxId.value;
});

const searchContacts = debounce(
  async text => {
    // Typed again meanwhile: the newer call takes over.
    if (text !== query.value.trim()) return;
    isSearching.value = true;
    try {
      const { data } = await ContactsAPI.search(text);
      results.value = data.payload || [];
      hasSearched.value = true;
    } catch {
      useAlert(t('CRM_PIPELINE.NEW_DEAL.SEARCH_ERROR'));
    } finally {
      isSearching.value = false;
    }
  },
  300,
  false
);

watch(query, value => {
  if (!value.trim()) {
    results.value = [];
    hasSearched.value = false;
    return;
  }
  searchContacts(value.trim());
});

const loadConversations = async () => {
  isLoadingConversations.value = true;
  conversations.value = [];
  conversationId.value = null;
  try {
    const { data } = await ContactsAPI.getConversations(contact.value.id);
    conversations.value = [...(data.payload || [])].sort(
      (a, b) => b.last_activity_at - a.last_activity_at
    );
    conversationId.value = conversations.value[0]?.id || null;
    source.value = conversations.value.length ? 'existing' : 'new';
  } catch {
    useAlert(t('CRM_PIPELINE.NEW_DEAL.CONVERSATIONS_ERROR'));
  } finally {
    isLoadingConversations.value = false;
  }
};

const pickContact = picked => {
  contact.value = picked;
  step.value = 'details';
  loadConversations();
};

// Contacts only keep E.164 numbers; the hint asks for DDD + number, so a bare Brazilian number
// gets the +55 country code.
const normalizePhone = raw => {
  const digits = raw.replace(/\D/g, '');
  if (!digits) return '';
  const hasCountryCode = raw.trim().startsWith('+') || digits.length > 11;
  return hasCountryCode ? `+${digits}` : `+55${digits}`;
};

const createContact = async () => {
  const name = newContact.name.trim();
  if (!name) return;
  isCreatingContact.value = true;
  try {
    const phone = normalizePhone(newContact.phone);
    const { data } = await ContactsAPI.create({
      name,
      ...(phone ? { phone_number: phone } : {}),
    });
    pickContact(data.payload.contact);
  } catch (error) {
    useAlert(
      error.response?.data?.message ||
        t('CRM_PIPELINE.NEW_DEAL.CONTACT_CREATE_ERROR')
    );
  } finally {
    isCreatingContact.value = false;
  }
};

const reset = preselectedStageId => {
  step.value = 'contact';
  query.value = '';
  results.value = [];
  hasSearched.value = false;
  newContact.name = '';
  newContact.phone = '';
  contact.value = null;
  source.value = 'existing';
  conversations.value = [];
  conversationId.value = null;
  inboxId.value = inboxes.value[0]?.id || null;
  stageId.value =
    openStages.value.find(item => item.id === preselectedStageId)?.id ||
    openStages.value.find(item => item.is_default)?.id ||
    openStages.value[0]?.id ||
    null;
  Object.keys(values).forEach(key => delete values[key]);
  missingKeys.value = [];
  showErrors.value = false;
  isSaving.value = false;
};

const open = ({ stageId: preselectedStageId } = {}) => {
  reset(preselectedStageId);
  dialogRef.value?.open();
};

const submit = async () => {
  showErrors.value = true;
  if (!canSubmit.value || hasMissingFields.value) return;
  isSaving.value = true;
  const customAttributes = {};
  fieldKeys.value.forEach(key => {
    if (!isBlank(values[key])) customAttributes[key] = values[key];
  });
  const target =
    source.value === 'existing'
      ? { conversation_id: conversationId.value }
      : { contact_id: contact.value.id, inbox_id: inboxId.value };
  try {
    await PipelinesAPI.createCard(props.pipeline.id, {
      stage_id: stageId.value,
      custom_attributes: customAttributes,
      ...target,
    });
    dialogRef.value?.close();
    emit('created');
  } catch (error) {
    const missing = error.response?.data?.missing_attributes;
    if (missing?.length) {
      missingKeys.value = missing;
    } else {
      useAlert(
        error.response?.data?.error || t('CRM_PIPELINE.NEW_DEAL.CREATE_ERROR')
      );
    }
  } finally {
    isSaving.value = false;
  }
};

// Enter inside the form: creates the contact on step 1, the deal on step 2.
const onConfirm = () => {
  if (step.value === 'contact') createContact();
  else submit();
};

onMounted(() => {
  if (!inboxes.value.length) store.dispatch('inboxes/get');
});

defineExpose({ open });
</script>

<template>
  <Dialog
    ref="dialogRef"
    width="xl"
    overflow-y-auto
    :title="$t('CRM_PIPELINE.NEW_DEAL.TITLE')"
    :description="
      step === 'contact'
        ? $t('CRM_PIPELINE.NEW_DEAL.STEP_CONTACT')
        : $t('CRM_PIPELINE.NEW_DEAL.STEP_DETAILS')
    "
    @confirm="onConfirm"
  >
    <div v-if="step === 'contact'" class="flex flex-col gap-5">
      <div class="flex flex-col gap-2">
        <div
          class="flex items-center gap-2 px-3 rounded-lg border border-n-weak bg-n-solid-1 focus-within:ring-2 focus-within:ring-n-brand"
        >
          <span class="i-lucide-search size-4 text-n-slate-10 shrink-0" />
          <input
            v-model="query"
            type="text"
            autofocus
            class="flex-1 min-w-0 py-2.5 bg-transparent border-0 text-sm text-n-slate-12 focus:outline-none placeholder:text-n-slate-10"
            :placeholder="$t('CRM_PIPELINE.NEW_DEAL.SEARCH_PLACEHOLDER')"
          />
          <Spinner v-if="isSearching" :size="16" class="text-n-slate-10" />
        </div>
        <p v-if="!hasSearched" class="mb-0 text-xs text-n-slate-11">
          {{ $t('CRM_PIPELINE.NEW_DEAL.SEARCH_HINT') }}
        </p>
        <p v-else-if="!results.length" class="mb-0 text-xs text-n-slate-11">
          {{ $t('CRM_PIPELINE.NEW_DEAL.NO_RESULTS') }}
        </p>
        <ul
          v-else
          class="flex flex-col p-0 mb-0 max-h-60 overflow-y-auto list-none rounded-lg border border-n-weak divide-y divide-n-weak"
        >
          <li v-for="item in results" :key="item.id">
            <button
              type="button"
              class="flex items-center w-full gap-3 px-3 py-2 text-start hover:bg-n-alpha-2"
              @click="pickContact(item)"
            >
              <Avatar
                :name="item.name || ''"
                :src="item.thumbnail"
                :size="28"
                rounded-full
              />
              <span class="flex flex-col min-w-0">
                <span class="text-sm font-medium text-n-slate-12 truncate">
                  {{ item.name || item.phone_number }}
                </span>
                <span class="text-xs text-n-slate-11 truncate">
                  {{
                    [item.phone_number, item.email].filter(Boolean).join(' · ')
                  }}
                </span>
              </span>
            </button>
          </li>
        </ul>
      </div>

      <div
        class="flex flex-col gap-3 p-4 rounded-xl border border-n-weak bg-n-solid-1"
      >
        <span class="text-sm font-semibold text-n-slate-12">
          {{ $t('CRM_PIPELINE.NEW_DEAL.CREATE_CONTACT') }}
        </span>
        <div class="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <Input
            v-model="newContact.name"
            :label="$t('CRM_PIPELINE.NEW_DEAL.CONTACT_NAME')"
          />
          <Input
            v-model="newContact.phone"
            type="tel"
            :label="$t('CRM_PIPELINE.NEW_DEAL.CONTACT_PHONE')"
            :message="$t('CRM_PIPELINE.NEW_DEAL.CONTACT_PHONE_HINT')"
          />
        </div>
        <Button
          type="button"
          variant="faded"
          size="sm"
          icon="i-lucide-user-plus"
          class="self-start"
          :label="$t('CRM_PIPELINE.NEW_DEAL.CREATE_AND_CONTINUE')"
          :is-loading="isCreatingContact"
          :disabled="isCreatingContact || !newContact.name.trim()"
          @click="createContact"
        />
      </div>
    </div>

    <div v-else class="flex flex-col gap-5">
      <div
        class="flex items-center gap-3 p-3 rounded-xl border border-n-weak bg-n-solid-1"
      >
        <Avatar
          :name="contact.name || ''"
          :src="contact.thumbnail"
          :size="32"
          rounded-full
        />
        <div class="flex flex-col flex-1 min-w-0">
          <span class="text-xs text-n-slate-11">
            {{ $t('CRM_PIPELINE.NEW_DEAL.CONTACT') }}
          </span>
          <span class="text-sm font-semibold text-n-slate-12 truncate">
            {{ contact.name || contact.phone_number }}
          </span>
        </div>
        <Button
          type="button"
          variant="link"
          size="sm"
          :label="$t('CRM_PIPELINE.NEW_DEAL.CHANGE_CONTACT')"
          @click="step = 'contact'"
        />
      </div>

      <div class="flex flex-col gap-2">
        <span class="text-sm font-semibold text-n-slate-12">
          {{ $t('CRM_PIPELINE.NEW_DEAL.SOURCE') }}
        </span>
        <div class="flex gap-2">
          <button
            v-for="option in SOURCES"
            :key="option"
            type="button"
            class="flex-1 px-3 py-2 text-sm rounded-lg border"
            :class="
              source === option
                ? 'border-n-brand bg-n-brand/10 text-n-blue-11 font-medium'
                : 'border-n-weak text-n-slate-11 hover:bg-n-alpha-2'
            "
            @click="source = option"
          >
            {{
              option === 'existing'
                ? $t('CRM_PIPELINE.NEW_DEAL.SOURCE_EXISTING')
                : $t('CRM_PIPELINE.NEW_DEAL.SOURCE_NEW')
            }}
          </button>
        </div>

        <template v-if="source === 'existing'">
          <p v-if="isLoadingConversations" class="mb-0 text-xs text-n-slate-11">
            {{ $t('CRM_PIPELINE.NEW_DEAL.LOADING_CONVERSATIONS') }}
          </p>
          <p
            v-else-if="!conversations.length"
            class="mb-0 text-xs text-n-amber-11"
          >
            {{ $t('CRM_PIPELINE.NEW_DEAL.NO_CONVERSATIONS') }}
          </p>
          <ul
            v-else
            class="flex flex-col p-0 mb-0 max-h-48 overflow-y-auto list-none rounded-lg border border-n-weak divide-y divide-n-weak"
          >
            <li v-for="conversation in conversations" :key="conversation.id">
              <button
                type="button"
                class="flex items-center w-full gap-3 px-3 py-2 text-start hover:bg-n-alpha-2"
                :class="
                  conversationId === conversation.id ? 'bg-n-brand/10' : ''
                "
                @click="conversationId = conversation.id"
              >
                <span
                  class="size-4 shrink-0"
                  :class="
                    conversationId === conversation.id
                      ? 'i-lucide-circle-check text-n-blue-11'
                      : 'i-lucide-circle text-n-slate-10'
                  "
                />
                <span class="flex flex-col flex-1 min-w-0">
                  <span class="text-sm text-n-slate-12 truncate">
                    {{ inboxName(conversation.inbox_id) }}
                  </span>
                  <span class="text-xs text-n-slate-11 truncate">
                    {{
                      $t('CRM_PIPELINE.NEW_DEAL.LAST_ACTIVITY', {
                        time: activityAgo(conversation),
                      })
                    }}
                  </span>
                </span>
                <span class="text-xs text-n-slate-10 shrink-0">
                  {{
                    $t('CRM_PIPELINE.NEW_DEAL.CONVERSATION_ID', {
                      id: conversation.id,
                    })
                  }}
                </span>
              </button>
            </li>
          </ul>
        </template>

        <template v-else>
          <label class="flex flex-col gap-1.5 text-sm text-n-slate-11">
            {{ $t('CRM_PIPELINE.NEW_DEAL.INBOX') }}
            <FlowSelect v-model="inboxId">
              <option
                v-for="inbox in inboxes"
                :key="inbox.id"
                :value="inbox.id"
              >
                {{ inbox.name }}
              </option>
            </FlowSelect>
          </label>
          <p v-if="!inboxes.length" class="mb-0 text-xs text-n-amber-11">
            {{ $t('CRM_PIPELINE.NEW_DEAL.NO_INBOXES') }}
          </p>
        </template>
      </div>

      <label class="flex flex-col gap-1.5 text-sm text-n-slate-11">
        <span class="font-semibold text-n-slate-12">
          {{ $t('CRM_PIPELINE.NEW_DEAL.STAGE') }}
        </span>
        <FlowSelect v-model="stageId">
          <option v-for="item in openStages" :key="item.id" :value="item.id">
            {{ item.display_label }}
          </option>
        </FlowSelect>
      </label>

      <div v-if="fieldKeys.length" class="flex flex-col gap-4">
        <span class="text-sm font-semibold text-n-slate-12">
          {{ $t('CRM_PIPELINE.NEW_DEAL.FIELDS') }}
        </span>
        <AttributeField
          v-for="key in fieldKeys"
          :key="key"
          v-model="values[key]"
          :attribute="definitionFor(key)"
          :required="isRequired(key)"
          :has-error="showErrors && isMissing(key)"
        />
      </div>
      <p
        v-if="showErrors && hasMissingFields"
        class="mb-0 text-xs text-n-ruby-11"
      >
        {{ $t('CRM_PIPELINE.NEW_DEAL.MISSING_FIELDS') }}
      </p>
    </div>

    <template #footer>
      <div
        class="flex items-center justify-between w-full gap-3 pt-4 border-t border-n-weak"
      >
        <Button
          v-if="step === 'details'"
          type="button"
          variant="ghost"
          color="slate"
          icon="i-lucide-arrow-left"
          :label="$t('CRM_PIPELINE.NEW_DEAL.BACK')"
          @click="step = 'contact'"
        />
        <span v-else />
        <div class="flex items-center gap-3">
          <Button
            type="button"
            variant="ghost"
            color="slate"
            :label="$t('CRM_PIPELINE.NEW_DEAL.CANCEL')"
            @click="dialogRef?.close()"
          />
          <Button
            v-if="step === 'details'"
            type="submit"
            icon="i-lucide-plus"
            :label="$t('CRM_PIPELINE.NEW_DEAL.SUBMIT')"
            :is-loading="isSaving"
            :disabled="isSaving || !canSubmit"
          />
        </div>
      </div>
    </template>
  </Dialog>
</template>
