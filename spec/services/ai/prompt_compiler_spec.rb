require 'rails_helper'

RSpec.describe Ai::PromptCompiler do
  # Doubles leves: o compile só lê atributos (e faz Team.where/Ai::Agent.where, que voltam vazios).
  def build_agent
    double('agent',
           base_prompt: 'Você é a assistente da SCNET.', assistant_personality: nil,
           assistant_language: nil, guardrails: nil, assistant_name: 'Bia', name: 'Bia',
           company_name: 'SCNET', site: nil, identify_as: 'ai', account_id: 987_654,
           handoff_agent_ids: [])
  end

  def build_dept(instructions:)
    double('dept', name: 'Comercial', objetivo: 'Converter leads em clientes',
                   instructions: instructions, playbook: nil, lead_variables: [])
  end

  def compile(dept)
    described_class.compile(agent: build_agent, department: dept, knowledge: [], memory: nil, tools: [])
  end

  it 'NÃO injeta mais o campo legado department.instructions no prompt (dept com lixo)' do
    prompt = compile(build_dept(instructions: 'dhsezhdsrhsderhesdr'))

    expect(prompt).not_to include('dhsezhdsrhsderhesdr')
    expect(prompt).not_to include('Instruções:')
  end

  it 'ignora até um valor "válido" antigo em instructions (aposentado independente do conteúdo)' do
    prompt = compile(build_dept(instructions: 'Sempre confirme os dados duas vezes.'))

    expect(prompt).not_to include('Sempre confirme os dados duas vezes.')
    expect(prompt).not_to include('Instruções:')
  end

  it 'segue compilando normalmente o restante (identidade + objetivo do departamento)' do
    prompt = compile(build_dept(instructions: 'qualquer coisa'))

    expect(prompt).to include('Departamento: Comercial')
    expect(prompt).to include('Objetivo: Converter leads em clientes')
    expect(prompt).to include('SCNET')
  end

  it 'departments com instructions vazio compilam igual (nunca importou)' do
    prompt = compile(build_dept(instructions: ''))

    expect(prompt).to include('Departamento: Comercial')
    expect(prompt).not_to include('Instruções:')
  end

  describe 'bloco de conhecimento (uso restrito — anti-alucinação)' do
    def compile_with_knowledge(knowledge)
      described_class.compile(agent: build_agent, department: build_dept(instructions: nil),
                              knowledge: knowledge, memory: nil, tools: [])
    end

    it 'injeta o conhecimento E a instrução de usar SÓ ele / nunca inventar produto/valor' do
      prompt = compile_with_knowledge(["Internet Fibra 300 Mega\nPlano residencial R$ 89,90"])

      expect(prompt).to include('Base de conhecimento relevante')
      expect(prompt).to include('Internet Fibra 300 Mega') # o conteúdo do RAG entrou
      expect(prompt).to include('Use APENAS os produtos, planos, valores')
      expect(prompt).to include('NUNCA invente')
    end

    it 'não injeta o bloco (nem a instrução) quando não há conhecimento' do
      prompt = compile_with_knowledge([])

      expect(prompt).not_to include('Base de conhecimento relevante')
      expect(prompt).not_to include('NUNCA invente')
    end
  end

  describe 'âncora determinística de etapa (step_index)' do
    def build_dept_with_steps(steps)
      pb = double('playbook', steps: steps, transfer_when: [], close_when: [])
      double('dept', name: 'Comercial', objetivo: 'Converter leads', instructions: nil,
                     playbook: pb, lead_variables: [])
    end

    def compile_step(steps, step_index: nil)
      described_class.compile(agent: build_agent, department: build_dept_with_steps(steps),
                              knowledge: [], memory: nil, tools: [], step_index: step_index)
    end

    let(:steps) { [{ 'name' => 'Coleta' }, { 'name' => 'Proposta' }, { 'name' => 'Fechamento' }] }

    it 'ancora o modelo na etapa do índice informado (não deixa ele se autolocalizar)' do
      prompt = compile_step(steps, step_index: 1)

      expect(prompt).to include('ETAPA ATUAL (definida pelo sistema, não por você): 2 de 3 — "Proposta"')
      expect(prompt).to include('NÃO volte a etapas anteriores')
      # o texto legado que pedia o modelo se localizar sozinho saiu
      expect(prompt).not_to include('informe o nome EXATO da etapa atual')
    end

    it 'assume a primeira etapa (índice 0) quando nenhum índice é passado' do
      prompt = compile_step(steps, step_index: nil)

      expect(prompt).to include('ETAPA ATUAL (definida pelo sistema, não por você): 1 de 3 — "Coleta"')
    end

    it 'clampa um índice fora do range na última etapa' do
      prompt = compile_step(steps, step_index: 99)

      expect(prompt).to include('3 de 3 — "Fechamento"')
    end

    it 'lista as etapas na ordem para contexto' do
      prompt = compile_step(steps, step_index: 0)

      expect(prompt).to include('Etapas do atendimento (na ordem):')
      expect(prompt).to include('- Coleta')
      expect(prompt).to include('- Fechamento')
    end
  end

  describe 'ESTADO DA COLETA (reforço ativo — JÁ TENHO / FALTA agora)' do
    def build_dept_with_steps(steps)
      pb = double('playbook', steps: steps, transfer_when: [], close_when: [])
      double('dept', name: 'Comercial', objetivo: 'Converter leads', instructions: nil,
                     playbook: pb, lead_variables: [])
    end

    def compile_state(steps:, step_index:, collected: {})
      described_class.compile(agent: build_agent, department: build_dept_with_steps(steps),
                              knowledge: [], memory: nil, tools: [], collected: collected,
                              step_index: step_index)
    end

    let(:steps) do
      [{ 'name' => 'Nome', 'collect' => { 'attribute' => 'nome', 'required' => true } },
       { 'name' => 'Cidade', 'collect' => { 'attribute' => 'cidade', 'required' => true } },
       { 'name' => 'Planos', 'complete_when' => 'always' }]
    end

    it 'mostra "JÁ TENHO" com os fatos coletados e a regra anti-repetição' do
      prompt = compile_state(steps: steps, step_index: 1, collected: { 'nome' => 'Jaque' })

      expect(prompt).to include('ESTADO DA COLETA')
      expect(prompt).to include('✓ JÁ TENHO: nome=Jaque')
      expect(prompt).to include('NUNCA peça de novo um dado da lista "JÁ TENHO"')
    end

    it 'mostra "FALTA agora" com a CHAVE do slot da etapa atual quando ainda não coletado' do
      prompt = compile_state(steps: steps, step_index: 1, collected: { 'nome' => 'Jaque' })

      expect(prompt).to include('◦ FALTA agora')
      expect(prompt).to include('cidade')
    end

    it 'NÃO mostra "FALTA agora" quando o slot da etapa atual já foi coletado' do
      prompt = compile_state(steps: steps, step_index: 1, collected: { 'nome' => 'Jaque', 'cidade' => 'Chapecó' })

      expect(prompt).not_to include('◦ FALTA agora')
      expect(prompt).to include('✓ JÁ TENHO: nome=Jaque, cidade=Chapecó')
    end

    it 'não injeta "FALTA agora" em etapa informativa (sem collect)' do
      prompt = compile_state(steps: steps, step_index: 2, collected: { 'nome' => 'Jaque' })

      expect(prompt).not_to include('◦ FALTA agora')
    end

    it 'omite o bloco inteiro quando não há nada coletado e a etapa não declara slot' do
      informational = [{ 'name' => 'Boas-vindas', 'complete_when' => 'always' }]
      prompt = compile_state(steps: informational, step_index: 0, collected: {})

      expect(prompt).not_to include('ESTADO DA COLETA')
    end

    it 'em etapa de slot sem nada coletado, mostra só "FALTA agora" (sem "JÁ TENHO")' do
      prompt = compile_state(steps: steps, step_index: 0, collected: {})

      expect(prompt).to include('ESTADO DA COLETA')
      expect(prompt).to include('◦ FALTA agora')
      expect(prompt).to include('nome')
      expect(prompt).not_to include('✓ JÁ TENHO')
    end
  end

  # Prompt ENXUTO da 2ª chamada (Ai::Gateway#tool_followup): a ferramenta já rodou, o modelo só REDIGE
  # a resposta (pode pedir handoff/close). Saem os blocos de coleta/etapa/ferramenta; ficam persona,
  # RAG (+anti-invenção), times de handoff e o contrato. Objetos reais (o bloco de times precisa de Team).
  describe 'compile(followup:) — enxuga a 2ª chamada' do
    let(:account) { create(:account) }
    let(:profile) do
      Ai::OperationProfile.create!(account_id: account.id, name: 'p', supervisor_provider: 'openai',
                                   supervisor_model: 'gpt-4.1-mini')
    end
    let(:real_agent) do
      Ai::Agent.create!(account: account, name: 'Bia', status: 'active', ai_operation_profile_id: profile.id,
                        guardrails: 'Nunca prometa desconto.')
    end
    let(:real_dept) do
      dept = Ai::Department.create!(account: account, ai_agent_id: real_agent.id, name: 'Comercial',
                                    objetivo: 'Vender', status: 'active', behavior: {})
      dept.create_playbook!(active: true, transfer_when: ['cliente irritado'], steps: [
                              { 'name' => 'CADASTRO', 'instructions' => 'Peça e grave documento.' },
                              { 'name' => 'Fim' }
                            ])
      dept.lead_variables.create!(name: 'cidade', account: account)
      Ai::Tool.create!(account: account, ai_department_id: dept.id, name: 'consulta_cobertura',
                       implementation_type: 'capability', capability_key: 'coverage.check', status: 'active',
                       description: 'Checa cobertura')
      dept
    end

    before { create(:team, account: account, name: 'Suporte N2') }

    def compile(followup:, knowledge: ['Internet Fibra 300 Mega — Plano residencial R$ 89,90'])
      described_class.compile(
        agent: real_agent, department: real_dept, knowledge: knowledge, memory: nil,
        tools: real_dept.tools.active.to_a, collected: { 'documento' => 'CNH-123' },
        fillable_attributes: [%w[email E-mail]], step_index: 0, followup: followup
      )
    end

    it 'followup NÃO contém: LISTA de etapas, lead_variables, fillable, tools, transfer_when' do
      prompt = compile(followup: true)

      aggregate_failures do
        expect(prompt).not_to include('Etapas do atendimento')            # LISTA completa de etapas
        expect(prompt).not_to include('Procure coletar naturalmente')      # lead_variables
        expect(prompt).not_to include('Atributos da conversa para preencher') # fillable_attributes
        expect(prompt).not_to include('Ferramentas disponíveis')           # tools
        expect(prompt).not_to include('consulta_cobertura')
        expect(prompt).not_to include('Transfira para humano quando')
      end
    end

    # Ajuste do #273: a âncora da etapa corrente e o estado da coleta VOLTARAM ao followup (conv 372 — o
    # followup redigia sem saber a etapa e repedia dado já coletado). O CORTE do #273 (lista de etapas,
    # lead, fillable, tools) segue de pé — só estes dois blocos retornam.
    it 'followup CONTÉM a âncora da etapa corrente e o ESTADO DA COLETA (JÁ TENHO com os fatos)' do
      prompt = compile(followup: true)

      aggregate_failures do
        expect(prompt).to include('ETAPA ATUAL (definida pelo sistema, não por você): 1 de 2 — "CADASTRO"')
        expect(prompt).to include('ESTADO DA COLETA (mantido pelo sistema')
        expect(prompt).to include('✓ JÁ TENHO: documento=CNH-123') # facts populados aparecem no followup
      end
    end

    it 'followup mostra "FALTA agora" com a CHAVE do slot da etapa quando ainda não coletado' do
      real_dept.playbook.update!(steps: [
                                   { 'name' => 'CADASTRO', 'collect' => { 'attribute' => 'documento_cpf' } },
                                   { 'name' => 'Fim' }
                                 ])
      prompt = described_class.compile(
        agent: real_agent, department: real_dept, knowledge: [], memory: nil, tools: [],
        collected: {}, step_index: 0, followup: true
      )

      aggregate_failures do
        expect(prompt).to include('◦ FALTA agora')
        expect(prompt).to include('documento_cpf')
        expect(prompt).not_to include('Etapas do atendimento') # a lista continua fora
      end
    end

    it 'followup CONTÉM: persona, guardrails, RAG (+anti-invenção), times de handoff, response_contract' do
      prompt = compile(followup: true)

      aggregate_failures do
        expect(prompt).to include('Bia')                                   # persona
        expect(prompt).to include('Nunca prometa desconto.')               # guardrails
        expect(prompt).to include('Base de conhecimento relevante')        # RAG
        expect(prompt).to include('Internet Fibra 300 Mega')
        expect(prompt).to include('NUNCA invente')                         # anti-invenção
        expect(prompt).to include('Times disponíveis')                     # handoff humano
        expect(prompt).to include('Suporte N2')
        expect(prompt).to include('Retorne ESTRITAMENTE um JSON')          # response_contract
      end
    end

    it 'PRIMEIRA chamada (followup: false, default) mantém o prompt COMPLETO e MAIOR (regressão)' do
      full = compile(followup: false)

      expect(full).to include('Etapas do atendimento')
      expect(full).to include('ETAPA ATUAL')
      expect(full).to include('✓ JÁ TENHO')
      expect(full).to include('Ferramentas disponíveis')
      expect(full).to include('consulta_cobertura')
      expect(compile(followup: true).length).to be < full.length
    end

    it 'sem RAG e sem memória: o followup enxuto ainda compila (não quebra)' do
      prompt = described_class.compile(agent: real_agent, department: real_dept, knowledge: [], memory: nil,
                                       tools: [], customer_memory: nil, followup: true)

      expect(prompt).to include('Retorne ESTRITAMENTE um JSON')
      expect(prompt).not_to include('Base de conhecimento relevante')
    end
  end
end
