import { shallowMount, flushPromises } from '@vue/test-utils';
import IntegrationsHub from '../IntegrationsHub.vue';

let enabledFlags = [];

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

const renderedText = async () => {
  const wrapper = shallowMount(IntegrationsHub, {
    global: { mocks: { $t: key => key } },
  });
  await flushPromises();
  return wrapper.text();
};

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
