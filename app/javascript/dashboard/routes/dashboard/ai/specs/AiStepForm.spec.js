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
      departmentId: '5',
      departments: [],
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

// "DADOS PARA COLETA NA ETAPA": lista de itens (Ai::StepSlot.items no backend), cada um com seu próprio
// type/options/required/hint — substitui o Select único de antes (1 collect.attribute por etapa).
describe('AiStepForm.vue — "+ Selecionar dado do sistema" (união LeadVariable ∪ CustomAttributeDefinition, origem marcada)', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.clearAllMocks();
  });

  const addExistingCombo = wrapper =>
    wrapper.findComponent('[data-testid="collect-add-existing"]');

  it('popula o ComboBox da UNIÃO com a origem marcada (interna vs painel), sem opção vazia', () => {
    const wrapper = mountForm(
      { name: 'Coleta' },
      {
        leadVariables: [{ name: 'periodo_reservado' }],
        customAttributes: [
          {
            attribute_model: 'conversation_attribute',
            attribute_key: 'cidade',
          },
          {
            attribute_model: 'contact_attribute',
            attribute_key: 'telefone_contato',
          },
        ],
      }
    );

    const options = addExistingCombo(wrapper).props('options');
    // não existe mais opção vazia: uma etapa informativa é só uma lista de itens vazia, não uma escolha
    // dentro do combo.
    expect(options.some(o => o.value === '')).toBe(false);
    const byValue = Object.fromEntries(options.map(o => [o.value, o.label]));
    // LeadVariable => interna; CAD conversation_attribute OU contact_attribute => painel (805d2b6: um
    // CAD de contato tem que aparecer aqui também, senão o dado nunca chega pro atendente humano).
    expect(byValue.periodo_reservado).toContain('interna');
    expect(byValue.cidade).toContain('painel');
    expect(byValue.telefone_contato).toContain('painel');

    wrapper.unmount();
  });

  it('nenhum item -> collect: null (etapa informativa é a lista vazia, não uma escolha à parte)', async () => {
    const wrapper = mountForm({ name: 'Coleta' });

    await wrapper.get('button.bg-n-brand').trigger('click');
    await flushPromises();
    expect(wrapper.emitted('save')[0][0].collect).toBe(null);

    wrapper.unmount();
  });

  it('escolher um dado no ComboBox AGREGA um item novo, expandido, com type=text/required=true por default', async () => {
    const wrapper = mountForm(
      { name: 'Coleta' },
      { leadVariables: [{ name: 'cidade' }] }
    );

    await addExistingCombo(wrapper).vm.$emit('update:modelValue', 'cidade');
    await flushPromises();

    await wrapper.get('button.bg-n-brand').trigger('click');
    await flushPromises();
    expect(wrapper.emitted('save')[0][0].collect).toEqual({
      items: [{ attribute: 'cidade', type: 'text', required: true }],
    });

    wrapper.unmount();
  });

  it('escolher o MESMO dado duas vezes não duplica: já adicionado some das opções do ComboBox', async () => {
    const wrapper = mountForm(
      {
        name: 'Coleta',
        collect: {
          items: [{ attribute: 'cidade', type: 'text', required: true }],
        },
      },
      { leadVariables: [{ name: 'cidade' }] }
    );

    const options = addExistingCombo(wrapper).props('options');
    expect(options.some(o => o.value === 'cidade')).toBe(false);

    wrapper.unmount();
  });

  it('CPF obrigatório + e-mail opcional na MESMA etapa: cada item guarda seu próprio required', async () => {
    const step = {
      name: 'Dados do cliente',
      collect: {
        items: [
          { attribute: 'cpf_cliente', type: 'cpf', required: true },
          { attribute: 'email_cliente', type: 'email', required: false },
        ],
      },
    };
    const wrapper = mountForm(step);

    await wrapper.get('button.bg-n-brand').trigger('click');
    await flushPromises();
    const items = wrapper.emitted('save')[0][0].collect.items;
    expect(items[0]).toEqual({
      attribute: 'cpf_cliente',
      type: 'cpf',
      required: true,
    });
    expect(items[1]).toEqual({
      attribute: 'email_cliente',
      type: 'email',
      required: false,
    });

    wrapper.unmount();
  });

  it('remover um item tira ele do payload (os outros permanecem)', async () => {
    const step = {
      name: 'Dados do cliente',
      collect: {
        items: [
          { attribute: 'cpf_cliente', type: 'cpf', required: true },
          { attribute: 'email_cliente', type: 'email', required: false },
        ],
      },
    };
    const wrapper = mountForm(step);

    await wrapper
      .get('[data-testid="collect-item-remove-cpf_cliente"]')
      .trigger('click');
    await wrapper.get('button.bg-n-brand').trigger('click');
    await flushPromises();

    const items = wrapper.emitted('save')[0][0].collect.items;
    expect(items).toEqual([
      { attribute: 'email_cliente', type: 'email', required: false },
    ]);

    wrapper.unmount();
  });

  it('etapa antiga (1 collect, attribute em array — ticket 586) abre como items[] separados', async () => {
    const wrapper = mountForm({
      name: 'Cidade',
      collect: {
        attribute: ['cidade', 'viabilidade'],
        type: 'text',
        options: ['A', 'B'],
      },
    });

    await wrapper.get('button.bg-n-brand').trigger('click');
    await flushPromises();
    const items = wrapper.emitted('save')[0][0].collect.items;
    expect(items.map(i => i.attribute)).toEqual(['cidade', 'viabilidade']);

    wrapper.unmount();
  });

  it('etapa antiga com slot_required:false (nível da etapa) migra pro required do item', async () => {
    const wrapper = mountForm({
      name: 'Indicação',
      slot_required: false,
      collect: { attribute: 'indicacao', type: 'text' },
    });

    await wrapper.get('button.bg-n-brand').trigger('click');
    await flushPromises();
    expect(wrapper.emitted('save')[0][0].collect.items[0].required).toBe(false);

    wrapper.unmount();
  });

  it('dica de extração (hint): carregada do banco e reemitida no save', async () => {
    const wrapper = mountForm({
      name: 'Cidade',
      collect: {
        items: [
          {
            attribute: 'cidade',
            type: 'text',
            required: true,
            hint: 'Cidade para instalar a internet',
          },
        ],
      },
    });

    expect(wrapper.text()).toContain('Cidade para instalar a internet');

    await wrapper.get('button.bg-n-brand').trigger('click');
    await flushPromises();
    expect(wrapper.emitted('save')[0][0].collect.items[0].hint).toBe(
      'Cidade para instalar a internet'
    );

    wrapper.unmount();
  });
});

