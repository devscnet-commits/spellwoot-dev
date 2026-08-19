import { shallowMount, flushPromises } from '@vue/test-utils';
import AiStepForm from '../AiStepForm.vue';
import AiPromptAssistant from '../AiPromptAssistant.vue';

// O componente usa useRoute (accountId p/ o POST do inline-create) e o axios GLOBAL (window.axios).
vi.mock('vue-router', () => ({
  useRoute: () => ({ params: { accountId: '7' } }),
}));

// axios.post só é chamado no inline-create de LeadVariable; devolve a variável criada.
const stubAxios = createdName =>
  vi.stubGlobal('axios', {
    post: vi.fn().mockResolvedValue({ data: { id: 99, name: createdName } }),
  });

const mountForm = (step, extraProps = {}) => {
  stubAxios('cidade');
  return shallowMount(AiStepForm, {
    props: {
      step,
      isNew: false,
      index: 0,
      labels: [],
      teams: [],
      customAttributes: [],
      leadVariables: [],
      agentId: '3',
      ...extraProps,
    },
  });
};

// "Padrão ouro" (2026-08): instructions (1 textarea) virou objective/rules (2 campos). suggested_script
// ("Fala sugerida") foi removido de novo (2026-08): mesmo como exemplo, o modelo tratava o texto entre
// aspas como script literal — tom consistente agora vai no "Prompt base" do agente, não por etapa.
describe('AiStepForm.vue — Objetivo/Regras (2 campos estruturados)', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.clearAllMocks();
  });

  it('etapa NOVA: carrega objective/rules nos 2 campos e emite no save', async () => {
    const wrapper = mountForm({
      name: 'Qualificação',
      objective: 'Obter a cidade',
      rules: ['Regra 1', 'Regra 2'],
    });

    expect(wrapper.get('[data-testid="step-objective"]').element.value).toBe(
      'Obter a cidade'
    );
    expect(wrapper.get('[data-testid="step-rules"]').element.value).toBe(
      'Regra 1\nRegra 2'
    );

    await wrapper.get('button.bg-n-brand').trigger('click');
    await flushPromises();

    const saved = wrapper.emitted('save')[0][0];
    expect(saved.objective).toBe('Obter a cidade');
    expect(saved.rules).toEqual(['Regra 1', 'Regra 2']);
    expect('instructions' in saved).toBe(false);

    wrapper.unmount();
  });

  // Migração: etapa ANTIGA (só instructions) carrega o texto legado no campo Objetivo — nada se perde.
  it('etapa ANTIGA (só instructions): migra o texto legado pro campo Objetivo', async () => {
    const wrapper = mountForm({
      name: 'Cadastro',
      instructions: 'Peça e grave o CPF do cliente.',
    });

    expect(wrapper.get('[data-testid="step-objective"]').element.value).toBe(
      'Peça e grave o CPF do cliente.'
    );

    wrapper.unmount();
  });

  // AiPromptAssistant emite 'apply' com { objective, rules } — o form aplica direto
  // nos 2 campos (o admin ainda revisa e clica Salvar).
  it('aplica a sugestão do assistente (evento apply) nos 2 campos', async () => {
    const wrapper = mountForm({ name: 'Coleta' });

    await wrapper.findComponent(AiPromptAssistant).vm.$emit('apply', {
      objective: 'Objetivo sugerido',
      rules: ['Regra sugerida 1', 'Regra sugerida 2'],
    });
    await flushPromises();

    expect(wrapper.get('[data-testid="step-objective"]').element.value).toBe(
      'Objetivo sugerido'
    );
    expect(wrapper.get('[data-testid="step-rules"]').element.value).toBe(
      'Regra sugerida 1\nRegra sugerida 2'
    );

    wrapper.unmount();
  });
});

