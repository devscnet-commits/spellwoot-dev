require 'rails_helper'

# FIX 3d — Camada 0 no Ai::Gateway: com o gate LIGADO, um turno trivial encerra ANTES do modelo
# (Ai::Run 'trivial_skip', custo zero, evento turn.trivial_skipped, nenhuma resposta ao cliente). Com
# o gate DESLIGADO (default), o fluxo é byte-idêntico ao atual (o modelo é chamado).
#
# Rodar:  docker compose exec rails bundle exec rspec spec/services/ai/gateway_trivial_gate_spec.rb
RSpec.describe Ai::Gateway do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:agent) do
    Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id)
  end

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

  def stub_decision(decision)
    allow(Ai::ModelRouter).to receive(:decide).and_return(
      { provider: 'openai', model: 'gpt-4.1-mini', decision: decision,
        tokens_in: 10, tokens_out: 5, cost: 0.02, latency_ms: 1, status: 'recorded' }
    )
  end

  # Conversa onde NÓS falamos por último (outgoing), depois o cliente manda o turno trivial.
  def deliver_after_our_reply(text, binding:)
    convo = create(:conversation, account: account, inbox: inbox, status: 'open')
    create(:message, account: account, inbox: inbox, conversation: convo,
                     message_type: 'outgoing', content: 'Prontinho, tudo certo! 😊')
    message = create(:message, account: account, inbox: inbox, conversation: convo,
                              message_type: 'incoming', content: text)
    described_class.new(message: message, agent_inbox: binding, mode: binding.mode).run
    convo.reload
  end

  def events(convo)
    Ai::Event.where(conversation_id: convo.id).order(:id).pluck(:event_type)
  end

  context 'gate LIGADO (worker_overrides trivial_gate mode=on)' do
    let(:profile) do
      Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                   supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini',
                                   worker_overrides: { 'trivial_gate' => { 'mode' => 'on' } })
    end

    it 'turno trivial NÃO chama o modelo: cria Ai::Run trivial_skip (custo zero), emite evento e não responde' do
      create_department
      binding = create_binding(mode: 'live')
      allow(Ai::ModelRouter).to receive(:decide) # espião: não deve ser chamado

      convo = deliver_after_our_reply('Obrigada!!', binding: binding)

      expect(Ai::ModelRouter).not_to have_received(:decide)
      expect(events(convo)).to eq(%w[message.received department.resolved turn.trivial_skipped])

      run = Ai::Run.find_by(conversation_id: convo.id)
      expect(run.run_type).to eq('trivial_skip')
      expect(run.status).to eq('recorded')
      expect(run.cost).to eq(0)
      expect(run.tokens_in).to eq(0)
      expect(run.tokens_out).to eq(0)

      skipped = Ai::Event.find_by(conversation_id: convo.id, event_type: 'turn.trivial_skipped')
      expect(skipped.payload['reason']).to eq('closed_list')

      # Silêncio v1: só a nossa mensagem-semente segue lá; nada de novo foi enviado.
      expect(convo.messages.outgoing.count).to eq(1)
    end

    it 'turno NÃO-trivial ("preciso de ajuda") segue o fluxo normal e chama o modelo' do
      create_department
      binding = create_binding(mode: 'live')
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'Claro!' })

      convo = deliver_after_our_reply('Preciso de ajuda com o boleto', binding: binding)

      expect(Ai::ModelRouter).to have_received(:decide)
      expect(Ai::Run.find_by(conversation_id: convo.id).run_type).to eq('decision')
      expect(convo.messages.outgoing.last.content).to eq('Claro!')
    end

    # CONV 412 end-to-end: com o gate LIGADO, "ok" logo após uma PERGUNTA da IA (ai_last_asked_slot
    # presente) NÃO é descartado — o modelo é chamado e o cliente é respondido. É o argumento de que,
    # depois deste conserto, LIGAR o gate deixa de travar conversa ativa.
    it 'CONV 412: "ok" após pergunta pendente (ai_last_asked_slot) NÃO pula — chama o modelo' do
      create_department
      binding = create_binding(mode: 'live')
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'Perfeito, finalizando! 😊' })

      convo = create(:conversation, account: account, inbox: inbox, status: 'open')
      convo.update!(additional_attributes: { 'ai_last_asked_slot' => 'confirma_finalizacao' })
      create(:message, account: account, inbox: inbox, conversation: convo,
                       message_type: 'outgoing', content: 'Vou finalizar seu pré-cadastro, tudo bem?')
      message = create(:message, account: account, inbox: inbox, conversation: convo,
                                 message_type: 'incoming', content: 'ok')
      described_class.new(message: message, agent_inbox: binding, mode: binding.mode).run
      convo.reload

      expect(Ai::ModelRouter).to have_received(:decide)
      expect(events(convo)).not_to include('turn.trivial_skipped')
      expect(Ai::Run.find_by(conversation_id: convo.id).run_type).to eq('decision')
    end
  end

  context 'gate DESLIGADO (default — sem worker_overrides)' do
    let(:profile) do
      Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                   supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
    end

    it 'turno trivial segue o fluxo atual: chama o modelo, nenhum trivial_skip' do
      create_department
      binding = create_binding(mode: 'live')
      stub_decision({ 'decision' => 'reply', 'reply_text' => 'De nada! 😊' })

      convo = deliver_after_our_reply('Obrigada!!', binding: binding)

      expect(Ai::ModelRouter).to have_received(:decide)
      expect(events(convo)).not_to include('turn.trivial_skipped')
      expect(Ai::Run.find_by(conversation_id: convo.id).run_type).to eq('decision')
    end
  end
end
