require 'rails_helper'
require 'sidekiq/api'

# Diagnóstico do bug URGENTE ao vivo: "Python em silêncio total desde o deploy, rede confirmada OK".
RSpec.describe Ai::PythonOrchestratorDiagnostics do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'padrão', supervisor_provider: 'openai', supervisor_model: 'gpt-4o')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
  let(:department) do
    Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Comercial', status: 'active',
                           behavior: { 'python_orchestrator' => true })
  end
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }

  describe '.sidekiq_status' do
    it 'devolve um hash sem levantar exceção mesmo se a consulta ao Sidekiq falhar' do
      allow(Sidekiq::Queue).to receive(:new).and_raise(StandardError.new('redis indisponível'))

      result = described_class.sidekiq_status

      expect(result[:error]).to include('redis indisponível')
    end

    it 'devolve as 3 contagens quando o Sidekiq responde normalmente' do
      result = described_class.sidekiq_status

      expect(result).to include(:medium_queue_size, :gateway_run_job_retrying, :gateway_run_job_dead)
    end
  end

  describe '.recent_runs' do
    it 'devolve [] quando não há nenhum Ai::Run pra essa conversa (Gateway nunca rodou)' do
      expect(described_class.recent_runs(conversation)).to eq([])
    end

    it 'devolve os runs recentes com status/error_type/department_id' do
      Ai::Run.create!(account_id: account.id, conversation_id: conversation.id, ai_agent_id: agent.id,
                      inbox_id: inbox.id, run_type: 'decision', mode: 'live', status: 'error',
                      error_type: 'internal_error', ai_department_id: department.id)

      runs = described_class.recent_runs(conversation)

      expect(runs.size).to eq(1)
      expect(runs.first).to include(status: 'error', error_type: 'internal_error', department_id: department.id)
    end
  end

  describe '.flag_status' do
    it 'resolve o department VIA Ai::Run quando existe' do
      Ai::Run.create!(account_id: account.id, conversation_id: conversation.id, ai_agent_id: agent.id,
                      inbox_id: inbox.id, run_type: 'decision', mode: 'live', status: 'recorded',
                      ai_department_id: department.id)

      flags = described_class.flag_status(conversation)

      expect(flags).to contain_exactly(
        { department_id: department.id, name: 'Comercial', raw: true, raw_class: 'TrueClass', on: true }
      )
    end

    it 'sem Ai::Run, resolve VIA Ai::AgentInbox ativo da inbox' do
      Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'live', active: true)
      department # força a criação

      flags = described_class.flag_status(conversation)

      expect(flags.map { |f| f[:department_id] }).to include(department.id)
    end

    it 'aceita a flag gravada como STRING "true" (achado ao vivo do bug do tipo)' do
      department.update!(behavior: { 'python_orchestrator' => 'true' })
      Ai::Run.create!(account_id: account.id, conversation_id: conversation.id, ai_agent_id: agent.id,
                      inbox_id: inbox.id, run_type: 'decision', mode: 'live', status: 'recorded',
                      ai_department_id: department.id)

      flags = described_class.flag_status(conversation)

      expect(flags.first).to include(raw: 'true', raw_class: 'String', on: true)
    end

    it '[] quando não acha department candidato nem por Ai::Run nem por Ai::AgentInbox' do
      expect(described_class.flag_status(conversation)).to eq([])
    end
  end

  describe '.direct_call' do
    it 'pula com skipped quando não há mensagem incoming' do
      expect(described_class.direct_call(conversation)).to eq(skipped: 'sem mensagem incoming nesta conversa')
    end

    it 'pula com skipped quando não há Ai::AgentInbox ativo' do
      create(:message, conversation: conversation, account: account, message_type: 'incoming', content: 'oi')

      expect(described_class.direct_call(conversation)[:skipped]).to include('nenhum Ai::AgentInbox ativo')
    end

    it 'chama Ai::PythonOrchestratorClient FORÇANDO mode: shadow, mesmo pedindo diagnóstico numa conta live' do
      create(:message, conversation: conversation, account: account, message_type: 'incoming', content: 'oi')
      Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'live', active: true)
      department

      expect(Ai::PythonOrchestratorClient).to receive(:process_message)
        .with(hash_including(mode: 'shadow'))
        .and_return(reply: 'Oi! Como posso ajudar?', conversation_id: 'conv_1')

      result = described_class.direct_call(conversation)

      expect(result[:result]).to eq(reply: 'Oi! Como posso ajudar?', conversation_id: 'conv_1')
      expect(result[:department_id]).to eq(department.id)
    end

    it 'captura a exceção CRUA em vez de deixar o rescue silencioso escondê-la (o ponto inteiro do diagnóstico)' do
      create(:message, conversation: conversation, account: account, message_type: 'incoming', content: 'oi')
      Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'live', active: true)
      department
      allow(Ai::PythonOrchestratorClient).to receive(:process_message).and_raise(NoMethodError.new('boom'))

      result = described_class.direct_call(conversation)

      expect(result[:exception]).to include('NoMethodError', 'boom')
      expect(result[:backtrace]).to be_an(Array)
    end
  end

  describe '.truthy?' do
    it 'true pro booleano true' do
      expect(described_class.truthy?(true)).to be(true)
    end

    it 'true pra string "true" (case/espaço insensível)' do
      expect(described_class.truthy?(' True ')).to be(true)
    end

    it 'false pro booleano false, nil, e qualquer outra string' do
      expect(described_class.truthy?(false)).to be(false)
      expect(described_class.truthy?(nil)).to be(false)
      expect(described_class.truthy?('false')).to be(false)
    end
  end
end