describe('AiStepForm.vue — inline-create cria LeadVariable (interna), NÃO CustomAttributeDefinition, e já vira item', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.clearAllMocks();
  });

  it('cria a variável via endpoint ai_lead_variables, adiciona como item e emite variable-created', async () => {
    const wrapper = mountForm({ name: 'Coleta' });
    stubAxios('bairro'); // o POST devolve { name: 'bairro' }

    // abre o inline-create, digita e confirma
    await wrapper.get('[data-testid="collect-add-custom"]').trigger('click');
    const nameInput = wrapper.get('[data-testid="new-variable-name"]');
    await nameInput.setValue('bairro');
    // botão "Criar" (bg-n-brand dentro do inline-create — único bg-n-brand na tela enquanto criatingVariable é true)
    const createBtn = wrapper
      .findAll('button')
      .find(b => b.classes().includes('bg-n-brand'));
    await createBtn.trigger('click');
    await flushPromises();

    // POST no endpoint de LEAD VARIABLE, não em custom_attribute_definitions
    const [url, body] = window.axios.post.mock.calls[0];
    expect(url).toContain('/ai_agents/3/ai_departments/5/ai_lead_variables');
    expect(url).not.toContain('custom_attribute_definitions');
    expect(body).toEqual({ ai_lead_variable: { name: 'bairro' } });

    // pai é avisado para empilhar na lista
    expect(wrapper.emitted('variableCreated')[0][0]).toEqual({
      id: 99,
      name: 'bairro',
    });

    await wrapper.get('button.bg-n-brand').trigger('click'); // salvar a etapa
    await flushPromises();
    expect(wrapper.emitted('save').at(-1)[0].collect).toEqual({
      items: [{ attribute: 'bairro', type: 'text', required: true }],
    });

    wrapper.unmount();
  });
});

