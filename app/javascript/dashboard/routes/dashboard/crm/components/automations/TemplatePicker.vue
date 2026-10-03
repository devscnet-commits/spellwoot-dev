<script setup>
import { computed } from 'vue';
import { useStore } from 'dashboard/composables/store';
import FlowSelect from 'dashboard/routes/dashboard/settings/operationalFlows/FlowSelect.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import {
  COMPONENT_TYPES,
  MEDIA_FORMATS,
  findComponentByType,
  buildTemplateParameters,
  replaceTemplateVariables,
} from 'dashboard/helper/templateHelper';

// WhatsApp template of an official inbox plus one input per {{n}} of its body. The value is the
// action's template param: { name, language, category, processed_params: { body: { '1': ... } } }.
const props = defineProps({
  inboxId: { type: [Number, String], default: '' },
});

const model = defineModel({ type: Object, default: null });
const store = useStore();

// Only approved text templates: the automation fills body variables, never media headers.
const usable = template =>
  Boolean(findComponentByType(template, COMPONENT_TYPES.BODY)) &&
  (!template.status || template.status.toLowerCase() === 'approved') &&
  !MEDIA_FORMATS.includes(
    findComponentByType(template, COMPONENT_TYPES.HEADER)?.format
  );

const templates = computed(() =>
  (store.getters['inboxes/getWhatsAppTemplates'](props.inboxId) || []).filter(
    usable
  )
);

// A template is identified by name + language.
const keyOf = template => `${template.name}::${template.language}`;

const selectedKey = computed(() =>
  model.value?.name ? `${model.value.name}::${model.value.language}` : ''
);

const selectedTemplate = computed(() =>
  templates.value.find(template => keyOf(template) === selectedKey.value)
);

const bodyText = computed(
  () =>
    findComponentByType(selectedTemplate.value || {}, COMPONENT_TYPES.BODY)
      ?.text || ''
);

const paramKeys = computed(() =>
  Object.keys(model.value?.processed_params?.body || {})
);

const preview = computed(() =>
  replaceTemplateVariables(bodyText.value, model.value?.processed_params || {})
);

const selectTemplate = key => {
  const template = templates.value.find(item => keyOf(item) === key);
  if (!template) {
    model.value = null;
    return;
  }
  const { name, language, category } = template;
  model.value = {
    name,
    language,
    category,
    processed_params: buildTemplateParameters(template, false),
  };
};

const setParam = (key, value) => {
  const params = model.value.processed_params || {};
  model.value = {
    ...model.value,
    processed_params: { ...params, body: { ...params.body, [key]: value } },
  };
};
</script>

<template>
  <div class="flex flex-col gap-3">
    <label class="flex flex-col gap-1 text-sm text-n-slate-11">
      <span>{{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.TEMPLATE_LABEL') }}</span>
      <FlowSelect
        :model-value="selectedKey"
        select-class="bg-n-solid-2"
        @update:model-value="selectTemplate"
      >
        <option value="" disabled>
          {{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.TEMPLATE_PLACEHOLDER') }}
        </option>
        <option
          v-for="template in templates"
          :key="keyOf(template)"
          :value="keyOf(template)"
        >
          {{
            $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.TEMPLATE_META', {
              name: template.name,
              language: template.language,
              category: template.category,
            })
          }}
        </option>
      </FlowSelect>
      <span v-if="inboxId && !templates.length" class="text-xs text-n-amber-11">
        {{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.NO_TEMPLATES') }}
      </span>
    </label>

    <template v-if="selectedTemplate">
      <div class="flex flex-col gap-1">
        <span class="text-xs font-medium text-n-slate-11">
          {{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.TEMPLATE_PREVIEW') }}
        </span>
        <p
          class="p-3 mb-0 text-sm whitespace-pre-wrap rounded-lg bg-n-alpha-1 text-n-slate-12"
        >
          {{ preview }}
        </p>
      </div>

      <div v-if="paramKeys.length" class="flex flex-col gap-2">
        <span class="text-xs font-medium text-n-slate-11">
          {{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.TEMPLATE_PARAMS') }}
        </span>
        <Input
          v-for="key in paramKeys"
          :key="key"
          :model-value="model.processed_params.body[key]"
          :label="
            $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.TEMPLATE_PARAM_LABEL', { key })
          "
          :placeholder="
            $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.TEMPLATE_PARAM_PLACEHOLDER', {
              key,
            })
          "
          @update:model-value="setParam(key, $event)"
        />
      </div>
    </template>
  </div>
</template>
