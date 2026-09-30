import { shallowMount, flushPromises } from '@vue/test-utils';
import InboxesAPI from 'dashboard/api/inboxes';
import NextButton from 'dashboard/components-next/button/Button.vue';
import InboxSecretCode from '../InboxSecretCode.vue';

vi.mock('dashboard/api/inboxes', () => ({ default: { getSecret: vi.fn() } }));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: key => key }) }));

const mountSecret = () =>
  shallowMount(InboxSecretCode, {
    props: { inboxId: 7, field: 'hmac_token', maskedValue: 'AbCd****xyz' },
    global: {
      stubs: {
        'woot-code': { props: ['script'], template: '<pre>{{ script }}</pre>' },
      },
    },
  });

// Segredo do canal: a tela recebe só o mascarado; o valor completo vem no clique, pelo endpoint de admin.
describe('InboxSecretCode', () => {
  it('mostra o valor mascarado até o clique', () => {
    const wrapper = mountSecret();

    expect(wrapper.text()).toContain('AbCd****xyz');
    expect(InboxesAPI.getSecret).not.toHaveBeenCalled();
  });

  it('busca e mostra o valor completo ao clicar em Mostrar', async () => {
    InboxesAPI.getSecret.mockResolvedValue({
      data: { value: 'segredo-completo' },
    });
    const wrapper = mountSecret();

    await wrapper.findComponent(NextButton).vm.$emit('click');
    await flushPromises();

    expect(InboxesAPI.getSecret).toHaveBeenCalledWith(7, 'hmac_token');
    expect(wrapper.text()).toContain('segredo-completo');
  });
});
