<script setup>
import { computed } from 'vue';
import FlowSelect from 'dashboard/routes/dashboard/settings/operationalFlows/FlowSelect.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import TagMultiSelectComboBox from 'dashboard/components-next/combobox/TagMultiSelectComboBox.vue';
import TemplatePicker from './TemplatePicker.vue';
import {
  PRIORITIES,
  TEMPERATURE_VALUES,
  CONVERSATION_STATUSES,
  actionIcon,
  isOfficialWhatsApp,
} from './automationForm';

// One numbered action of the rule with the fields of its action_name. Edits are emitted as a
// patched copy of the action ({ action_name, action_params }).
const props = defineProps({
  index: { type: Number, required: true },
  total: { type: Number, required: true },
  error: { type: String, default: '' },
  pipelines: { type: Array, default: () => [] },
  currentPipelineId: { type: Number, default: null },
  inboxes: { type: Array, default: () => [] },
  teams: { type: Array, default: () => [] },
  agents: { type: Array, default: () => [] },
  labels: { type: Array, default: () => [] },
});

const emit = defineEmits(['remove', 'moveUp', 'moveDown']);

const model = defineModel({ type: Object, required: true });

const name = computed(() => model.value.action_name);
const params = computed(() => model.value.action_params || {});

const setParam = patch => {
  model.value = {
    ...model.value,
    action_params: { ...model.value.action_params, ...patch },
  };
};

const whatsappInboxes = computed(() =>
  props.inboxes.filter(isOfficialWhatsApp)
);

const selectedInbox = computed(() =>
  props.inboxes.find(inbox => inbox.id === Number(params.value.inbox_id))
);

// A new conversation on the official WhatsApp API can only be opened with a template.
const needsTemplate = computed(() => isOfficialWhatsApp(selectedInbox.value));

// Templates belong to an inbox: switching it drops the picked template.
const onInboxChange = inboxId =>
  setParam({ inbox_id: inboxId, template: null });

const targetPipelineId = computed(
  () => Number(params.value.pipeline_id) || props.currentPipelineId
);

const targetStages = computed(
  () =>
    props.pipelines.find(pipeline => pipeline.id === targetPipelineId.value)
      ?.stages || []
);

const onPipelineChange = pipelineId =>
  setParam({ pipeline_id: pipelineId, stage_id: '' });

const labelOptions = computed(() =>
  props.labels.map(label => ({ value: label.title, label: label.title }))
);
</script>

