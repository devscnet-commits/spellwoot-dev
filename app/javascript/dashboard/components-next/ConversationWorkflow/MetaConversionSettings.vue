<script setup>
import { ref, computed, watch, reactive } from 'vue';
import { useI18n } from 'vue-i18n';
import { useMapGetter } from 'dashboard/composables/store';
import { useAccount } from 'dashboard/composables/useAccount';
import { useAlert } from 'dashboard/composables';
import { ATTRIBUTE_TYPES } from './constants';

const { t } = useI18n();
const { currentAccount, updateAccount } = useAccount();
const conversationAttributes = useMapGetter(
  'attributes/getConversationAttributes'
);

const isSaving = ref(false);
const isDirty = ref(false);

// Form state
const enabled = ref(false);
const strategy = ref('on_arrival');
// Independent toggle: Lead on arrival can now run alongside the per-flow closing conversion.
const leadOnArrival = ref(true);
const winStatusField = ref('');
const winValue = ref('');
const lossValue = ref('');
const valueField = ref('');
const currency = ref('BRL');
const enrichmentFields = reactive({
  em: '', zp: '', ct: '', st: '', country: '', db: '', ge: '', external_id: '',
});

// Attribute option lists
const listAttributes = computed(() =>
  (conversationAttributes.value || [])
    .filter(a => a.attributeDisplayType === ATTRIBUTE_TYPES.LIST)
    .map(a => ({
      value: a.attributeKey,
      label: a.attributeDisplayName,
      attributeValues: a.attributeValues,
    }))
);

const numberAttributes = computed(() =>
  (conversationAttributes.value || [])
    .filter(a => a.attributeDisplayType === ATTRIBUTE_TYPES.NUMBER)
    .map(a => ({ value: a.attributeKey, label: a.attributeDisplayName }))
);

const allAttributeOptions = computed(() =>
  (conversationAttributes.value || []).map(a => ({
    value: a.attributeKey,
    label: a.attributeDisplayName,
  }))
);

const TEXT_LIKE = [ATTRIBUTE_TYPES.TEXT, ATTRIBUTE_TYPES.LINK];
const ENRICHMENT_FIELD_TYPES = {
  em: TEXT_LIKE,
  zp: [...TEXT_LIKE, ATTRIBUTE_TYPES.NUMBER],
  ct: TEXT_LIKE,
  st: TEXT_LIKE,
  country: TEXT_LIKE,
  db: [ATTRIBUTE_TYPES.DATE, ...TEXT_LIKE],
  ge: [ATTRIBUTE_TYPES.LIST, ...TEXT_LIKE],
  external_id: [...TEXT_LIKE, ATTRIBUTE_TYPES.NUMBER],
};

function attributeOptionsFor(metaKey) {
  const allowed = ENRICHMENT_FIELD_TYPES[metaKey];
  if (!allowed) return allAttributeOptions.value;
  return (conversationAttributes.value || [])
    .filter(a => allowed.includes(a.attributeDisplayType))
    .map(a => ({ value: a.attributeKey, label: a.attributeDisplayName }));
}

const winStatusValues = computed(() => {
  const attr = listAttributes.value.find(a => a.value === winStatusField.value);
  return attr?.attributeValues || [];
});

// Load from account settings
watch(
  currentAccount,
  account => {
    const s = account?.settings?.meta_conversion_settings || {};
    enabled.value = s.enabled ?? false;
    strategy.value = s.strategy ?? 'on_arrival';
    leadOnArrival.value =
      s.lead_on_arrival ?? (s.strategy == null || s.strategy === 'on_arrival');
    winStatusField.value = s.win_status_field ?? '';
    winValue.value = s.win_value ?? '';
    lossValue.value = s.loss_value ?? '';
    valueField.value = s.value_field ?? '';
    currency.value = s.currency ?? 'BRL';
    enrichmentFields.em = s.enrichment_fields?.em ?? '';
    enrichmentFields.zp = s.enrichment_fields?.zp ?? '';
    enrichmentFields.ct = s.enrichment_fields?.ct ?? '';
    enrichmentFields.st = s.enrichment_fields?.st ?? '';
    enrichmentFields.country = s.enrichment_fields?.country ?? '';
    enrichmentFields.db = s.enrichment_fields?.db ?? '';
    enrichmentFields.ge = s.enrichment_fields?.ge ?? '';
    enrichmentFields.external_id = s.enrichment_fields?.external_id ?? '';
    isDirty.value = false;
  },
  { immediate: true }
);

watch(
  [
    enabled,
    strategy,
    leadOnArrival,
    winStatusField,
    winValue,
    lossValue,
    valueField,
    currency,
    enrichmentFields,
  ],
  () => {
    isDirty.value = true;
  },
  { deep: true }
);

