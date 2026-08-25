import { shallowMount, flushPromises } from '@vue/test-utils';
import CreditRequestButton from '../CreditRequestButton.vue';
import Button from 'dashboard/components-next/button/Button.vue';

vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { accountId: '1' } }),
}));
vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => (params ? `${key}:${params.amount}` : key),
  }),
}));

const BASE_URL = '/api/v1/accounts/1/credit_requests';

const mountWith = axiosStub => {
  vi.stubGlobal('axios', axiosStub);
  return shallowMount(CreditRequestButton, {
    global: {
      mocks: {
        $t: (key, params) => (params ? `${key}:${params.amount}` : key),
      },
    },
  });
};

describe('CreditRequestButton.vue', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.clearAllMocks();
  });

  it('busca as solicitações pelo axios global na URL da conta ao montar', async () => {
    const get = vi.fn().mockResolvedValue({ data: [] });
    mountWith({ get });
    await flushPromises();

    expect(get).toHaveBeenCalledWith(BASE_URL);
  });

  it('mostra o botão quando NÃO há solicitação pendente', async () => {
    const wrapper = mountWith({ get: vi.fn().mockResolvedValue({ data: [] }) });
    await flushPromises();

    // O label vai como prop do componente Button (stub), não como texto.
    expect(wrapper.findComponent(Button).props('label')).toBe(
      'PLAN.CREDIT_REQUEST.BUTTON'
    );
    expect(wrapper.text()).not.toContain('PLAN.CREDIT_REQUEST.PENDING');
  });

  it('mostra o status pendente e ESCONDE o botão quando já há uma solicitação pending', async () => {
    const wrapper = mountWith({
      get: vi.fn().mockResolvedValue({
        data: [{ id: 1, status: 'pending', amount_requested: 500 }],
      }),
    });
    await flushPromises();

    expect(wrapper.text()).toContain('PLAN.CREDIT_REQUEST.PENDING');
    expect(wrapper.findComponent(Button).exists()).toBe(false);
  });

  it('faz POST com amount + reason ao submeter o formulário', async () => {
    const post = vi
      .fn()
      .mockResolvedValue({ data: { id: 9, status: 'pending' } });
    const get = vi.fn().mockResolvedValue({ data: [] });
    const wrapper = mountWith({ get, post });
    await flushPromises();

    // abre o formulário (Button "Solicitar mais créditos")
    await wrapper.findComponent(Button).trigger('click');
    await wrapper.find('input[type="number"]').setValue(1000);
    await wrapper.find('textarea').setValue('preciso');
    // submete (primeiro Button do form = "Enviar")
    await wrapper.findAllComponents(Button)[0].trigger('click');
    await flushPromises();

    expect(post).toHaveBeenCalledWith(BASE_URL, {
      credit_request: { amount_requested: 1000, reason: 'preciso' },
    });
  });
});
