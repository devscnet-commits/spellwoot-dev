import { shallowMount } from '@vue/test-utils';
import { useAlert } from 'dashboard/composables';
import Email from '../Email.vue';

vi.mock('../emailChannels/Microsoft.vue', () => ({
  default: { template: '<div />' },
}));
vi.mock('../emailChannels/Google.vue', () => ({
  default: { template: '<div />' },
}));
vi.mock('../emailChannels/ForwardToOption.vue', () => ({
  default: { template: '<div />' },
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/composables/store', () => ({
  useStoreGetters: () => ({
    'globalConfig/get': { value: {} },
    'globalConfig/isAChatwootInstance': { value: false },
  }),
}));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

// Callback OAuth (Google/Microsoft) recusado pelo plano volta para esta tela com error_message.
describe('Email.vue — aviso do plano vindo do OAuth', () => {
  beforeEach(() => {
    window.chatwootConfig = {};
    useAlert.mockClear();
  });

  it('mostra o aviso e limpa a URL', () => {
    window.history.replaceState(
      {},
      '',
      '/app/accounts/2/settings/inboxes/new/email?error_message=Limite%20de%20caixas%20de%20entrada%20do%20seu%20plano%20atingido.'
    );

    shallowMount(Email, { global: { mocks: { $t: key => key } } });

    expect(useAlert).toHaveBeenCalledWith(
      'Limite de caixas de entrada do seu plano atingido.'
    );
    expect(window.location.search).toBe('');
  });

  it('sem error_message não mostra nada', () => {
    window.history.replaceState(
      {},
      '',
      '/app/accounts/2/settings/inboxes/new/email'
    );

    shallowMount(Email, { global: { mocks: { $t: key => key } } });

    expect(useAlert).not.toHaveBeenCalled();
  });
});
