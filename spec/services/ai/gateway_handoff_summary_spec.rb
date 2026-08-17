require 'rails_helper'

# Verifica que os 3 gatilhos de handoff AUTOMÁTICO enfileiram o Ai::HandoffSummaryJob com o reason
# certo, end-to-end pelo gateway (o golden master gateway_spec cobre os efeitos; aqui só o enqueue).
RSpec.describe 'Ai::Gateway enfileira resumo de handoff', type: :model do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }

  before do
    account.enable_features!('ai_core')
    allow_any_instance_of(::Inbox).to receive(:available_now?).and_return(true)
    allow(Ai::KnowledgeRetriever).to receive(:retrieve).and_return([])
    allow(Ai::Workers::MediaProcessor).to receive(:process).and_return(nil)
    # update_memory (pós-dispatch) chama o worker Summary via call_model — neutraliza para não fazer
    # chamada real (o foco aqui é só o enqueue do resumo de handoff, não a memória).
    allow(Ai::ModelRouter).to receive(:call_model).and_return({ text: '', tokens_in: 0, tokens_out: 0, status: 'recorded' })
    Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Atendimento', status: 'active',
                           behavior: { 'auto_attendance' => true, 'reply_scope' => 'all' })
    Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'live', active: true)
  end

  def binding
    Ai::AgentInbox.find_by(ai_agent_id: agent.id, inbox_id: inbox.id)
  end

  def run_gateway(content, convo: nil)
    convo ||= create(:conversation, account: account, inbox: inbox, status: 'open')
    message = create(:message, account: account, inbox: inbox, conversation: convo, message_type: 'incoming', content: content)
    Ai::Gateway.new(message: message, agent_inbox: binding, mode: 'live').run
    convo
  end

  def stub_decide(decision)
    allow(Ai::ModelRouter).to receive(:decide).and_return(
      { provider: 'openai', model: 'gpt-4.1-mini', decision: decision,
        tokens_in: 1, tokens_out: 1, cost: 0.0, latency_ms: 1, status: 'recorded' }
    )
  end

  it 'crédito esgotado -> reason credit_exhausted' do
    account.create_ai_credit_balance!(plan_credits: 0, extra_credits: 0)
    stub_decide({ 'decision' => 'reply', 'reply_text' => 'não deveria responder' })

    convo = run_gateway('preciso de ajuda')

    expect(Ai::HandoffSummaryJob).to have_been_enqueued.with(convo.id, 'credit_exhausted')
  end

  it 'handoff nativo (modelo pede transferência) -> reason modelo_pediu_transferencia' do
    stub_decide({ 'decision' => 'handoff', 'reply_text' => 'Vou te transferir 🙂' })

    convo = run_gateway('quero falar com um humano')

    expect(Ai::HandoffSummaryJob).to have_been_enqueued.with(convo.id, 'modelo_pediu_transferencia')
  end

  it 'loop persistente após retry -> reason loop' do
    convo = create(:conversation, account: account, inbox: inbox, status: 'open')
    # Semeia 2 respostas anteriores parafraseadas + incoming entre elas (padrão do gateway_spec anti-loop).
    Ai::Run.create!(account_id: account.id, conversation_id: convo.id, ai_agent_id: agent.id,
                    run_type: 'decision', mode: 'live', status: 'recorded', created_at: 6.minutes.ago,
                    decision: { 'decision' => 'reply', 'reply_text' => 'Você quer contratar internet em Cunha Porá, correto?' })
    create(:message, account: account, inbox: inbox, conversation: convo, message_type: 'incoming', content: 'sim', created_at: 5.minutes.ago)
    Ai::Run.create!(account_id: account.id, conversation_id: convo.id, ai_agent_id: agent.id,
                    run_type: 'decision', mode: 'live', status: 'recorded', created_at: 4.minutes.ago,
                    decision: { 'decision' => 'reply', 'reply_text' => 'Você deseja contratar internet em Cunha Porá, correto?' })
    create(:message, account: account, inbox: inbox, conversation: convo, message_type: 'incoming', content: 'sim', created_at: 3.minutes.ago)

    # As duas decisões seguintes continuam repetindo -> LoopGuard força o handoff.
    allow(Ai::ModelRouter).to receive(:decide).and_return(
      { provider: 'openai', model: 'gpt-4.1-mini', decision: { 'decision' => 'reply', 'reply_text' => 'Você está interessado em contratar internet em Cunha Porá, correto?' },
        tokens_in: 1, tokens_out: 1, cost: 0.0, latency_ms: 1, status: 'recorded' }
    )

    run_gateway('sim', convo: convo)

    expect(Ai::HandoffSummaryJob).to have_been_enqueued.with(convo.id, 'loop')
  end
end
