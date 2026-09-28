import { shallowMount, flushPromises } from '@vue/test-utils';
import IntegrationsHub from '../IntegrationsHub.vue';

let enabledFlags = [];
let routeQuery = {};

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({ accountId: { value: 1 } }),
}));
vi.mock('dashboard/composables/store', () => ({
  useMapGetter: () => ({
    value: (_accountId, flag) => enabledFlags.includes(flag),
  }),
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));
vi.mock('vue-router', () => ({ useRoute: () => ({ query: routeQuery }) }));
vi.mock('../../../../../api/integrationSettings', () => ({
  default: {
    get: vi
      .fn()
      .mockResolvedValue({ data: { config: {}, sources: {}, enabled: true } }),
  },
}));
vi.mock('../../../../../api/providerInstances', () => ({
  default: { list: vi.fn().mockResolvedValue({ data: [] }) },
}));

const mountHub = async () => {
  const wrapper = shallowMount(IntegrationsHub, {
    global: { mocks: { $t: key => key } },
  });
  await flushPromises();
  return wrapper;
};

const renderedText = async () => (await mountHub()).text();

describe('IntegrationsHub.vue — WhatsApp não oficial', () => {
  it('mostra UazAPI e Evolution quando o plano libera "Todas"', async () => {
    enabledFlags = ['channel_whatsapp', 'channel_whatsapp_unofficial'];

    const text = await renderedText();

    expect(text).toContain('UazAPI');
    expect(text).toContain('Evolution API');
  });

  it('esconde UazAPI e Evolution quando o plano é "Somente oficiais"', async () => {
    enabledFlags = ['channel_whatsapp'];

    const text = await renderedText();

    expect(text).not.toContain('UazAPI');
    expect(text).not.toContain('Evolution API');
    expect(text).toContain('Meta Conversions API');
  });
});

describe('IntegrationsHub.vue — link direto vindo do Meu Plano', () => {
  afterEach(() => {
    routeQuery = {};
  });

  it('abre o card do provider pedido em ?provider=', async () => {
    enabledFlags = [];
    routeQuery = { provider: 'openai' };

    const wrapper = await mountHub();

    expect(
      wrapper.find('#provider-openai .border-t.border-n-weak').exists()
    ).toBe(true);
    expect(
      wrapper.find('#provider-meta .border-t.border-n-weak').exists()
    ).toBe(false);
  });

  it('ignora provider que o plano não mostra', async () => {
    enabledFlags = [];
    routeQuery = { provider: 'uazapi' };

    const wrapper = await mountHub();

    expect(wrapper.find('#provider-uazapi').exists()).toBe(false);
  });
});