// RAG virou tool agentic (consultar_conhecimento, sempre disponível — Ai::PythonOrchestratorClient),
// sem pré-configuração por etapa: os campos "Consultar no conhecimento antes de responder"/"Filtrar
// por tipo" e o estado draft.knowledgeQuery/knowledgeKinds saíram da tela. buildStepPayload nunca mais
// emite a chave `knowledge`, mesmo quando a etapa carregada do backend ainda tem o campo legado.
describe('AiStepForm.vue — knowledge removido da tela (RAG agora é tool agentic)', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.clearAllMocks();
  });

  it('etapa com knowledge legado no backend: salvar NÃO reemite a chave knowledge (não há mais campo pra editar)', async () => {
    const step = {
      name: 'Viabilidade',
      knowledge: { query: 'cidades atendidas', kinds: ['documento'] },
    };
    const wrapper = mountForm(step);

    await wrapper.get('button.bg-n-brand').trigger('click'); // o botão salvar
    await flushPromises();

    const saved = wrapper.emitted('save');
    expect(saved).toBeTruthy();
    expect('knowledge' in saved[0][0]).toBe(false);

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

    // reason: 'conclusao' é a constante do contrato preenchida por buildStepPayload em handoff_human — o
    // seeding continua preservando action/team_id (não clobba o backfill) e ainda cura o reason ausente.
    expect(wrapper.emitted('save')[0][0].on_complete).toEqual({
      action: 'handoff_human',
      reason: 'conclusao',
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

describe('AiStepForm.vue — Select da chave (união LeadVariable ∪ CustomAttributeDefinition, origem marcada)', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.clearAllMocks();
  });

  // findComponent: o <Select> é um stub (shallowMount) — precisamos do wrapper de COMPONENTE (props/$emit),
  // não do DOMWrapper que find() devolve.
  const keySelect = wrapper =>
    wrapper.findComponent('[data-testid="slot-key-select"]');

  it('popula o Select da UNIÃO com a origem marcada (interna vs painel) + opção vazia', () => {
    const wrapper = mountForm(
      { name: 'Coleta' },
      {
        leadVariables: [{ name: 'periodo_reservado' }],
        customAttributes: [
          {
            attribute_model: 'conversation_attribute',
            attribute_key: 'cidade',
          },
          { attribute_model: 'contact_attribute', attribute_key: 'ignorado' },
        ],
      }
    );

    const options = keySelect(wrapper).props('options');
    // opção vazia (etapa informativa) primeiro
    expect(options[0].value).toBe('');
    const byValue = Object.fromEntries(options.map(o => [o.value, o.label]));
    // LeadVariable => interna; CAD conversation_attribute => painel; contact_attribute NÃO entra
    expect(byValue.periodo_reservado).toContain('interna');
    expect(byValue.cidade).toContain('painel');
    expect('ignorado' in byValue).toBe(false);

    wrapper.unmount();
  });

  it('opção vazia salva collect: null (etapa informativa é escolha explícita)', async () => {
    // etapa com collect declarado -> seleciona a opção vazia -> collect null no save
    const wrapper = mountForm({
      name: 'Coleta',
      collect: { attribute: 'cidade' },
    });
    await keySelect(wrapper).vm.$emit('update:modelValue', '');
    await flushPromises();

    await wrapper.get('button.bg-n-brand').trigger('click');
    await flushPromises();
    expect(wrapper.emitted('save')[0][0].collect).toBe(null);

    wrapper.unmount();
  });

  it('chave declarada salva collect com a chave e o tipo', async () => {
    const wrapper = mountForm({
      name: 'Coleta',
      collect: { attribute: 'cidade', type: 'text' },
    });

    await wrapper.get('button.bg-n-brand').trigger('click');
    await flushPromises();
    expect(wrapper.emitted('save')[0][0].collect).toEqual({
      attribute: 'cidade',
      type: 'text',
    });

    wrapper.unmount();
  });
});

describe('AiStepForm.vue — inline-create cria LeadVariable (interna), NÃO CustomAttributeDefinition', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.clearAllMocks();
  });

  it('cria a variável via endpoint ai_lead_variables, seleciona a chave e emite variable-created', async () => {
    const wrapper = mountForm({ name: 'Coleta' });
    stubAxios('bairro'); // o POST devolve { name: 'bairro' }

    // abre o inline-create, digita e confirma
    await wrapper.get('button.underline').trigger('click'); // "criar variável interna"
    const nameInput = wrapper.get('[data-testid="new-variable-name"]');
    await nameInput.setValue('bairro');
    // botão "Criar" (bg-n-brand dentro do inline-create)
    const createBtn = wrapper
      .findAll('button')
      .find(b => b.classes().includes('bg-n-brand'));
    await createBtn.trigger('click');
    await flushPromises();

    // POST no endpoint de LEAD VARIABLE, não em custom_attribute_definitions
    const [url, body] = window.axios.post.mock.calls[0];
    expect(url).toContain('/ai_agents/3/ai_lead_variables');
    expect(url).not.toContain('custom_attribute_definitions');
    expect(body).toEqual({ ai_lead_variable: { name: 'bairro' } });

    // pai é avisado para empilhar na lista; a chave criada fica selecionada
    expect(wrapper.emitted('variableCreated')[0][0]).toEqual({
      id: 99,
      name: 'bairro',
    });

    await wrapper.get('button.bg-n-brand').trigger('click'); // salvar a etapa
    await flushPromises();
    expect(wrapper.emitted('save').at(-1)[0].collect).toEqual({
      attribute: 'bairro',
      type: 'text',
    });

    wrapper.unmount();
  });
});

