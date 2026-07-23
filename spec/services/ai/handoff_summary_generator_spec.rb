require 'rails_helper'

RSpec.describe Ai::HandoffSummaryGenerator do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }

  before do
    Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'live', active: true)
    create(:message, account: account, inbox: inbox, conversation: conversation,
                     message_type: 'incoming', content: 'quero cancelar meu plano agora')
    allow(Ai::ModelRouter).to receive(:decide).and_return(
      { provider: 'openai', model: 'gpt-4.1-mini', decision: { 'summary' => 'Cliente quer cancelar o plano.' },
        tokens_in: 10, tokens_out: 5, cost: 0.001, latency_ms: 20, status: 'recorded' }
    )
  end

  it 'gera o resumo e cria Ai::HandoffSummary + Ai::Run, SEM consumir crédito' do
    balance = AiCreditBalance.create!(account_id: account.id, plan_credits: 5, extra_credits: 0)

    summary = described_class.new(conversation: conversation, reason: 'loop').generate

    expect(summary).to be_a(Ai::HandoffSummary)
    expect(summary.content).to eq('Cliente quer cancelar o plano.')
    expect(summary.reason).to eq('loop')
    expect(summary.run).to be_present

    run = Ai::Run.find_by(conversation_id: conversation.id, run_type: 'handoff_summary')
    expect(run).to be_present
    expect(run.mode).to eq('assistant')
    expect(run.cost).to eq(0.001) # custo registrado para os relatórios

    expect(balance.reload.total).to eq(5) # crédito NÃO foi consumido
  end

  it 'mapeia o token de ausência para "não informado" — NUNCA vaza o token cru no resumo (humano lê)' do
    conversation.update!(additional_attributes: {
                           'ai_collected_facts' => { 'email_cliente' => Ai::StepSlot::ABSENT, 'cidade' => 'Chapecó' }
                         })

    described_class.new(conversation: conversation, reason: 'loop').generate

    expect(Ai::ModelRouter).to have_received(:decide) do |kwargs|
      expect(kwargs[:system_prompt]).to include('email_cliente: não informado')
      expect(kwargs[:system_prompt]).not_to include(Ai::StepSlot::ABSENT)
    end
  end

  it 'inclui o motivo do handoff e o transcript no prompt' do
    described_class.new(conversation: conversation, reason: 'credit_exhausted').generate

    expect(Ai::ModelRouter).to have_received(:decide) do |kwargs|
      expect(kwargs[:system_prompt]).to include('créditos de IA da conta se esgotaram')
      expect(kwargs[:user_message]).to include('quero cancelar meu plano')
      expect(kwargs[:json]).to be(true)
    end
  end

  it 'NÃO cria resumo quando a geração falha (status error)' do
    allow(Ai::ModelRouter).to receive(:decide).and_return(
      { provider: 'openai', model: 'gpt-4.1-mini', decision: { 'error' => 'boom' },
        tokens_in: 0, tokens_out: 0, cost: 0.0, latency_ms: 1, status: 'error' }
    )

    expect { described_class.new(conversation: conversation, reason: 'loop').generate }
      .not_to change(Ai::HandoffSummary, :count)
  end

  it 'devolve nil e não levanta quando o summary vem vazio' do
    allow(Ai::ModelRouter).to receive(:decide).and_return(
      { provider: 'openai', model: 'gpt-4.1-mini', decision: { 'summary' => '' },
        tokens_in: 1, tokens_out: 1, cost: 0.0, latency_ms: 1, status: 'recorded' }
    )

    expect(described_class.new(conversation: conversation, reason: 'loop').generate).to be_nil
  end

  describe 'linha "Dados já coletados" (collected_attributes)' do
    def prompt_for(reason: 'loop')
      captured = nil
      allow(Ai::ModelRouter).to receive(:decide) do |kwargs|
        captured = kwargs[:system_prompt]
        { provider: 'openai', model: 'gpt-4.1-mini', decision: { 'summary' => 'ok' },
          tokens_in: 1, tokens_out: 1, cost: 0.0, latency_ms: 1, status: 'recorded' }
      end
      described_class.new(conversation: conversation, reason: reason).generate
      captured
    end

    it 'inclui todas as chaves de ai_collected_facts quando custom_attributes está vazio' do
      conversation.update!(custom_attributes: {},
                           additional_attributes: { 'ai_collected_facts' => {
                             'nome_cliente' => 'Fulano', 'telefone_secundario' => '49985671245'
                           } })

      prompt = prompt_for
      expect(prompt).to include('Dados já coletados do cliente:')
      expect(prompt).to include('nome_cliente: Fulano')
      expect(prompt).to include('telefone_secundario: 49985671245')
    end

    it 'quando a mesma chave existe nos dois, vence o valor de custom_attributes' do
      conversation.update!(custom_attributes: { 'cidade' => 'Maravilha' },
                           additional_attributes: { 'ai_collected_facts' => {
                             'cidade' => 'Chapecó', 'plano_escolhido' => 'Fibra 500'
                           } })

      prompt = prompt_for
      expect(prompt).to include('cidade: Maravilha')
      expect(prompt).not_to include('cidade: Chapecó')
      expect(prompt).to include('plano_escolhido: Fibra 500')
    end

    it 'descarta valores em branco vindos dos facts' do
      conversation.update!(custom_attributes: {},
                           additional_attributes: { 'ai_collected_facts' => {
                             'nome_cliente' => 'Fulano', 'email_cliente' => '', 'documento_cpf' => nil
                           } })

      prompt = prompt_for
      expect(prompt).to include('nome_cliente: Fulano')
      expect(prompt).not_to include('email_cliente:')
      expect(prompt).not_to include('documento_cpf:')
    end

    it 'não quebra quando additional_attributes é nulo ou sem ai_collected_facts' do
      conversation.update!(custom_attributes: { 'cidade' => 'Maravilha' }, additional_attributes: {})

      prompt = prompt_for
      expect(prompt).to include('cidade: Maravilha')
    end

    it 'omite a linha "Dados já coletados" quando não há nenhum dado' do
      conversation.update!(custom_attributes: {}, additional_attributes: {})
      allow(conversation.contact).to receive(:custom_attributes).and_return({}) if conversation.contact

      prompt = prompt_for
      expect(prompt).not_to include('Dados já coletados do cliente:')
    end
  end
end