// (B2) choice: opções vêm de lista fixa OU do resultado de uma ferramenta (domínio dinâmico), por item.
describe('AiStepForm.vue — choice: fonte das opções (lista fixa vs ferramenta), por item', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.clearAllMocks();
  });

  // Mesma armadilha #306/knowledge: buildStepPayload emite domain_from_tool, então sem semear o item de
  // domain_from_tool, editar a etapa apagaria o vínculo.
  it('carregar choice com domain_from_tool e salvar SEM tocar preserva o vínculo (options limpa)', async () => {
    const wrapper = mountForm(
      {
        name: 'Período',
        collect: {
          items: [
            {
              attribute: 'periodo_reservado',
              type: 'choice',
              required: true,
              domain_from_tool: 'consultar_periodos',
            },
          ],
        },
      },
      { tools: [{ name: 'consultar_periodos' }] }
    );

    await wrapper.get('button.bg-n-brand').trigger('click');
    await flushPromises();

    const item = wrapper.emitted('save')[0][0].collect.items[0];
    expect(item.domain_from_tool).toBe('consultar_periodos');
    expect(item.options).toEqual([]);

    wrapper.unmount();
  });

  // Anti-degradação-silenciosa: a ferramenta salva não existe mais na lista do department -> avisa na tela
  // (o runtime já faz fail-open + tool_domain.unextractable, mas quem edita precisa VER). O item precisa
  // estar EXPANDIDO pro aviso aparecer (é dentro do editor) — etapa carregada do banco abre recolhida, então
  // clica em editar primeiro.
  it('ferramenta salva ausente da lista -> mostra o aviso; presente -> não mostra', async () => {
    const step = {
      name: 'Período',
      collect: {
        items: [
          {
            attribute: 'periodo_reservado',
            type: 'choice',
            required: true,
            domain_from_tool: 'consultar_periodos',
          },
        ],
      },
    };

    const semTool = mountForm(step, { tools: [{ name: 'outra_coisa' }] });
    await semTool
      .get('[data-testid="collect-item-edit-periodo_reservado"]')
      .trigger('click');
    expect(semTool.find('[data-testid="tool-domain-missing"]').exists()).toBe(
      true
    );
    semTool.unmount();

    const comTool = mountForm(step, {
      tools: [{ name: 'consultar_periodos' }],
    });
    await comTool
      .get('[data-testid="collect-item-edit-periodo_reservado"]')
      .trigger('click');
    expect(comTool.find('[data-testid="tool-domain-missing"]').exists()).toBe(
      false
    );
    comTool.unmount();
  });
});

// Higiene de variáveis: preview da normalização + exclusão. A busca é o ComboBox de "+ Selecionar...".
describe('AiStepForm.vue — higiene de variáveis (normalização + exclusão)', () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.clearAllMocks();
  });

  it('preview: "número_conta" mostra a chave normalizada que vai nascer ("numero_conta")', async () => {
    const wrapper = mountForm({ name: 'Coleta' });

    await wrapper.get('[data-testid="collect-add-custom"]').trigger('click');
    await wrapper
      .get('[data-testid="new-variable-name"]')
      .setValue('número_conta');

    expect(wrapper.get('[data-testid="normalized-preview"]').text()).toContain(
      'numero_conta'
    );
    wrapper.unmount();
  });

  it('excluir variável interna: confirma, chama DELETE no endpoint, emite variable-deleted e remove o item que a usava', async () => {
    const wrapper = mountForm(
      {
        name: 'Coleta',
        collect: {
          items: [{ attribute: 'documento_cpf', type: 'text', required: true }],
        },
      },
      { leadVariables: [{ id: 99, name: 'documento_cpf' }] }
    );
    vi.stubGlobal('axios', {
      post: vi.fn(),
      delete: vi.fn().mockResolvedValue({}),
    });
    vi.spyOn(window, 'confirm').mockReturnValue(true);

    await wrapper.get('[data-testid="collect-add-custom"]').trigger('click'); // abre criar/gerenciar
    await wrapper
      .get('[data-testid="delete-variable-documento_cpf"]')
      .trigger('click');
    await flushPromises();

    expect(window.axios.delete.mock.calls[0][0]).toContain(
      '/ai_lead_variables/99'
    );
    expect(wrapper.emitted('variableDeleted')[0]).toEqual([99]);

    // fecha o painel de criar/gerenciar antes de salvar — senão o "Criar" (bg-n-brand, disabled, sem
    // nome digitado) é o PRIMEIRO .bg-n-brand no DOM e o clique no "Salvar" da etapa não acha o botão certo.
    await wrapper.get('[data-testid="collect-cancel-create"]').trigger('click');
    await wrapper.get('button.bg-n-brand').trigger('click');
    await flushPromises();
    expect(wrapper.emitted('save').at(-1)[0].collect).toBe(null); // item órfão removido junto

    wrapper.unmount();
  });
});
