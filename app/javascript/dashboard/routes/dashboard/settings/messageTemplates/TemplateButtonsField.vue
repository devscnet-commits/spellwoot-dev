<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { vOnClickOutside } from '@vueuse/components';

import InboxesAPI from 'dashboard/api/inboxes';
import Button from 'dashboard/components-next/button/Button.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import DropdownMenu from 'dashboard/components-next/dropdown-menu/DropdownMenu.vue';

const props = defineProps({
  buttonTypeOptions: { type: Array, default: () => [] },
  buttonTypeLabels: { type: Object, default: () => ({}) },
  maxButtons: { type: Number, default: 10 },
  // The AUTHENTICATION category's COPY_CODE button is Meta's OTP button under the hood — fixed
  // text ("Copy Code"), no sample code — unlike the same button type used for a Marketing promo
  // code, where both are user-editable. Same UI type, different rules depending on category.
  isAuthentication: { type: Boolean, default: false },
  inboxId: { type: Number, default: null },
});

const buttons = defineModel({ type: Array, default: () => [] });

const BUTTON_TEXT_MAX_LENGTH = 25;
// Meta caps the voice call button's label at 20 characters, unlike every other button.
const VOICE_CALL_TEXT_MAX_LENGTH = 20;
// Same cap the backend validator applies to button[:phone_number].
const PHONE_MAX_LENGTH = 20;
const textMaxLength = button =>
  button.type === 'VOICE_CALL'
    ? VOICE_CALL_TEXT_MAX_LENGTH
    : BUTTON_TEXT_MAX_LENGTH;
// Meta fixes the button text for these two ("View catalog" / "Copy Pix code") and rejects a
// custom one, so there's nothing to let the user edit here.
const FIXED_TEXT_BUTTON_TYPES = ['CATALOG', 'ORDER_DETAILS'];

const hasFixedText = button =>
  FIXED_TEXT_BUTTON_TYPES.includes(button.type) ||
  (button.type === 'COPY_CODE' && props.isAuthentication);

const { t } = useI18n();
const isAddMenuOpen = ref(false);

// Meta only accepts the numeric ID of a Flow that already exists on the WABA. Typing it by hand
// meant a wrong value only surfaced ~10s later as Meta's generic "An unknown error has occurred",
// with nothing pointing at this field — so the ids come from the account instead.
const flows = ref([]);
const isLoadingFlows = ref(false);
const hasFlowsError = ref(false);

const hasFlowButton = computed(() =>
  buttons.value.some(button => button.type === 'FLOW')
);

const flowOptions = computed(() =>
  flows.value
    .filter(flow => flow.selectable)
    .map(flow => ({ value: String(flow.id), label: flow.name }))
);

// "Nenhum Flow" e "tem Flow, mas em rascunho" pedem ações diferentes do admin — criar um, ou
// publicar o que já existe. Dizer sempre a primeira manda quem já tem rascunho para o lugar errado.
const flowsStateKey = computed(() => {
  if (isLoadingFlows.value) return 'FLOWS_LOADING';
  if (hasFlowsError.value) return 'FLOWS_ERROR';
  return flows.value.length ? 'FLOWS_NONE_PUBLISHED' : 'FLOWS_EMPTY';
});

const flowsEmptyState = computed(() =>
  t(
    `MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.${flowsStateKey.value}`
  )
);

// Sem Flow selecionável não existe template de Flow: a Meta recusa, e antes disso o nosso próprio
// validador recusa com "O ID do Flow é obrigatório", que não diz ao admin o que fazer. Avisar aqui,
// no campo, enquanto ele ainda pode trocar de tipo de modelo.
// Criar o Flow aqui dentro: a conta sem Flow nenhum era um beco sem saída, e mandar o admin para
// o WhatsApp Manager no meio da criação de um modelo é trocar um problema por outro. Painel inline,
// não modal, porque este componente já roda dentro do modal de edição.
const FLOW_TEMPLATE_KEYS = ['LEAD_CAPTURE', 'APPOINTMENT', 'SURVEY'];

const isCreatingPanelOpen = ref(false);
const isCreatingFlow = ref(false);
const createFlowError = ref('');
const newFlow = ref({ key: 'LEAD_CAPTURE', name: '', submitLabel: '' });

