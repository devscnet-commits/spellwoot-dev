import { shallowMount, flushPromises } from '@vue/test-utils';
import { nextTick } from 'vue';
import AiPromptAssistant from '../AiPromptAssistant.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';

vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { accountId: '7' } }),
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));

const mountPanel = (axiosStub, extraProps = {}) => {
  // Usa o axios GLOBAL (window.axios), não um import cru — mesma regressão do bug do AiVersionHistory.
  vi.stubGlobal('axios', axiosStub);
  return shallowMount(AiPromptAssistant, {
    props: { open: true, kind: 'base_prompt', ...extraProps },
    global: {
      stubs: {
        TeleportWithDirection: { template: '<div><slot /></div>' },
        Transition: { template: '<div><slot /></div>' },
      },
    },
  });
};

describe('AiPromptAssistant.vue', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.clearAllMocks();
  });

  it('renderiza o painel quando open=true', () => {
    const wrapper = mountPanel({ post: vi.fn() });

    expect(wrapper.find('aside').exists()).toBe(true);
  });

  it('gera via window.axios na rota do assistente e mostra loading enquanto pende', async () => {
    let resolveRequest;
    const post = vi.fn(
      () =>
        new Promise(resolve => {
          resolveRequest = resolve;
        })
    );
    const wrapper = mountPanel({ post });

    wrapper
      .findComponent(TextArea)
      .vm.$emit('update:modelValue', 'agente comercial');
    await nextTick();
    wrapper.findComponent(Button).vm.$emit('click');
    await nextTick();

    expect(post).toHaveBeenCalledWith(
      '/api/v1/accounts/7/ai_prompt_assistant',
      {
        kind: 'base_prompt',
        brief: 'agente comercial',
      }
    );
    // Botão em loading durante a request (mata duplo-clique).
    expect(wrapper.findComponent(Button).props('isLoading')).toBe(true);

    resolveRequest({ data: { suggestion: 'texto gerado' } });
    await flushPromises();

    expect(wrapper.text()).toContain('texto gerado');
    expect(wrapper.findComponent(Button).props('isLoading')).toBe(false);
  });

  // PR4 — quando a tela sabe o department (etapas/Comportamento), envia department_id para o backend
  // ancorar as capacidades reais (não sugerir consulta sem fonte nem variável inventada).
  it('envia department_id no corpo quando a prop está preenchida', async () => {
    const post = vi.fn(() => Promise.resolve({ data: { suggestion: 'ok' } }));
    const wrapper = mountPanel(
      { post },
      { kind: 'step_instructions', departmentId: 42 }
    );

    wrapper
      .findComponent(TextArea)
      .vm.$emit('update:modelValue', 'consulta de fatura');
    await nextTick();
    wrapper.findComponent(Button).vm.$emit('click');
    await flushPromises();

    expect(post).toHaveBeenCalledWith(
      '/api/v1/accounts/7/ai_prompt_assistant',
      {
        kind: 'step_instructions',
        brief: 'consulta de fatura',
        department_id: 42,
      }
    );
  });
});
