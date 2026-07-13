import { shallowMount, flushPromises } from '@vue/test-utils';
import AiHandoffSummary from '../AiHandoffSummary.vue';

vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { accountId: '1' } }),
}));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: k => k }) }));

const url = cid => `/api/v1/accounts/1/conversations/${cid}/ai_handoff_summary`;

const mountWith = (axiosStub, props = { conversationId: 7 }) => {
  // O componente usa o axios GLOBAL do Chatwoot (window.axios), não um import cru.
  vi.stubGlobal('axios', axiosStub);
  return shallowMount(AiHandoffSummary, { props });
};

describe('AiHandoffSummary.vue', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.clearAllMocks();
  });

  it('busca o resumo na URL escopada por CONVERSA (não por contato)', async () => {
    const get = vi.fn().mockResolvedValue({ data: { summary: null } });
    mountWith({ get });
    await flushPromises();

    expect(get).toHaveBeenCalledWith(url(7));
  });

  it('renderiza o resumo e o rótulo do motivo quando há dado', async () => {
    const wrapper = mountWith({
      get: vi.fn().mockResolvedValue({
        data: {
          summary: 'Cliente quer cancelar o plano',
          reason: 'credit_exhausted',
          created_at: '2026-07-13T10:00:00Z',
        },
      }),
    });
    await flushPromises();

    expect(wrapper.text()).toContain('Cliente quer cancelar o plano');
    expect(wrapper.text()).toContain(
      'CONVERSATION_SIDEBAR.HANDOFF_SUMMARY.REASONS.CREDIT_EXHAUSTED'
    );
  });

  it('mostra o estado vazio quando não há resumo', async () => {
    const wrapper = mountWith({
      get: vi.fn().mockResolvedValue({ data: { summary: null } }),
    });
    await flushPromises();

    expect(wrapper.text()).toContain(
      'CONVERSATION_SIDEBAR.HANDOFF_SUMMARY.EMPTY'
    );
  });

  it('recarrega quando o conversationId muda', async () => {
    const get = vi.fn().mockResolvedValue({ data: { summary: null } });
    const wrapper = mountWith({ get });
    await flushPromises();

    await wrapper.setProps({ conversationId: 99 });
    await flushPromises();

    expect(get).toHaveBeenCalledWith(url(99));
  });
});