// (B2) choice: opções vêm de lista fixa OU do resultado de uma ferramenta (domínio dinâmico).
describe('AiStepForm.vue — choice: fonte das opções (lista fixa vs ferramenta)', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.clearAllMocks();
  });

  // Mesma armadilha #306/knowledge: buildStepPayload emite domain_from_tool, então sem semear o draft de
  // collect.domain_from_tool, editar a etapa apagaria o vínculo. Trava a semeadura de collectSource/tool.
  it('carregar choice com domain_from_tool e salvar SEM tocar preserva o vínculo (options limpa)', async () => {
    const wrapper = mountForm(
      {
        name: 'Período',
        collect: {
          attribute: 'periodo_reservado',
          type: 'choice',
          domain_from_tool: 'consultar_periodos',
        },
      },
      { tools: [{ name: 'consultar_periodos' }] }
    );

    await wrapper.get('button.bg-n-brand').trigger('click');
    await flushPromises();

    const collect = wrapper.emitted('save')[0][0].collect;
    expect(collect.domain_from_tool).toBe('consultar_periodos');
    expect(collect.options).toEqual([]);

    wrapper.unmount();
  });

  // Anti-degradação-silenciosa: a ferramenta salva não existe mais na lista do agente -> avisa na tela
  // (o runtime já faz fail-open + tool_domain.unextractable, mas quem edita precisa VER).
  it('ferramenta salva ausente da lista -> mostra o aviso; presente -> não mostra', () => {
    const step = {
      name: 'Período',
      collect: {
        attribute: 'periodo_reservado',
        type: 'choice',
        domain_from_tool: 'consultar_periodos',
      },
    };

    const semTool = mountForm(step, { tools: [{ name: 'outra_coisa' }] });
    expect(semTool.find('[data-testid="tool-domain-missing"]').exists()).toBe(
      true
    );
    semTool.unmount();

    const comTool = mountForm(step, {
      tools: [{ name: 'consultar_periodos' }],
    });
    expect(comTool.find('[data-testid="tool-domain-missing"]').exists()).toBe(
      false
    );
    comTool.unmount();
  });
});

// Higiene de variáveis: preview da normalização (item 1) + exclusão (item 4). A busca (item 5) é o ComboBox.
describe('AiStepForm.vue — higiene de variáveis (normalização + exclusão)', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.clearAllMocks();
  });

  it('preview: "número_conta" mostra a chave normalizada que vai nascer ("numero_conta")', async () => {
    const wrapper = mountForm({ name: 'Coleta' });

    await wrapper.get('button.underline').trigger('click'); // abre criar
    await wrapper
      .get('[data-testid="new-variable-name"]')
      .setValue('número_conta');

    expect(wrapper.get('[data-testid="normalized-preview"]').text()).toContain(
      'numero_conta'
    );
    wrapper.unmount();
  });

  it('excluir variável interna: confirma, chama DELETE no endpoint e emite variable-deleted', async () => {
    const wrapper = mountForm(
      { name: 'Coleta' },
      { leadVariables: [{ id: 99, name: 'documento_cpf' }] }
    );
    vi.stubGlobal('axios', {
      post: vi.fn(),
      delete: vi.fn().mockResolvedValue({}),
    });
    vi.spyOn(window, 'confirm').mockReturnValue(true);

    await wrapper.get('button.underline').trigger('click'); // abre criar/gerenciar
    await wrapper
      .get('[data-testid="delete-variable-documento_cpf"]')
      .trigger('click');
    await flushPromises();

    expect(window.axios.delete.mock.calls[0][0]).toContain(
      '/ai_lead_variables/99'
    );
    expect(wrapper.emitted('variableDeleted')[0]).toEqual([99]);
    wrapper.unmount();
  });
});

