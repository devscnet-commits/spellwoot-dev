import { shallowMount } from '@vue/test-utils';
import Whatsapp from '../Whatsapp.vue';
import ChannelSelector from 'dashboard/components/ChannelSelector.vue';

let enabledFlags = [];

// Os formulários de cada provedor puxam o router do app; aqui só importa a lista de provedores.
vi.mock('../Twilio.vue', () => ({ default: { template: '<div />' } }));
vi.mock('../360DialogWhatsapp.vue', () => ({
  default: { template: '<div />' },
}));
vi.mock('../CloudWhatsapp.vue', () => ({ default: { template: '<div />' } }));
vi.mock('../WhatsappEmbeddedSignup.vue', () => ({
  default: { template: '<div />' },
}));
vi.mock('../UazapiWhatsapp.vue', () => ({ default: { template: '<div />' } }));

vi.mock('dashboard/composables/useAccount', () => ({
  useAccount: () => ({
    isCloudFeatureEnabled: flag => enabledFlags.includes(flag),
  }),
}));
vi.mock('vue-router', () => ({
  useRoute: () => ({
    name: 'settings_inboxes_page_channel',
    params: {},
    query: {},
  }),
  useRouter: () => ({ push: vi.fn() }),
}));
vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: key => key }),
  I18nT: { template: '<span />' },
}));

const providerTitles = () =>
  shallowMount(Whatsapp, { global: { mocks: { $t: key => key } } })
    .findAllComponents(ChannelSelector)
    .map(selector => selector.props('title'));

describe('Whatsapp.vue — escolha de provedor', () => {
  it('mostra o UazAPI quando o plano libera "Todas"', () => {
    enabledFlags = ['channel_whatsapp', 'channel_whatsapp_unofficial'];

    expect(providerTitles()).toContain(
      'INBOX_MGMT.ADD.WHATSAPP.PROVIDERS.UAZAPI'
    );
  });

  it('esconde o UazAPI e mantém os oficiais quando o plano é "Somente oficiais"', () => {
    enabledFlags = ['channel_whatsapp'];

    const titles = providerTitles();

    expect(titles).not.toContain('INBOX_MGMT.ADD.WHATSAPP.PROVIDERS.UAZAPI');
    expect(titles).toContain(
      'INBOX_MGMT.ADD.WHATSAPP.PROVIDERS.WHATSAPP_CLOUD'
    );
  });
});
