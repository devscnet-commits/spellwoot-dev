import { mount, flushPromises } from '@vue/test-utils';
import UpgradePaymentDialog from '../UpgradePaymentDialog.vue';
import AccountPlanAPI from 'dashboard/api/account/plan';
import { useAlert } from 'dashboard/composables';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => (params ? `${key}|${JSON.stringify(params)}` : key),
  }),
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));
vi.mock('dashboard/api/account/plan', () => ({
  default: { requestUpgrade: vi.fn() },
}));

const mountDialog = (props = {}) =>
  mount(UpgradePaymentDialog, {
    props: {
      upgradePlan: { slug: 'pro_plus', name: 'PRO PLUS' },
      priceLabel: 'R$ 499,00/mês',
      currentPlanName: 'PLUS',
      accountId: 7,
      accountName: 'Provedor X',
      whatsappNumber: '5549999990000',
      emailRequest: true,
      ...props,
    },
    global: {
      mocks: { $t: key => key },
      stubs: {
        Dialog: {
          name: 'Dialog',
          template: '<div><slot /></div>',
          props: [
            'title',
            'description',
            'confirmButtonLabel',
            'showConfirmButton',
            'isLoading',
          ],
          emits: ['confirm', 'close'],
          methods: { open() {}, close() {} },
        },
      },
    },
  });

const dialog = wrapper => wrapper.findComponent({ name: 'Dialog' });

describe('UpgradePaymentDialog.vue', () => {
  beforeEach(() => {
    vi.spyOn(window, 'open').mockImplementation(() => null);
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('não pede forma de pagamento (ainda não há provedor)', () => {
    const wrapper = mountDialog();

    expect(wrapper.find('input[type="radio"]').exists()).toBe(false);
  });

  it('com WhatsApp configurado: abre o WhatsApp da Conexiia com conta e planos — sem trocar o plano', () => {
    const wrapper = mountDialog();

    expect(dialog(wrapper).props('confirmButtonLabel')).toBe(
      'PLAN.UPGRADE.PAYMENT.CONTINUE_WHATSAPP'
    );
    dialog(wrapper).vm.$emit('confirm');

    const [url, target] = window.open.mock.calls[0];
    expect(target).toBe('_blank');
    expect(url.startsWith('https://wa.me/5549999990000?text=')).toBe(true);
    const text = decodeURIComponent(url.split('?text=')[1]);
    expect(text).toContain('"accountId":7');
    expect(text).toContain('"accountName":"Provedor X"');
    expect(text).toContain('"currentPlan":"PLUS"');
    expect(text).toContain('"targetPlan":"PRO PLUS"');
    expect(AccountPlanAPI.requestUpgrade).not.toHaveBeenCalled();
  });

  it('sem WhatsApp: "Solicitar upgrade" avisa a equipe por e-mail', async () => {
    AccountPlanAPI.requestUpgrade.mockResolvedValue({});
    const wrapper = mountDialog({ whatsappNumber: null });

    expect(dialog(wrapper).props('showConfirmButton')).toBe(true);
    expect(dialog(wrapper).props('confirmButtonLabel')).toBe(
      'PLAN.UPGRADE.PAYMENT.REQUEST'
    );
    dialog(wrapper).vm.$emit('confirm');
    await flushPromises();

    expect(AccountPlanAPI.requestUpgrade).toHaveBeenCalledWith('pro_plus');
    expect(useAlert).toHaveBeenCalledWith('PLAN.UPGRADE.PAYMENT.REQUEST_SENT');
    expect(window.open).not.toHaveBeenCalled();
  });

  it('falha ao enviar o pedido: avisa o erro', async () => {
    AccountPlanAPI.requestUpgrade.mockRejectedValue(new Error('boom'));
    const wrapper = mountDialog({ whatsappNumber: null });

    dialog(wrapper).vm.$emit('confirm');
    await flushPromises();

    expect(useAlert).toHaveBeenCalledWith('PLAN.UPGRADE.PAYMENT.REQUEST_ERROR');
  });

  it('sem nenhum contato configurado: sem botão e orienta falar com o suporte', () => {
    const wrapper = mountDialog({ whatsappNumber: null, emailRequest: false });

    expect(dialog(wrapper).props('showConfirmButton')).toBe(false);
    expect(wrapper.text()).toContain('PLAN.UPGRADE.PAYMENT.NO_CONTACT');
  });
});