const handleSave = async () => {
  isSaving.value = true;
  try {
    const enrichment = Object.fromEntries(
      Object.entries(enrichmentFields).filter(([, v]) => v !== '')
    );
    await updateAccount(
      {
        meta_conversion_settings: {
          enabled: enabled.value,
          strategy: strategy.value,
          lead_on_arrival: leadOnArrival.value,
          win_status_field: winStatusField.value || null,
          win_value: winValue.value || null,
          loss_value: lossValue.value || null,
          value_field: valueField.value || null,
          currency: currency.value || 'BRL',
          enrichment_fields: Object.keys(enrichment).length ? enrichment : null,
        },
      },
      { silent: true }
    );
    isDirty.value = false;
    useAlert(t('CONVERSATION_WORKFLOW.META_CONVERSION.SAVE.SUCCESS'));
  } catch {
    useAlert(t('CONVERSATION_WORKFLOW.META_CONVERSION.SAVE.ERROR'));
  } finally {
    isSaving.value = false;
  }
};
</script>

<template>
  <div
    class="flex flex-col w-full outline-1 outline outline-n-container rounded-xl bg-n-solid-2 divide-y divide-n-weak"
  >
    <!-- Header -->
    <div class="flex justify-between items-center px-5 py-4">
      <div class="flex flex-col gap-1">
        <h3 class="text-heading-2 text-n-slate-12">
          {{ $t('CONVERSATION_WORKFLOW.META_CONVERSION.TITLE') }}
        </h3>
        <p class="mb-0 text-body-para text-n-slate-11">
          {{ $t('CONVERSATION_WORKFLOW.META_CONVERSION.DESCRIPTION') }}
        </p>
      </div>
      <label class="flex items-center gap-2 cursor-pointer select-none">
        <div
          class="relative w-10 h-5 rounded-full transition-colors"
          :class="enabled ? 'bg-n-brand' : 'bg-n-slate-5'"
        >
          <input v-model="enabled" type="checkbox" class="sr-only" />
          <div
            class="absolute top-0.5 size-4 bg-white rounded-full shadow transition-transform"
            :class="enabled ? 'translate-x-5' : 'translate-x-0.5'"
          />
        </div>
        <span class="text-body-para text-n-slate-12">
          {{
            enabled
              ? $t('CONVERSATION_WORKFLOW.META_CONVERSION.DISABLE_LABEL')
              : $t('CONVERSATION_WORKFLOW.META_CONVERSION.ENABLED_LABEL')
          }}
        </span>
      </label>
    </div>

    <template v-if="enabled">
      <!-- Lead on arrival (independent toggle) -->
      <div class="px-5 py-4 flex items-center justify-between gap-3">
        <div class="flex flex-col">
          <p class="text-body-para font-medium text-n-slate-12 mb-0">
            {{ $t('CONVERSATION_WORKFLOW.META_CONVERSION.LEAD_ON_ARRIVAL.LABEL') }}
          </p>
          <p class="text-body-small text-n-slate-11 mb-0">
            {{ $t('CONVERSATION_WORKFLOW.META_CONVERSION.LEAD_ON_ARRIVAL.DESC') }}
          </p>
        </div>
        <label class="flex items-center gap-2 cursor-pointer select-none shrink-0">
          <div
            class="relative w-10 h-5 rounded-full transition-colors"
            :class="leadOnArrival ? 'bg-n-brand' : 'bg-n-slate-5'"
          >
            <input v-model="leadOnArrival" type="checkbox" class="sr-only" />
            <div
              class="absolute top-0.5 size-4 bg-white rounded-full shadow transition-transform"
              :class="leadOnArrival ? 'translate-x-5' : 'translate-x-0.5'"
            />
          </div>
        </label>
      </div>

      <!-- Strategy -->
      <div class="px-5 py-4 flex flex-col gap-3">
        <p class="text-body-para font-medium text-n-slate-12 mb-0">
          {{ $t('CONVERSATION_WORKFLOW.META_CONVERSION.STRATEGY.LABEL') }}
        </p>
        <label class="flex items-start gap-3 cursor-pointer">
          <input
            v-model="strategy"
            type="radio"
            value="on_arrival"
            class="mt-0.5"
          />
          <div>
            <span class="text-body-para text-n-slate-12">
              {{
                $t(
                  'CONVERSATION_WORKFLOW.META_CONVERSION.STRATEGY.ON_ARRIVAL_LABEL'
                )
              }}
            </span>
            <p class="text-body-small text-n-slate-11 mb-0">
              {{
                $t(
                  'CONVERSATION_WORKFLOW.META_CONVERSION.STRATEGY.ON_ARRIVAL_DESC'
                )
              }}
            </p>
          </div>
        </label>
        <label class="flex items-start gap-3 cursor-pointer">
          <input
            v-model="strategy"
            type="radio"
            value="on_close"
            class="mt-0.5"
          />
          <div>
            <span class="text-body-para text-n-slate-12">
              {{
                $t(
                  'CONVERSATION_WORKFLOW.META_CONVERSION.STRATEGY.ON_CLOSE_LABEL'
                )
              }}
            </span>
            <p class="text-body-small text-n-slate-11 mb-0">
              {{
                $t(
                  'CONVERSATION_WORKFLOW.META_CONVERSION.STRATEGY.ON_CLOSE_DESC'
                )
              }}
            </p>
          </div>
        </label>
      </div>

      <!-- on_close config -->
      <div v-if="strategy === 'on_close'" class="px-5 py-4 flex flex-col gap-4">
        <p class="text-body-para font-medium text-n-slate-12 mb-0">
          {{
            $t('CONVERSATION_WORKFLOW.META_CONVERSION.ON_CLOSE.SECTION_TITLE')
          }}
        </p>

        <!-- Status field -->
        <div class="flex flex-col gap-1">
          <label class="text-body-small font-medium text-n-slate-12">
            {{
              $t('CONVERSATION_WORKFLOW.META_CONVERSION.ON_CLOSE.STATUS_FIELD')
            }}
          </label>
          <select
            v-model="winStatusField"
            class="text-body-para text-n-slate-12 bg-n-solid-1 border border-n-weak rounded px-3 py-2 w-full"
          >
            <option value="" disabled>
              {{
                $t(
                  'CONVERSATION_WORKFLOW.META_CONVERSION.ON_CLOSE.SELECT_FIELD'
                )
              }}
            </option>
            <option
              v-for="attr in listAttributes"
              :key="attr.value"
              :value="attr.value"
            >
              {{ attr.label }}
            </option>
          </select>
        </div>

        <!-- Win / Loss values -->
        <div v-if="winStatusField" class="grid grid-cols-2 gap-3">
          <div class="flex flex-col gap-1">
            <label class="text-body-small font-medium text-n-slate-12">
              {{
                $t('CONVERSATION_WORKFLOW.META_CONVERSION.ON_CLOSE.WIN_VALUE')
              }}
            </label>
            <select
              v-if="winStatusValues.length"
              v-model="winValue"
              class="text-body-para text-n-slate-12 bg-n-solid-1 border border-n-weak rounded px-3 py-2"
            >
              <option value="" disabled>
                {{
                  $t(
                    'CONVERSATION_WORKFLOW.META_CONVERSION.ON_CLOSE.SELECT_VALUE'
                  )
                }}
              </option>
              <option v-for="val in winStatusValues" :key="val" :value="val">
                {{ val }}
              </option>
            </select>
            <input
              v-else
              v-model="winValue"
              type="text"
              class="text-body-para text-n-slate-12 bg-n-solid-1 border border-n-weak rounded px-3 py-2"
            />
          </div>
          <div class="flex flex-col gap-1">
            <label class="text-body-small font-medium text-n-slate-12">
              {{
                $t('CONVERSATION_WORKFLOW.META_CONVERSION.ON_CLOSE.LOSS_VALUE')
              }}
            </label>
            <select
              v-if="winStatusValues.length"
              v-model="lossValue"
              class="text-body-para text-n-slate-12 bg-n-solid-1 border border-n-weak rounded px-3 py-2"
            >
              <option value="" disabled>
                {{
                  $t(
                    'CONVERSATION_WORKFLOW.META_CONVERSION.ON_CLOSE.SELECT_VALUE'
                  )
                }}
              </option>
              <option v-for="val in winStatusValues" :key="val" :value="val">
                {{ val }}
              </option>
            </select>
            <input
              v-else
              v-model="lossValue"
              type="text"
              class="text-body-para text-n-slate-12 bg-n-solid-1 border border-n-weak rounded px-3 py-2"
            />
          </div>
        </div>

        <!-- Value field + currency -->
        <div class="grid grid-cols-2 gap-3">
          <div class="flex flex-col gap-1">
            <label class="text-body-small font-medium text-n-slate-12">
              {{
                $t('CONVERSATION_WORKFLOW.META_CONVERSION.ON_CLOSE.VALUE_FIELD')
              }}
            </label>
            <select
              v-model="valueField"
              class="text-body-para text-n-slate-12 bg-n-solid-1 border border-n-weak rounded px-3 py-2"
            >
              <option value="">
                {{
                  $t(
                    'CONVERSATION_WORKFLOW.META_CONVERSION.ON_CLOSE.NO_VALUE_FIELD'
                  )
                }}
              </option>
              <option
                v-for="attr in numberAttributes"
                :key="attr.value"
                :value="attr.value"
              >
                {{ attr.label }}
              </option>
            </select>
          </div>
          <div class="flex flex-col gap-1">
            <label class="text-body-small font-medium text-n-slate-12">
              {{
                $t('CONVERSATION_WORKFLOW.META_CONVERSION.ON_CLOSE.CURRENCY')
              }}
            </label>
            <input
              v-model="currency"
              type="text"
              maxlength="3"
              class="text-body-para text-n-slate-12 bg-n-solid-1 border border-n-weak rounded px-3 py-2 uppercase"
              :placeholder="
                $t(
                  'CONVERSATION_WORKFLOW.META_CONVERSION.ON_CLOSE.CURRENCY_PLACEHOLDER'
                )
              "
            />
          </div>
        </div>
      </div>

      <!-- Enrichment fields -->
      <div class="px-5 py-4 flex flex-col gap-4">
        <div>
          <p class="text-body-para font-medium text-n-slate-12 mb-0">
            {{ $t('CONVERSATION_WORKFLOW.META_CONVERSION.ENRICHMENT.TITLE') }}
          </p>
          <p class="text-body-small text-n-slate-11 mb-0">
            Mapeie atributos da conversa para os campos de dados do contato enviados à Meta. Todos os valores são protegidos por hash antes do envio.
          </p>
        </div>

        <!-- Auto fields (read-only) -->
        <div class="flex flex-col gap-2">
          <p class="text-xs font-medium text-n-slate-11 uppercase tracking-wide">Enviados automaticamente do contato</p>
          <div class="grid grid-cols-2 gap-2">
            <div
              v-for="item in [
                { label: 'Telefone (ph)', icon: 'i-lucide-phone' },
                { label: 'Nome do contato (fn)', icon: 'i-lucide-user' },
              ]"
              :key="item.label"
              class="flex items-center gap-2 px-3 py-2 rounded-lg bg-n-teal-2 border border-n-teal-4"
            >
              <span :class="[item.icon, 'w-3.5 h-3.5 text-n-teal-11 shrink-0']" />
              <span class="text-xs text-n-teal-11 font-medium">{{ item.label }}</span>
            </div>
          </div>
        </div>

        <!-- Configurable fields -->
        <div class="flex flex-col gap-2">
          <p class="text-xs font-medium text-n-slate-11 uppercase tracking-wide">Dados adicionais (opcional)</p>
          <div class="grid grid-cols-2 gap-3">
            <div
              v-for="(label, metaKey) in {
                em: $t('CONVERSATION_WORKFLOW.META_CONVERSION.ENRICHMENT.EMAIL'),
                zp: $t('CONVERSATION_WORKFLOW.META_CONVERSION.ENRICHMENT.ZIP'),
                ct: $t('CONVERSATION_WORKFLOW.META_CONVERSION.ENRICHMENT.CITY'),
                st: $t('CONVERSATION_WORKFLOW.META_CONVERSION.ENRICHMENT.STATE'),
                country: $t('CONVERSATION_WORKFLOW.META_CONVERSION.ENRICHMENT.COUNTRY'),
                db: $t('CONVERSATION_WORKFLOW.META_CONVERSION.ENRICHMENT.DATE_OF_BIRTH'),
                ge: $t('CONVERSATION_WORKFLOW.META_CONVERSION.ENRICHMENT.GENDER'),
                external_id: $t('CONVERSATION_WORKFLOW.META_CONVERSION.ENRICHMENT.EXTERNAL_ID'),
              }"
              :key="metaKey"
              class="flex flex-col gap-1"
            >
              <label class="text-body-small font-medium text-n-slate-12">
                {{ label }}
              </label>
              <select
                v-model="enrichmentFields[metaKey]"
                class="text-body-para text-n-slate-12 bg-n-solid-1 border border-n-weak rounded px-3 py-2"
              >
                <option value="">
                  {{
                    $t(
                      'CONVERSATION_WORKFLOW.META_CONVERSION.ENRICHMENT.NOT_MAPPED'
                    )
                  }}
                </option>
                <option
                  v-for="attr in attributeOptionsFor(metaKey)"
                  :key="attr.value"
                  :value="attr.value"
                >
                  {{ attr.label }}
                </option>
              </select>
            </div>
          </div>
        </div>
      </div>
    </template>

    <!-- Save button -->
    <div class="flex justify-end px-5 py-4">
      <button
        class="text-body-para font-medium px-4 py-2 rounded-lg bg-n-brand text-white disabled:opacity-50"
        :disabled="isSaving || !isDirty"
        @click="handleSave"
      >
        {{
          isSaving
            ? $t('CONVERSATION_WORKFLOW.META_CONVERSION.SAVING')
            : $t('CONVERSATION_WORKFLOW.META_CONVERSION.SAVE_BUTTON')
        }}
      </button>
    </div>
  </div>
</template>
