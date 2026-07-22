require 'rails_helper'

# Fix 3b — split decisão/resposta. OFF (default) = fluxo único intocado (golden master cobre isso no
# gateway_spec). Aqui cobrimos o modo ON: duas fases, dois Ai::Run, temperaturas, shadow e fallback.
# O LLM é isolado stubando Ai::ModelRouter.decide (Fase A/fallback) e .generate_text (Fase B).
RSpec.describe Ai::Gateway do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado', supervisor_provider: 'openai',
                                 supervisor_model: 'gpt-4.1-mini',
                                 worker_overrides: { 'split_decision_reply' => { 'mode' => 'on' } })
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }

  before do
    account.enable_features!('ai_core')
    allow_any_instance_of(::Inbox).to receive(:available_now?).and_return(true)
    allow(Ai::KnowledgeRetriever).to receive(:retrieve).and_return([])
    allow(Ai::Workers::MediaProcessor).to receive(:process).and_return(nil)
    allow(Ai::Workers::Summary).to receive(:generate).and_return(nil)
  end

  def create_department
    Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Atendimento', status: 'active',
                           behavior: { 'auto_attendance' => true, 'reply_scope' => 'all' })
  end

  def create_binding(mode:)
    Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: mode, active: true)
  end

  def fase_a_result(decision, status: 'recorded')
    { provider: 'openai', model: 'gpt-4.1-mini', decision: decision, tokens_in: 100, tokens_out: 20,
      cached_tokens: 0, cost: 0.01, latency_ms: 5, temperature: 0.2, status: status }
  end

  def fase_b_result(text, status: 'recorded')
    { provider: 'openai', model: 'gpt-4.1-mini', temperature: 0.7, text: text, tokens_in: 200, tokens_out: 50,
      cached_tokens: 0, cost: 0.02, latency_ms: 5, status: status }
  end

  def deliver(content, binding:, mode:)
    convo = create(:conversation, account: account, inbox: inbox, status: 'open')
    message = create(:message, account: account, inbox: inbox, conversation: convo, message_type: 'incoming', content: content)
    described_class.new(message: message, agent_inbox: binding, mode: mode).run
    convo.reload
  end

  describe 'ON + live: duas fases' do
    it 'reply: cria Ai::Run decision E reply, e envia o texto da Fase B' do
      binding = create_binding(mode: 'live')
      create_department
      allow(Ai::ModelRouter).to receive(:decide).and_return(fase_a_result('decision' => 'reply', 'attributes' => {}))
      allow(Ai::ModelRouter).to receive(:generate_text).and_return(fase_b_result('Olá! Como posso ajudar?'))

      convo = deliver('oi', binding: binding, mode: 'live')

      expect(Ai::Run.where(conversation_id: convo.id).pluck(:run_type)).to include('decision', 'reply')
      expect(convo.messages.outgoing.last.content).to eq('Olá! Como posso ajudar?')
    end

    it 'Fase A sai com temperatura 0.2 e schema SEM reply_text; Fase B usa o slider (temperature nil)' do
      binding = create_binding(mode: 'live')
      create_department
      expect(Ai::ModelRouter).to receive(:decide)
        .with(hash_including(temperature: 0.2, schema: Ai::DecisionSchema.without_reply_text))
        .and_return(fase_a_result('decision' => 'reply', 'attributes' => {}))
      expect(Ai::ModelRouter).to receive(:generate_text)
        .with(hash_including(temperature: nil)).and_return(fase_b_result('resposta'))

      deliver('oi', binding: binding, mode: 'live')
    end

    it 'anexa as tools NATIVAS de leitura na Fase A' do
      binding = create_binding(mode: 'live')
      create_department
      allow(Ai::ModelRouter).to receive(:generate_text).and_return(fase_b_result('ok'))
      expect(Ai::ModelRouter).to receive(:decide) do |kwargs|
        names = Array(kwargs[:tools]).map(&:name)
        expect(names).to include('lista_catalogo', 'busca_conhecimento')
        fase_a_result('decision' => 'reply', 'attributes' => {})
      end

      deliver('quais os planos?', binding: binding, mode: 'live')
    end
  end

  describe 'shadow' do
    it 'NUNCA faz split (sem run reply, sem generate_text) — cai no fluxo único' do
      binding = create_binding(mode: 'shadow')
      create_department
      allow(Ai::ModelRouter).to receive(:decide).and_return(fase_a_result('decision' => 'reply', 'reply_text' => 'oi', 'attributes' => {}))
      expect(Ai::ModelRouter).not_to receive(:generate_text)

      convo = deliver('oi', binding: binding, mode: 'shadow')

      expect(Ai::Run.where(conversation_id: convo.id, run_type: 'reply')).to be_empty
    end
  end

  describe 'fallback' do
    it 'Fase A falha -> evento split.fallback + fluxo único (envelope com reply_text)' do
      binding = create_binding(mode: 'live')
      create_department
      allow(Ai::ModelRouter).to receive(:decide).and_return(
        fase_a_result({ 'error' => 'boom' }, status: 'error'),                                   # Fase A falha
        fase_a_result('decision' => 'reply', 'reply_text' => 'fallback ok', 'attributes' => {})  # fluxo único
      )

      convo = deliver('oi', binding: binding, mode: 'live')

      expect(Ai::Event.where(conversation_id: convo.id, event_type: 'split.fallback')).to be_present
      expect(convo.messages.outgoing.last.content).to eq('fallback ok')
    end

    it 'Fase B vazia -> reply seguro do playbook (nunca vaza JSON)' do
      binding = create_binding(mode: 'live')
      create_department
      allow(Ai::ModelRouter).to receive(:decide).and_return(fase_a_result('decision' => 'reply', 'attributes' => {}))
      allow(Ai::ModelRouter).to receive(:generate_text).and_return(fase_b_result('', status: 'error'))

      convo = deliver('oi', binding: binding, mode: 'live')

      last = convo.messages.outgoing.last.content
      expect(last).to be_present
      expect(last).not_to include('{')
    end
  end
end
