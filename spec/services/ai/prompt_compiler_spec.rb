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
end
