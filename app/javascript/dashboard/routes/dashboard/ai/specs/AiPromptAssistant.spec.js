import { shallowMount, flushPromises } from '@vue/test-utils';
import { nextTick } from 'vue';
import AiPromptAssistant from '../AiPromptAssistant.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';

vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { accountId: '7' } }),
}));
vi.mock('dashboard/composables', () => ({ useAlert: vi.fn() }));

const mountPanel = (axiosStub, extraProps = {}) => {
  // Usa o axios GLOBAL (window.axios), não um import cru — mesma regressão do bug do AiVersionHistory.
  vi.stubGlobal('axios', axiosStub);
  return shallowMount(AiPromptAssistant, {
    props: { open: true, kind: 'base_prompt', ...extraProps },
    global: {
      stubs: {
        TeleportWithDirection: { template: '<div><slot /></div>' },
        Transition: { template: '<div><slot /></div>' },
      },
    },
  });
};

describe('AiPromptAssistant.vue', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.clearAllMocks();
  });

  it('renderiza o painel quando open=true', () => {
    const wrapper = mountPanel({ post: vi.fn() });

    expect(wrapper.find('aside').exists()).toBe(true);
  });

  it('gera via window.axios na rota do assistente e mostra loading enquanto pende', async () => {
    let resolveRequest;
    const post = vi.fn(
      () =>
        new Promise(resolve => {
          resolveRequest = resolve;
        })
    );
    const wrapper = mountPanel({ post });

    wrapper
      .findComponent(TextArea)
      .vm.$emit('update:modelValue', 'agente comercial');
    await nextTick();
    wrapper.findComponent(Button).vm.$emit('click');
    await nextTick();

    expect(post).toHaveBeenCalledWith(
      '/api/v1/accounts/7/ai_prompt_assistant',
      {
        kind: 'base_prompt',
        brief: 'agente comercial',
      }
    );
    // Botão em loading durante a request (mata duplo-clique).
    expect(wrapper.findComponent(Button).props('isLoading')).toBe(true);

    resolveRequest({ data: { suggestion: 'texto gerado' } });
    await flushPromises();

    expect(wrapper.text()).toContain('texto gerado');
    expect(wrapper.findComponent(Button).props('isLoading')).toBe(false);
  });

  // PR4 — quando a tela sabe o department (etapas/Comportamento), envia department_id para o backend
  // ancorar as capacidades reais (não sugerir consulta sem fonte nem variável inventada).
  it('envia department_id no corpo quando a prop está preenchida', async () => {
    const post = vi.fn(() =>
      Promise.resolve({
        data: { objective: 'x', rules: ['y'] },
      })
    );
    const wrapper = mountPanel(
      { post },
      { kind: 'step_instructions', departmentId: 42 }
    );

    wrapper
      .findComponent(TextArea)
      .vm.$emit('update:modelValue', 'consulta de fatura');
    await nextTick();
    wrapper.findComponent(Button).vm.$emit('click');
    await flushPromises();

    expect(post).toHaveBeenCalledWith(
      '/api/v1/accounts/7/ai_prompt_assistant',
      {
        kind: 'step_instructions',
        brief: 'consulta de fatura',
        department_id: 42,
      }
    );
  });

  // "Padrão ouro" (2026-08): step_instructions NÃO devolve mais {"suggestion"} — devolve campos
  // SEPARADOS (objective/rules), espelhando os 2 campos de AiStepForm.vue. suggested_script ("Fala
  // sugerida") foi removido de novo (2026-08): mesmo como exemplo, o modelo tratava o texto entre
  // aspas como script literal.
  describe('kind=step_instructions — contrato de campos separados', () => {
    it('mostra o preview estruturado (objective/rules) em vez do <pre> de texto único', async () => {
      const post = vi.fn(() =>
        Promise.resolve({
          data: {
            objective: 'Obter a cidade',
            rules: ['Regra 1', 'Regra 2'],
          },
        })
      );
      const wrapper = mountPanel({ post }, { kind: 'step_instructions' });

      wrapper.findComponent(TextArea).vm.$emit('update:modelValue', 'x');
      await nextTick();
      wrapper.findComponent(Button).vm.$emit('click');
      await flushPromises();

      expect(wrapper.text()).toContain('Obter a cidade');
      expect(wrapper.text()).toContain('Regra 1');
      expect(wrapper.text()).toContain('Regra 2');
      expect(wrapper.find('pre').exists()).toBe(false); // não é mais 1 texto único copiável
    });

    // O botão "Usar esta sugestão" emite 'apply' com os campos — AiStepForm aplica direto no draft.
    it('clicar em "Usar esta sugestão" emite apply com objective/rules e fecha o painel', async () => {
      const post = vi.fn(() =>
        Promise.resolve({
          data: {
            objective: 'Obter a cidade',
            rules: ['Regra 1'],
          },
        })
      );
      const wrapper = mountPanel({ post }, { kind: 'step_instructions' });

      wrapper.findComponent(TextArea).vm.$emit('update:modelValue', 'x');
      await nextTick();
      wrapper.findComponent(Button).vm.$emit('click');
      await flushPromises();

      // 2 Button no painel agora: Gerar sugestão + Usar esta sugestão. O segundo é o Apply.
      const applyButton = wrapper.findAllComponents(Button).at(-1);
      await applyButton.vm.$emit('click');

      expect(wrapper.emitted('apply')[0][0]).toEqual({
        objective: 'Obter a cidade',
        rules: ['Regra 1'],
      });
      expect(wrapper.emitted('update:open')[0]).toEqual([false]);
    });

    it('resposta sem NENHUM dos 3 campos preenchidos mostra erro (não quebra)', async () => {
      const useAlertModule = await import('dashboard/composables');
      const post = vi.fn(() =>
        Promise.resolve({
          data: {
            objective: '',
            rules: [],
            admin_warnings: [],
          },
        })
      );
      const wrapper = mountPanel({ post }, { kind: 'step_instructions' });

      wrapper.findComponent(TextArea).vm.$emit('update:modelValue', 'x');
      await nextTick();
      wrapper.findComponent(Button).vm.$emit('click');
      await flushPromises();

      expect(useAlertModule.useAlert).toHaveBeenCalled();
      wrapper.unmount();
    });
  });

  // Bug real ao vivo: a IA leu "AVISO: CRIE A VARIÁVEL..." dentro da instrução como se fosse
  // comportamento. admin_warnings existe pra isso nunca mais acontecer — mostrado num bloco À PARTE,
  // NUNCA incluído no payload do apply() (que só carrega objective/rules).
  describe('kind=step_instructions — admin_warnings (aviso pro admin, nunca pra IA)', () => {
    it('mostra admin_warnings num bloco separado do preview dos campos de máquina', async () => {
      const post = vi.fn(() =>
        Promise.resolve({
          data: {
            objective: 'Obter o setor',
            rules: [
              'Assim que o cliente informar o setor, chame registrar_setor_cliente.',
            ],
            admin_warnings: [
              'Crie a variável setor_cliente antes de publicar esta etapa.',
            ],
          },
        })
      );
      const wrapper = mountPanel({ post }, { kind: 'step_instructions' });

      wrapper.findComponent(TextArea).vm.$emit('update:modelValue', 'x');
      await nextTick();
      wrapper.findComponent(Button).vm.$emit('click');
      await flushPromises();

      const warningsBlock = wrapper.find('[data-testid="admin-warnings"]');
      expect(warningsBlock.exists()).toBe(true);
      expect(warningsBlock.text()).toContain(
        'Crie a variável setor_cliente antes de publicar esta etapa.'
      );
    });

    it('apply() NUNCA inclui admin_warnings — só objective/rules vão pro form', async () => {
      const post = vi.fn(() =>
        Promise.resolve({
          data: {
            objective: 'Obter o setor',
            rules: ['Regra 1'],
            admin_warnings: [
              'Crie a variável setor_cliente antes de publicar esta etapa.',
            ],
          },
        })
      );
      const wrapper = mountPanel({ post }, { kind: 'step_instructions' });

      wrapper.findComponent(TextArea).vm.$emit('update:modelValue', 'x');
      await nextTick();
      wrapper.findComponent(Button).vm.$emit('click');
      await flushPromises();

      const applyButton = wrapper.findAllComponents(Button).at(-1);
      await applyButton.vm.$emit('click');

      const applied = wrapper.emitted('apply')[0][0];
      expect(applied).toEqual({
        objective: 'Obter o setor',
        rules: ['Regra 1'],
      });
      expect('adminWarnings' in applied).toBe(false);
      expect('admin_warnings' in applied).toBe(false);
    });

    // Se SÓ vier admin_warnings (nada de objective/rules), ainda mostra o aviso —
    // não trata como resposta vazia/erro.
    it('resposta só com admin_warnings (sem conteúdo de máquina) ainda mostra o aviso, sem erro', async () => {
      const useAlertModule = await import('dashboard/composables');
      const post = vi.fn(() =>
        Promise.resolve({
          data: {
            objective: '',
            rules: [],
            admin_warnings: [
              'Você pediu consulta a faturas, mas não há ferramenta cadastrada.',
            ],
          },
        })
      );
      const wrapper = mountPanel({ post }, { kind: 'step_instructions' });

      wrapper.findComponent(TextArea).vm.$emit('update:modelValue', 'x');
      await nextTick();
      wrapper.findComponent(Button).vm.$emit('click');
      await flushPromises();

      expect(useAlertModule.useAlert).not.toHaveBeenCalled();
      expect(wrapper.find('[data-testid="admin-warnings"]').exists()).toBe(
        true
      );
    });

    it('sem admin_warnings: o bloco não aparece', async () => {
      const post = vi.fn(() =>
        Promise.resolve({
          data: {
            objective: 'x',
            rules: ['y'],
            admin_warnings: [],
          },
        })
      );
      const wrapper = mountPanel({ post }, { kind: 'step_instructions' });

      wrapper.findComponent(TextArea).vm.$emit('update:modelValue', 'x');
      await nextTick();
      wrapper.findComponent(Button).vm.$emit('click');
      await flushPromises();

      expect(wrapper.find('[data-testid="admin-warnings"]').exists()).toBe(
        false
      );
    });
  });
});
