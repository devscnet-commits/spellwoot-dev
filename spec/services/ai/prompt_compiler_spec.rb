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
end
