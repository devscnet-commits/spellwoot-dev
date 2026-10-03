<script setup>
import { computed } from 'vue';
import Draggable from 'vuedraggable';
import PipelineCard from './PipelineCard.vue';
import { STAGE_DOT_CLASS, formatMoney } from '../helpers';

const props = defineProps({
  stage: { type: Object, required: true },
  column: { type: Object, required: true },
  color: { type: String, required: true },
  requirementsCount: { type: Number, default: 0 },
  isLoadingMore: { type: Boolean, default: false },
  now: { type: Number, required: true },
});

const emit = defineEmits([
  'dropped',
  'loadMore',
  'newCard',
  'open',
  'setTemperature',
  'aiFollowup',
]);

const isWon = computed(() => props.stage.polarity === 'positive');
const isLost = computed(() => props.stage.polarity === 'negative');

const columnClass = computed(() => {
  if (isWon.value) return 'border-n-teal-6';
  if (isLost.value) return 'border-n-ruby-6';
  return 'border-n-weak';
});

// vuedraggable moves the element between the column lists; the board persists it.
const onChange = event => {
  if (event.added) emit('dropped', event.added.element);
};
</script>

<template>
  <div
    class="flex flex-col w-72 shrink-0 h-full rounded-xl border bg-n-solid-1"
    :class="columnClass"
  >
    <div class="flex flex-col gap-2 px-3 pt-3 pb-2 border-b border-n-weak">
      <div class="flex items-center gap-2 min-w-0">
        <span
          v-if="isWon || isLost"
          class="flex items-center gap-1 px-1.5 py-0.5 text-xs font-medium rounded-md shrink-0"
          :class="
            isWon ? 'bg-n-teal-3 text-n-teal-11' : 'bg-n-ruby-3 text-n-ruby-11'
          "
        >
          <span
            :class="isWon ? 'i-lucide-circle-check' : 'i-lucide-circle-x'"
            class="size-3"
          />
          {{
            isWon
              ? $t('CRM_PIPELINE.BOARD.WON_BADGE')
              : $t('CRM_PIPELINE.BOARD.LOST_BADGE')
          }}
        </span>
        <span
          v-else
          class="size-2.5 rounded-full shrink-0"
          :class="STAGE_DOT_CLASS[color]"
        />
        <span class="text-sm font-semibold text-n-slate-12 truncate flex-1">
          {{ stage.display_label }}
        </span>
        <span
          class="min-w-6 px-1.5 py-0.5 text-xs text-center font-medium rounded-full bg-n-alpha-2 text-n-slate-11"
        >
          {{ column.count }}
        </span>
      </div>
      <div class="flex items-center justify-between gap-2">
        <span class="text-xs text-n-slate-11 truncate">
          {{ $t('CRM_PIPELINE.BOARD.TOTAL') }}
          <span class="font-semibold text-n-teal-11">
            {{ formatMoney(column.total_value) }}
          </span>
        </span>
        <div class="flex items-center gap-1 shrink-0">
          <span
            v-if="requirementsCount"
            v-tooltip.top="$t('CRM_PIPELINE.BOARD.REQUIRED_TOOLTIP')"
            class="flex items-center gap-1 px-1.5 py-0.5 text-[11px] rounded-md border border-n-blue-6 text-n-blue-11"
          >
            <span class="i-lucide-shield size-3" />
            {{
              $t('CRM_PIPELINE.BOARD.REQUIRED_COUNT', {
                count: requirementsCount,
              })
            }}
          </span>
          <span
            v-if="column.automations_count"
            v-tooltip.top="$t('CRM_PIPELINE.BOARD.AUTOMATIONS_TOOLTIP')"
            class="flex items-center gap-1 px-1.5 py-0.5 text-[11px] rounded-md border border-n-amber-6 text-n-amber-11"
          >
            <span class="i-lucide-zap size-3" />
            {{
              $t('CRM_PIPELINE.BOARD.AUTOMATIONS_COUNT', {
                count: column.automations_count,
              })
            }}
          </span>
          <span
            v-if="column.has_ai_followup"
            v-tooltip.top="$t('CRM_PIPELINE.BOARD.AI_TOOLTIP')"
            class="flex items-center gap-1 px-1.5 py-0.5 text-[11px] rounded-md border border-n-iris-6 text-n-iris-11"
          >
            <span class="i-lucide-sparkles size-3" />
            {{ $t('CRM_PIPELINE.BOARD.AI_BADGE') }}
          </span>
        </div>
      </div>
    </div>

    <div class="flex-1 min-h-0 overflow-y-auto px-2 py-2">
      <Draggable
        :list="column.cards"
        group="pipeline"
        item-key="id"
        :animation="150"
        ghost-class="opacity-40"
        class="flex flex-col gap-2 min-h-full pb-2"
        @change="onChange"
      >
        <template #item="{ element }">
          <PipelineCard
            :card="element"
            :ai-followup-delay="column.ai_followup_delay"
            :now="now"
            @open="emit('open', element)"
            @set-temperature="value => emit('setTemperature', element, value)"
            @ai-followup="emit('aiFollowup', element)"
          />
        </template>
        <template #footer>
          <p
            v-if="!column.cards.length"
            class="py-6 mb-0 text-xs text-center text-n-slate-10 border border-dashed border-n-weak rounded-xl"
          >
            {{ $t('CRM_PIPELINE.BOARD.EMPTY_COLUMN') }}
          </p>
        </template>
      </Draggable>
      <button
        v-if="column.has_more"
        type="button"
        class="w-full py-1.5 text-xs text-n-slate-11 rounded-lg hover:bg-n-alpha-2 disabled:opacity-60"
        :disabled="isLoadingMore"
        @click="emit('loadMore')"
      >
        {{
          isLoadingMore
            ? $t('CRM_PIPELINE.BOARD.LOADING_MORE')
            : $t('CRM_PIPELINE.BOARD.LOAD_MORE')
        }}
      </button>
    </div>

    <button
      type="button"
      class="flex items-center justify-center gap-1.5 py-2.5 text-xs text-n-slate-11 border-t border-n-weak rounded-b-xl hover:bg-n-alpha-1 hover:text-n-slate-12"
      @click="emit('newCard')"
    >
      <span class="i-lucide-plus size-3.5" />
      {{ $t('CRM_PIPELINE.BOARD.NEW_CARD_IN_STAGE') }}
    </button>
  </div>
</template>
