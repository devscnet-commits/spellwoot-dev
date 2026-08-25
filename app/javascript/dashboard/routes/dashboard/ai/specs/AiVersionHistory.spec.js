import { shallowMount, flushPromises } from '@vue/test-utils';
import AiVersionHistory from '../AiVersionHistory.vue';

// O componente dispara toast de erro via useAlert — mockamos para inspecionar.
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));

const BASE_URL = '/api/v1/accounts/1/ai_agents/1/ai_agent_versions';
const versions = [
  { id: 2, version_number: 2, note: null, created_at: '2026-07-10T10:00:00Z' },
  {
    id: 1,
    version_number: 1,
    note: 'Restaurado da v1',
    created_at: '2026-07-09T10:00:00Z',
  },
];

const mountWith = axiosStub => {
  // O componente usa o axios GLOBAL do Chatwoot (window.axios), não um import cru.
  vi.stubGlobal('axios', axiosStub);
  return shallowMount(AiVersionHistory, { props: { baseUrl: BASE_URL } });
};

describe('AiVersionHistory.vue', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.clearAllMocks();
  });

  it('busca as versões pelo axios GLOBAL, na baseUrl recebida (regressão do import cru)', async () => {
    const get = vi.fn().mockResolvedValue({ data: versions });
    mountWith({ get });
    await flushPromises();

    expect(get).toHaveBeenCalledWith(BASE_URL);
  });

  it('renderiza a contagem e as linhas de versão quando a API responde', async () => {
    const wrapper = mountWith({
      get: vi.fn().mockResolvedValue({ data: versions }),
    });
    await flushPromises();

    expect(wrapper.text()).toContain('(2)');
    await wrapper.find('button').trigger('click'); // expande a lista
    expect(wrapper.text()).toContain('v2');
    expect(wrapper.text()).toContain('v1');
  });

  it('mostra toast de erro e loga (não engole o erro em silêncio) quando a API falha', async () => {
    const { useAlert } = await import('dashboard/composables');
    const consoleError = vi
      .spyOn(console, 'error')
      .mockImplementation(() => {});

    mountWith({
      get: vi.fn().mockRejectedValue({ response: { status: 401 } }),
    });
    await flushPromises();

    expect(consoleError).toHaveBeenCalled();
    expect(useAlert).toHaveBeenCalled();

    consoleError.mockRestore();
  });
});
