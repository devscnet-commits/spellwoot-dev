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

describe('AiStepForm.vue — preservação de step.on_complete (semeadura do draft, (b)-core)', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.clearAllMocks();
  });

  // A MESMA armadilha do #306/knowledge aplicada ao on_complete: buildStepPayload agora EMITE on_complete,
  // então sem semear o draft de props.step.on_complete, editar a etapa apagaria o backfill. Trava a semeadura.
  it('carregar etapa com on_complete e salvar SEM tocar emite o MESMO on_complete (não clobba o backfill)', async () => {
    const step = {
      name: 'Finalização',
      on_complete: { action: 'handoff_human', team_id: 7 },
    };
    const wrapper = mountForm(step);

    await wrapper.get('button.bg-n-brand').trigger('click');
    await flushPromises();

    expect(wrapper.emitted('save')[0][0].on_complete).toEqual({
      action: 'handoff_human',
      team_id: 7,
    });

    wrapper.unmount();
  });

  it('etapa SEM on_complete: o payload emite on_complete: null (não declara desfecho, e limpa)', async () => {
    const wrapper = mountForm({ name: 'Coleta' });

    await wrapper.get('button.bg-n-brand').trigger('click');
    await flushPromises();

    expect(wrapper.emitted('save')[0][0].on_complete).toBe(null);

    wrapper.unmount();
  });
});

describe('AiStepForm.vue — foco do input de chave manual (input único, sempre montado)', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.clearAllMocks();
  });

  // Regressão: antes havia DOIS <input v-model="draft.collectAttribute"> em ramos v-if mutuamente exclusivos
  // (âmbar "sem slot" vs verde "editando"); como hasSlot deriva de collectAttribute, a 1ª letra flipava o
  // ramo e o Vue REMONTAVA o input, matando o foco (o usuário digitava "c" e tinha que clicar de novo).
  // Agora é UM input sempre montado. Este teste digita caractere a caractere e exige que o MESMO input
  // continue presente e acumule o valor completo. FALHA se o input voltar a ser condicional: no bug antigo,
  // após a 1ª letra hasSlot vira true, o ramo verde mostra a LEITURA (span) e o input some -> a 2ª iteração
  // não encontra mais o input.
  it('digitar caractere a caractere mantém UM input montado e o valor completo', async () => {
    const wrapper = mountForm({ name: 'Coleta' }); // sem collect, sem instrução -> estado "sem slot"
    await flushPromises();

    const keyInput = () => wrapper.find('[data-testid="slot-key-input"]');
    expect(keyInput().exists()).toBe(true); // input presente já no estado "sem slot"

    // Digita caractere a caractere (reduce em vez de for-of/await-in-loop — regras do lint do repo). A 1ª
    // letra flipa hasSlot; o input NÃO pode remontar: reasserta a presença antes de cada tecla.
    await ['c', 'ci', 'cid', 'cida', 'cidad', 'cidade'].reduce(
      async (chain, value) => {
        await chain;
        expect(keyInput().exists()).toBe(true); // NUNCA some ao digitar
        await keyInput().setValue(value);
        await flushPromises();
      },
      Promise.resolve()
    );

    expect(keyInput().exists()).toBe(true);
    expect(keyInput().element.value).toBe('cidade'); // valor completo preservado

    await wrapper.get('button.bg-n-brand').trigger('click');
    await flushPromises();
    expect(wrapper.emitted('save')[0][0].collect).toEqual({
      attribute: 'cidade',
      type: 'text',
    });

    wrapper.unmount();
  });
});