<template>
  <div
    class="flex flex-col gap-3 p-4 border rounded-xl bg-n-solid-1"
    :class="error ? 'border-n-ruby-8' : 'border-n-weak'"
  >
    <div class="flex items-center gap-2">
      <span
        class="flex items-center justify-center text-xs font-semibold rounded-full size-6 bg-n-brand/10 text-n-blue-11 shrink-0"
      >
        {{ index + 1 }}
      </span>
      <span :class="actionIcon(name)" class="size-4 text-n-slate-11 shrink-0" />
      <span class="flex-1 min-w-0 text-sm font-medium truncate text-n-slate-12">
        {{ $t(`CRM_AUTOMATIONS.ACTIONS.NAMES.${name}`) }}
      </span>
      <Button
        v-tooltip.top="$t('CRM_AUTOMATIONS.ACTIONS.MOVE_UP')"
        type="button"
        variant="ghost"
        color="slate"
        size="sm"
        icon="i-lucide-chevron-up"
        :disabled="index === 0"
        @click="emit('moveUp')"
      />
      <Button
        v-tooltip.top="$t('CRM_AUTOMATIONS.ACTIONS.MOVE_DOWN')"
        type="button"
        variant="ghost"
        color="slate"
        size="sm"
        icon="i-lucide-chevron-down"
        :disabled="index === total - 1"
        @click="emit('moveDown')"
      />
      <Button
        v-tooltip.top="$t('CRM_AUTOMATIONS.ACTIONS.REMOVE')"
        type="button"
        variant="ghost"
        color="ruby"
        size="sm"
        icon="i-lucide-trash-2"
        @click="emit('remove')"
      />
    </div>

    <TextArea
      v-if="name === 'send_message' || name === 'add_private_note'"
      :model-value="params.content || ''"
      :label="
        name === 'send_message'
          ? $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.CONTENT_LABEL')
          : $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.NOTE_LABEL')
      "
      :placeholder="
        name === 'send_message'
          ? $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.CONTENT_PLACEHOLDER')
          : $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.NOTE_PLACEHOLDER')
      "
      min-height="5rem"
      auto-height
      resize
      @update:model-value="setParam({ content: $event })"
    />

    <template v-else-if="name === 'send_template'">
      <label class="flex flex-col gap-1 text-sm text-n-slate-11">
        <span>{{
          $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.WHATSAPP_INBOX_LABEL')
        }}</span>
        <FlowSelect
          :model-value="params.inbox_id"
          select-class="bg-n-solid-2"
          @update:model-value="onInboxChange"
        >
          <option value="" disabled>
            {{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.INBOX_PLACEHOLDER') }}
          </option>
          <option
            v-for="inbox in whatsappInboxes"
            :key="inbox.id"
            :value="inbox.id"
          >
            {{ inbox.name }}
          </option>
        </FlowSelect>
        <span v-if="!whatsappInboxes.length" class="text-xs text-n-amber-11">
          {{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.NO_WHATSAPP_INBOXES') }}
        </span>
      </label>
      <TemplatePicker
        v-if="params.inbox_id"
        :inbox-id="params.inbox_id"
        :model-value="params.template"
        @update:model-value="setParam({ template: $event })"
      />
      <TextArea
        :model-value="params.content || ''"
        :label="$t('CRM_AUTOMATIONS.ACTIONS.FIELDS.OPTIONAL_TEXT_LABEL')"
        :placeholder="
          $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.OPTIONAL_TEXT_PLACEHOLDER')
        "
        min-height="5rem"
        auto-height
        resize
        @update:model-value="setParam({ content: $event })"
      />
    </template>

    <Input
      v-else-if="name === 'send_webhook'"
      :model-value="params.url || ''"
      type="url"
      :label="$t('CRM_AUTOMATIONS.ACTIONS.FIELDS.URL_LABEL')"
      :placeholder="$t('CRM_AUTOMATIONS.ACTIONS.FIELDS.URL_PLACEHOLDER')"
      :message="$t('CRM_AUTOMATIONS.ACTIONS.FIELDS.URL_HINT')"
      @update:model-value="setParam({ url: $event })"
    />

    <template v-else-if="name === 'create_conversation'">
      <label class="flex flex-col gap-1 text-sm text-n-slate-11">
        <span>{{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.INBOX_LABEL') }}</span>
        <FlowSelect
          :model-value="params.inbox_id"
          select-class="bg-n-solid-2"
          @update:model-value="onInboxChange"
        >
          <option value="" disabled>
            {{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.INBOX_PLACEHOLDER') }}
          </option>
          <option v-for="inbox in inboxes" :key="inbox.id" :value="inbox.id">
            {{ inbox.name }}
          </option>
        </FlowSelect>
      </label>
      <template v-if="needsTemplate">
        <p class="mb-0 text-xs text-n-amber-11">
          {{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.TEMPLATE_REQUIRED_HINT') }}
        </p>
        <TemplatePicker
          :inbox-id="params.inbox_id"
          :model-value="params.template"
          @update:model-value="setParam({ template: $event })"
        />
      </template>
      <TextArea
        :model-value="params.content || ''"
        :label="
          needsTemplate
            ? $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.OPTIONAL_TEXT_LABEL')
            : $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.CONTENT_LABEL')
        "
        :placeholder="$t('CRM_AUTOMATIONS.ACTIONS.FIELDS.CONTENT_PLACEHOLDER')"
        min-height="5rem"
        auto-height
        resize
        @update:model-value="setParam({ content: $event })"
      />
    </template>

    <div v-else-if="name === 'move_stage'" class="grid gap-3 md:grid-cols-2">
      <label class="flex flex-col gap-1 text-sm text-n-slate-11">
        <span>{{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.PIPELINE_LABEL') }}</span>
        <FlowSelect
          :model-value="targetPipelineId"
          select-class="bg-n-solid-2"
          @update:model-value="onPipelineChange"
        >
          <option
            v-for="pipeline in pipelines"
            :key="pipeline.id"
            :value="pipeline.id"
          >
            {{ pipeline.name }}
          </option>
        </FlowSelect>
      </label>
      <label class="flex flex-col gap-1 text-sm text-n-slate-11">
        <span>{{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.STAGE_LABEL') }}</span>
        <FlowSelect
          :model-value="params.stage_id || ''"
          select-class="bg-n-solid-2"
          @update:model-value="setParam({ stage_id: $event })"
        >
          <option value="">
            {{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.STAGE_ENTRY') }}
          </option>
          <option
            v-for="stage in targetStages"
            :key="stage.id"
            :value="stage.id"
          >
            {{ stage.display_label }}
          </option>
        </FlowSelect>
      </label>
    </div>

    <label
      v-else-if="name === 'assign_team'"
      class="flex flex-col gap-1 text-sm text-n-slate-11"
    >
      <span>{{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.TEAM_LABEL') }}</span>
      <FlowSelect
        :model-value="params.team_id || ''"
        select-class="bg-n-solid-2"
        @update:model-value="setParam({ team_id: $event })"
      >
        <option value="">
          {{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.TEAM_REMOVE') }}
        </option>
        <option v-for="team in teams" :key="team.id" :value="team.id">
          {{ team.name }}
        </option>
      </FlowSelect>
    </label>

    <label
      v-else-if="name === 'assign_agent'"
      class="flex flex-col gap-1 text-sm text-n-slate-11"
    >
      <span>{{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.AGENT_LABEL') }}</span>
      <FlowSelect
        :model-value="params.assignee_id || ''"
        select-class="bg-n-solid-2"
        @update:model-value="setParam({ assignee_id: $event })"
      >
        <option value="">
          {{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.AGENT_REMOVE') }}
        </option>
        <option v-for="agent in agents" :key="agent.id" :value="agent.id">
          {{ agent.name }}
        </option>
      </FlowSelect>
    </label>

    <label
      v-else-if="name === 'change_priority'"
      class="flex flex-col gap-1 text-sm text-n-slate-11"
    >
      <span>{{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.PRIORITY_LABEL') }}</span>
      <FlowSelect
        :model-value="params.priority || ''"
        select-class="bg-n-solid-2"
        @update:model-value="setParam({ priority: $event })"
      >
        <option
          v-for="priority in PRIORITIES"
          :key="priority"
          :value="priority"
        >
          {{ $t(`CRM_AUTOMATIONS.ACTIONS.FIELDS.PRIORITIES.${priority}`) }}
        </option>
        <option value="">
          {{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.PRIORITIES.remove') }}
        </option>
      </FlowSelect>
    </label>

    <div
      v-else-if="name === 'add_label' || name === 'remove_label'"
      class="flex flex-col gap-1 text-sm text-n-slate-11"
    >
      <span>{{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.LABELS_LABEL') }}</span>
      <TagMultiSelectComboBox
        :model-value="params.labels || []"
        :options="labelOptions"
        :placeholder="$t('CRM_AUTOMATIONS.ACTIONS.FIELDS.LABELS_PLACEHOLDER')"
        :search-placeholder="$t('CRM_AUTOMATIONS.ACTIONS.FIELDS.LABELS_SEARCH')"
        :empty-state="$t('CRM_AUTOMATIONS.ACTIONS.FIELDS.LABELS_EMPTY')"
        @update:model-value="setParam({ labels: [...$event] })"
      />
    </div>

    <Input
      v-else-if="name === 'add_sla'"
      :model-value="params.minutes"
      type="number"
      min="1"
      class="max-w-xs"
      :label="$t('CRM_AUTOMATIONS.ACTIONS.FIELDS.SLA_MINUTES_LABEL')"
      :message="$t('CRM_AUTOMATIONS.ACTIONS.FIELDS.SLA_HINT')"
      @update:model-value="setParam({ minutes: $event })"
    />

    <p v-else-if="name === 'remove_sla'" class="mb-0 text-sm text-n-slate-11">
      {{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.REMOVE_SLA_HINT') }}
    </p>

    <label
      v-else-if="name === 'change_status'"
      class="flex flex-col gap-1 text-sm text-n-slate-11"
    >
      <span>{{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.STATUS_LABEL') }}</span>
      <FlowSelect
        :model-value="params.status || ''"
        select-class="bg-n-solid-2"
        @update:model-value="setParam({ status: $event })"
      >
        <option value="" disabled>
          {{ $t('CRM_AUTOMATIONS.CONDITIONS.SELECT_PLACEHOLDER') }}
        </option>
        <option
          v-for="status in CONVERSATION_STATUSES"
          :key="status"
          :value="status"
        >
          {{ $t(`CRM_AUTOMATIONS.ACTIONS.FIELDS.STATUSES.${status}`) }}
        </option>
      </FlowSelect>
    </label>

    <label
      v-else-if="name === 'change_temperature'"
      class="flex flex-col gap-1 text-sm text-n-slate-11"
    >
      <span>{{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.TEMPERATURE_LABEL') }}</span>
      <FlowSelect
        :model-value="params.temperature || ''"
        select-class="bg-n-solid-2"
        @update:model-value="setParam({ temperature: $event })"
      >
        <option
          v-for="temperature in TEMPERATURE_VALUES"
          :key="temperature"
          :value="temperature"
        >
          {{ $t(`CRM_AUTOMATIONS.ACTIONS.FIELDS.TEMPERATURES.${temperature}`) }}
        </option>
        <option value="">
          {{ $t('CRM_AUTOMATIONS.ACTIONS.FIELDS.TEMPERATURES.remove') }}
        </option>
      </FlowSelect>
    </label>

    <p v-if="error" class="mb-0 text-xs text-n-ruby-9">
      {{ $t(`CRM_AUTOMATIONS.ACTIONS.ERRORS.${error}`) }}
    </p>
  </div>
</template>
