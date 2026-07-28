import { shallowMount, flushPromises } from '@vue/test-utils';
import AiStepForm from '../AiStepForm.vue';

// O componente usa useRoute (accountId p/ o endpoint de inferência) e o axios GLOBAL (window.axios).
vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { accountId: '7' } }),
}));

const mountForm = step => {
  // Instruções vazias -> inferRaw sai cedo (sem POST); o axios stub é só rede de segurança.
  vi.stubGlobal('axios', {
    post: vi.fn().mockResolvedValue({ data: { attribute: '' } }),
  });
  return shallowMount(AiStepForm, {
    props: {
      step,
      isNew: false,
      index: 0,
      labels: [],
      teams: [],
      customAttributes: [],
      departments: [],
    },
  });
};

describe('AiStepForm.vue — preservação de step.knowledge (semeadura do draft, PR 2)', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.clearAllMocks();
  });

  // Bug do #306 aplicado a knowledge: como buildStepPayload passou a EMITIR knowledge, se o draft NÃO for
  // semeado de props.step.knowledge, editar a etapa clobba o backfill. Este teste trava a semeadura.
  it('carregar etapa com knowledge e salvar SEM tocar no campo emite o MESMO knowledge (não clobba o backfill)', async () => {
    const step = {
      name: 'Viabilidade',
      knowledge: { query: 'cidades atendidas', kinds: ['documento'] },
    };
    const wrapper = mountForm(step);

    await wrapper.get('button.bg-n-brand').trigger('click'); // o botão salvar
    await flushPromises();

    const saved = wrapper.emitted('save');
    expect(saved).toBeTruthy();
    expect(saved[0][0].knowledge).toEqual({
      query: 'cidades atendidas',
      kinds: ['documento'],
    });

    wrapper.unmount();
  });

  it('etapa SEM knowledge: o payload não ganha a chave knowledge', async () => {
    const wrapper = mountForm({ name: 'Coleta' });

    await wrapper.get('button.bg-n-brand').trigger('click');
    await flushPromises();

    expect('knowledge' in wrapper.emitted('save')[0][0]).toBe(false);

    wrapper.unmount();
  });
});
