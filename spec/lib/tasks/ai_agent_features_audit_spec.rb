require 'rails_helper'
require 'rake'

RSpec.describe 'ai:agent_features_audit', type: :task do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?('ai:agent_features_audit')
  end

  let(:task) { Rake::Task['ai:agent_features_audit'] }
  after { task.reenable }

  let(:account) { create(:account) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini',
                                 worker_overrides: { 'ocr' => { 'provider' => 'openai', 'model' => 'gpt-4.1-mini' } })
  end

  # Agente COM recursos configurados (RAG + tool + automação + follow-up + handoff + lead var).
  def agent_with_features
    agent = Ai::Agent.create!(
      account: account, name: 'Bia', status: 'active', ai_operation_profile_id: profile.id,
      base_prompt: 'Você é a assistente da SCNET.', guardrails: 'Nunca invente preços.',
      handoff_agent_ids: [999], follow_up: { 'behaviors' => [{ 'context' => 'inbox_hours' }] }
    )
    Ai::Playbook.create!(ai_agent_id: agent.id, active: true, objetivo: 'Converter leads',
                         steps: [{ 'name' => 'Qualificação', 'instructions' => 'x',
                                   'automations' => [{ 'type' => 'tag' }, { 'type' => 'webhook' }] }])
    ks = Ai::KnowledgeSource.create!(account: account, ai_agent_id: agent.id, kind: 'faq', status: 'active',
                                     title: 'Planos', raw: 'conteudo')
    Ai::KnowledgeChunk.create!(ai_knowledge_source_id: ks.id, content: 'Fibra 300 Mega R$ 89,90')
    Ai::Tool.create!(account: account, ai_agent_id: agent.id, name: 'buscar_plano', status: 'active',
                     implementation_type: 'capability')
    Ai::LeadVariable.create!(account: account, ai_agent_id: agent.id, name: 'cidade', var_type: 'texto')
    agent
  end

  # Agente SEM recursos: bare, sem playbook/tools/knowledge/lead vars.
  def agent_without_features
    Ai::Agent.create!(account: account, name: 'Vazio', status: 'active', ai_operation_profile_id: profile.id)
  end

  it 'roda sem erro e mostra recursos EM USO para um agente configurado' do
    agent = agent_with_features

    expect { task.invoke(agent.id.to_s) }.to output(
      a_string_including("AGENTE ##{agent.id}")
        .and(a_string_including('RAG/Conhecimento'))
        .and(a_string_including('sim'))
        .and(a_string_including('TRANSVERSAIS'))
    ).to_stdout
  end

  it 'roda sem erro para um agente SEM recursos configurados' do
    agent = agent_without_features

    expect { task.invoke(agent.id.to_s) }.to output(
      a_string_including("AGENTE ##{agent.id}").and(a_string_including('não'))
    ).to_stdout
  end

  it 'aborta (guard) quando o agent_id não existe' do
    expect { task.invoke('999999') }.to raise_error(SystemExit)
  end

  it 'sem agent_id: imprime um resumo (uma linha por agente)' do
    agent = agent_with_features

    expect { task.invoke }.to output(
      a_string_including("##{agent.id}").and(a_string_including('RAG:'))
    ).to_stdout
  end

  it 'FORMAT=json emite JSON válido' do
    agent = agent_with_features
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('FORMAT').and_return('json')

    output = nil
    expect { output = capture_stdout { task.invoke(agent.id.to_s) } }.not_to raise_error
    expect { JSON.parse(output) }.not_to raise_error
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