const flowTemplateOptions = computed(() =>
  FLOW_TEMPLATE_KEYS.map(key => ({
    value: key,
    label: t(
      `MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.FLOW_TEMPLATES.${key}`
    ),
  }))
);

const openCreatePanel = () => {
  createFlowError.value = '';
  newFlow.value = { key: 'LEAD_CAPTURE', name: '', submitLabel: '' };
  isCreatingPanelOpen.value = true;
};

const createFlow = async button => {
  if (!newFlow.value.name.trim()) return;

  isCreatingFlow.value = true;
  createFlowError.value = '';
  try {
    const { data } = await InboxesAPI.createTemplateFlow(props.inboxId, {
      key: newFlow.value.key,
      name: newFlow.value.name.trim(),
      heading: newFlow.value.name.trim(),
      submit_label: newFlow.value.submitLabel.trim() || undefined,
    });
    // Entra na lista já selecionável e escolhido: o admin pediu este Flow, não vai querer procurá-lo.
    flows.value = [...flows.value, { ...data.flow, selectable: true }];
    button.flow_id = String(data.flow.id);
    // A Meta exige navigate_screen e recusa o template sem ele. Como o Flow é nosso, sabemos a
    // tela de entrada — não faz sentido devolver essa pergunta para quem acabou de criá-lo.
    if (data.flow.screen_id) button.navigate_screen = data.flow.screen_id;
    isCreatingPanelOpen.value = false;
  } catch (error) {
    createFlowError.value =
      error?.response?.data?.error ||
      t(
        'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.FLOW_CREATE_ERROR'
      );
  } finally {
    isCreatingFlow.value = false;
  }
};

const hasNoSelectableFlow = computed(
  () =>
    !isLoadingFlows.value &&
    !hasFlowsError.value &&
    flowOptions.value.length === 0
);

const fetchFlows = async () => {
  if (!props.inboxId || isLoadingFlows.value || flows.value.length) return;

  isLoadingFlows.value = true;
  hasFlowsError.value = false;
  try {
    const { data } = await InboxesAPI.getTemplateFlows(props.inboxId);
    flows.value = data.flows || [];
  } catch {
    hasFlowsError.value = true;
  } finally {
    isLoadingFlows.value = false;
  }
};

// Only hit the API once a Flow button actually exists — most templates never use one.
watch(hasFlowButton, hasFlow => hasFlow && fetchFlows(), { immediate: true });

const addMenuItems = () =>
  props.buttonTypeOptions.map(option => ({
    action: 'add_button',
    value: option.value,
    label: option.label,
  }));

const addButton = type => {
  if (buttons.value.length >= props.maxButtons) return;

  buttons.value = [
    ...buttons.value,
    {
      type,
      text: '',
      url: '',
      phone_number: '',
      example: '',
      flow_id: '',
      navigate_screen: '',
    },
  ];
  isAddMenuOpen.value = false;
};

const handleAddMenuAction = ({ value }) => addButton(value);

const removeButton = index => {
  buttons.value = buttons.value.filter((_, i) => i !== index);
};
</script>

