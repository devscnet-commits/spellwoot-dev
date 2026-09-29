import { mount } from '@vue/test-utils';
import UpgradePaymentDialog from '../UpgradePaymentDialog.vue';

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key, params) => (params ? `${key}|${JSON.stringify(params)}` : key),
  }),
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
          ],
          emits: ['confirm', 'close'],
          methods: { open() {}, close() {} },
        },
      },
    },
  });

describe('UpgradePaymentDialog.vue', () => {
  beforeEach(() => {
    vi.spyOn(window, 'open').mockImplementation(() => null);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('continuar abre o WhatsApp da Conexiia com conta, planos e forma de pagamento — sem trocar o plano', async () => {
    const wrapper = mountDialog();
    await wrapper.find('input[value="card"]').setValue(true);

    wrapper.findComponent({ name: 'Dialog' }).vm.$emit('confirm');

    expect(window.open).toHaveBeenCalledTimes(1);
    const [url, target] = window.open.mock.calls[0];
    expect(target).toBe('_blank');
    expect(url.startsWith('https://wa.me/5549999990000?text=')).toBe(true);
    const text = decodeURIComponent(url.split('?text=')[1]);
    expect(text).toContain('PLAN.UPGRADE.WHATSAPP_MESSAGE');
    expect(text).toContain('"accountId":7');
    expect(text).toContain('"accountName":"Provedor X"');
    expect(text).toContain('"currentPlan":"PLUS"');
    expect(text).toContain('"targetPlan":"PRO PLUS"');
    expect(text).toContain('"paymentMethod":"PLAN.UPGRADE.PAYMENT.CARD"');
  });

  it('sem número configurado: não oferece o botão e orienta falar com o suporte', () => {
    const wrapper = mountDialog({ whatsappNumber: null });

    expect(
      wrapper.findComponent({ name: 'Dialog' }).props('showConfirmButton')
    ).toBe(false);
    expect(wrapper.text()).toContain('PLAN.UPGRADE.PAYMENT.NO_CONTACT');

    wrapper.findComponent({ name: 'Dialog' }).vm.$emit('confirm');
    expect(window.open).not.toHaveBeenCalled();
  });
});