// Pedido do usuário (18/08): quando o dado coletado é um atributo personalizado do tipo "lista", tipo
// e opções têm que ser SEMPRE espelho do atributo — travados, não digitáveis à parte (evita a IA
// validando opções diferentes das que o resto do sistema aceita pra esse atributo).
describe('AiStepForm.vue — atributo de CAD tipo lista trava tipo/opções', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.clearAllMocks();
  });

  const cidadeCad = {
    attribute_key: 'cidade',
    attribute_display_type: 'list',
    attribute_values: ['Chapecó', 'Maravilha'],
  };

  it('etapa com atributo de CAD lista: trava o Select de tipo e mostra as opções como somente-leitura, espelhando o CAD', () => {
    const wrapper = mountForm(
      { name: 'Cidade', collect: { attribute: 'cidade', type: 'text' } },
      { customAttributes: [cidadeCad] }
    );

    expect(
      wrapper
        .findComponent('[data-testid="step-collect-type"]')
        .props('disabled')
    ).toBe(true);
    const locked = wrapper.get('[data-testid="step-collect-options-locked"]');
    expect(locked.element.disabled).toBe(true);
    expect(locked.element.value).toBe('Chapecó\nMaravilha');
    expect(
      wrapper.find('[data-testid="step-collect-options-free"]').exists()
    ).toBe(false);
    wrapper.unmount();
  });

  // Achado ao vivo (18/08, ampliado): um CAD tipo "link" (chave_1_2_3_) deixava a etapa mostrar
  // "Escolha (opções)" com valores digitados à mão, sem relação com o atributo real (que nem é lista).
  // Qualquer CAD trava o Tipo do dado (mapeado do attribute_display_type); só CAD tipo lista mostra
  // a caixa de opções (travada) — os demais tipos não têm "opções" pra mostrar.
  it('atributo de CAD tipo "link" (não-lista): trava o Select de tipo (mapeado pra texto) e NÃO mostra nenhuma caixa de opções', () => {
    const linkCad = {
      attribute_key: 'chave_1_2_3_',
      attribute_display_type: 'link',
    };
    const wrapper = mountForm(
      {
        name: 'Etapa',
        collect: {
          attribute: 'chave_1_2_3_',
          type: 'choice',
          options: ['coisa 1', 'coisa2'],
        },
      },
      { customAttributes: [linkCad] }
    );

    const typeSelect = wrapper.findComponent(
      '[data-testid="step-collect-type"]'
    );
    expect(typeSelect.props('disabled')).toBe(true);
    expect(typeSelect.props('modelValue')).toBe('text');
    expect(
      wrapper.find('[data-testid="step-collect-options-locked"]').exists()
    ).toBe(false);
    expect(
      wrapper.find('[data-testid="step-collect-options-free"]').exists()
    ).toBe(false);
    wrapper.unmount();
  });

  it('atributo de CAD tipo "número": trava o Select de tipo mapeado pra "number"', () => {
    const numeroCad = {
      attribute_key: 'idade',
      attribute_display_type: 'number',
    };
    const wrapper = mountForm(
      { name: 'Etapa', collect: { attribute: 'idade', type: 'text' } },
      { customAttributes: [numeroCad] }
    );

    const typeSelect = wrapper.findComponent(
      '[data-testid="step-collect-type"]'
    );
    expect(typeSelect.props('disabled')).toBe(true);
    expect(typeSelect.props('modelValue')).toBe('number');
    wrapper.unmount();
  });

  it('atributo SEM CAD lista correspondente: tipo/opções continuam livres pra editar', () => {
    const wrapper = mountForm(
      {
        name: 'Nome',
        collect: {
          attribute: 'nome_cliente',
          type: 'choice',
          options: ['A', 'B'],
        },
      },
      { customAttributes: [cidadeCad] }
    );

    expect(
      wrapper
        .findComponent('[data-testid="step-collect-type"]')
        .props('disabled')
    ).toBe(false);
    expect(
      wrapper.find('[data-testid="step-collect-options-locked"]').exists()
    ).toBe(false);
    expect(
      wrapper.get('[data-testid="step-collect-options-free"]').element.value
    ).toBe('A\nB');
    wrapper.unmount();
  });
});
