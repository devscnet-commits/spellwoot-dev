import { ref, computed, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import PipelinesAPI from 'dashboard/api/pipelines';

// The pipelines of the account and the one selected on the CRM pages (kept in the `pipeline` query
// param so the board, the automations, the AI follow-ups and the reports open on the same one).
export function usePipelines() {
  const route = useRoute();
  const router = useRouter();
  const pipelines = ref([]);
  const isLoading = ref(false);
  const selectedId = ref(Number(route.query.pipeline) || null);

  const selected = computed(
    () => pipelines.value.find(p => p.id === selectedId.value) || null
  );

  const select = id => {
    selectedId.value = Number(id) || null;
    router.replace({ query: { ...route.query, pipeline: selectedId.value } });
  };

  const fetchPipelines = async () => {
    isLoading.value = true;
    try {
      const { data } = await PipelinesAPI.get();
      pipelines.value = data.payload || [];
      if (!selected.value && pipelines.value.length) {
        select(pipelines.value[0].id);
      }
    } finally {
      isLoading.value = false;
    }
  };

  watch(
    () => route.query.pipeline,
    value => {
      const id = Number(value) || null;
      if (id && id !== selectedId.value) selectedId.value = id;
    }
  );

  return { pipelines, selected, selectedId, isLoading, select, fetchPipelines };
}