<template>
  <div class="space-y-2">
    <div class="flex items-center gap-1.5">
      <h3 class="font-semibold text-n-slate-12">
        {{ t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.TITLE') }}
      </h3>
      <span class="text-caption text-n-slate-10">
        · {{ t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.OPTIONAL_BADGE') }}
      </span>
    </div>
    <p class="text-body-main text-n-slate-11">
      {{
        t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.DESCRIPTION', {
          count: maxButtons,
        })
      }}
    </p>

    <div
      v-if="buttons.length < maxButtons"
      v-on-click-outside="() => (isAddMenuOpen = false)"
      class="relative"
    >
      <Button
        :label="t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.ADD_BUTTON')"
        icon="i-lucide-plus"
        size="sm"
        @click="isAddMenuOpen = !isAddMenuOpen"
      />
      <DropdownMenu
        v-if="isAddMenuOpen"
        class="top-full ltr:left-0 rtl:right-0 mt-1.5 max-w-64"
        :menu-items="addMenuItems()"
        @action="handleAddMenuAction"
      />
    </div>
    <p v-else class="text-body-main text-n-slate-11">
      {{
        t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.MAX_REACHED', {
          count: maxButtons,
        })
      }}
    </p>

    <div
      v-for="(button, index) in buttons"
      :key="index"
      class="p-3 space-y-2 border rounded-lg border-n-weak"
    >
      <div class="flex items-center justify-between">
        <span
          class="flex items-center gap-2 font-medium text-body-main text-n-slate-12"
        >
          <span
            class="flex items-center justify-center flex-shrink-0 text-xs font-semibold rounded-full size-5 bg-n-blue-3 text-n-blue-11"
          >
            {{ index + 1 }}
          </span>
          {{ buttonTypeLabels[button.type] }}
        </span>
        <Button
          icon="i-lucide-trash-2"
          variant="ghost"
          color="ruby"
          size="xs"
          @click="removeButton(index)"
        />
      </div>

      <Input
        v-if="!hasFixedText(button)"
        v-model="button.text"
        :label="
          t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.TEXT', {
            count: textMaxLength(button),
          })
        "
        :maxlength="textMaxLength(button)"
      />
      <p v-else class="text-caption text-n-slate-10">
        {{ t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIXED_TEXT_HINT') }}
      </p>

      <Input
        v-if="button.type === 'URL'"
        v-model="button.url"
        :label="t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.URL')"
      />

      <Input
        v-if="button.type === 'PHONE_NUMBER'"
        v-model="button.phone_number"
        :label="
          t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.PHONE_NUMBER')
        "
        :maxlength="PHONE_MAX_LENGTH"
      />

      <Input
        v-if="button.type === 'COPY_CODE' && !isAuthentication"
        v-model="button.example"
        :label="
          t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.EXAMPLE_CODE')
        "
      />

      <div v-if="button.type === 'FLOW'" class="flex flex-col gap-1">
        <label class="mb-0.5 text-heading-3 text-n-slate-12">
          {{ t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.FLOW_ID') }}
        </label>
        <ComboBox
          v-model="button.flow_id"
          :options="flowOptions"
          :disabled="isLoadingFlows"
          :placeholder="
            t(
              'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.FLOW_PLACEHOLDER'
            )
          "
          :empty-state="flowsEmptyState"
          :has-error="hasNoSelectableFlow"
          :message="
            hasNoSelectableFlow
              ? flowsEmptyState
              : t(
                  'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.FLOW_ID_HINT'
                )
          "
        />

        <Button
          v-if="!isCreatingPanelOpen"
          :label="
            t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.FLOW_CREATE')
          "
          icon="i-lucide-plus"
          variant="ghost"
          size="sm"
          class="self-start"
          @click="openCreatePanel"
        />

        <div
          v-else
          class="p-3 space-y-3 border rounded-lg border-n-weak bg-n-alpha-black2"
        >
          <p class="text-body-main text-n-slate-11">
            {{
              t(
                'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.FLOW_CREATE_HINT'
              )
            }}
          </p>
          <div class="flex flex-col gap-1">
            <label class="mb-0.5 text-heading-3 text-n-slate-12">
              {{
                t(
                  'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.FLOW_TEMPLATE'
                )
              }}
            </label>
            <ComboBox v-model="newFlow.key" :options="flowTemplateOptions" />
          </div>
          <Input
            v-model="newFlow.name"
            :label="
              t('MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.FLOW_NAME')
            "
          />
          <Input
            v-model="newFlow.submitLabel"
            :label="
              t(
                'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.FLOW_SUBMIT_LABEL'
              )
            "
          />
          <p v-if="createFlowError" class="text-body-main text-n-ruby-9">
            {{ createFlowError }}
          </p>
          <div class="flex items-center gap-2">
            <Button
              :label="
                t(
                  'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.FLOW_CREATE_CONFIRM'
                )
              "
              size="sm"
              :is-loading="isCreatingFlow"
              :disabled="isCreatingFlow || !newFlow.name.trim()"
              @click="createFlow(button)"
            />
            <Button
              :label="
                t(
                  'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.FLOW_CREATE_CANCEL'
                )
              "
              faded
              slate
              size="sm"
              :disabled="isCreatingFlow"
              @click="isCreatingPanelOpen = false"
            />
          </div>
        </div>
      </div>
      <Input
        v-if="button.type === 'FLOW'"
        v-model="button.navigate_screen"
        :label="
          t(
            'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.NAVIGATE_SCREEN'
          )
        "
        :message="
          t(
            'MESSAGE_TEMPLATES_MGMT.CREATE.STEP_2.BUTTONS.FIELDS.NAVIGATE_SCREEN_HINT'
          )
        "
      />
    </div>
  </div>
</template>
