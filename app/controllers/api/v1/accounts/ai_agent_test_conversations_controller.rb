# Aba "Teste" (ícone de laboratório): simula uma conversa REAL com o agente, rodando o MESMO
# Ai::Gateway que atende clientes de verdade — substitui o Ai::Tester antigo, que rodava o motor
# Ruby legado (Ai::ModelRouter.decide direto) e por isso não refletia etapas/ferramentas/avanço nem
# os gates de reply_scope/auto_attendance/horário do motor Python real de hoje.
#
# Isolamento: uma inbox Channel::Api dedicada por conta ("Teste de Agentes IA"). Um canal API não
# tem provedor externo — nenhuma mensagem sai de verdade, sem risco de vazar pro WhatsApp real.
#
# O binding do agente a essa inbox nasce com active: false DE PROPÓSITO: Ai::GatewayListener só
# enfileira Ai::GatewayRunJob (em background) quando existe algum binding active nessa inbox — com
# ele inativo, criar a mensagem de teste NUNCA dispara o job; #create_message chama Ai::Gateway
# diretamente e síncrono, então a resposta já vem pronta na mesma request (Ai::Gateway em si não
# olha pra active, só quem enfileira o job olha).
class Api::V1::Accounts::AiAgentTestConversationsController < Api::V1::Accounts::BaseController
  before_action :set_agent

  TEST_INBOX_NAME = 'Teste de Agentes IA'.freeze

  def show
    conversation = current_test_conversation
    render json: { conversation_id: conversation&.id, messages: serialize_messages(conversation) }
  end

  def reset
    conversation = create_test_conversation!
    render json: { conversation_id: conversation.id, messages: [] }
  end

  def create_message
    content = params[:content].to_s.strip
    return render(json: { error: 'mensagem vazia' }, status: :unprocessable_entity) if content.blank?

    conversation = current_test_conversation || create_test_conversation!
    message = conversation.messages.create!(account: Current.account, inbox: conversation.inbox,
                                            message_type: :incoming, content: content)
    ::Ai::Gateway.new(message: message, agent_inbox: test_binding, mode: 'live').run

    render json: { conversation_id: conversation.id, messages: serialize_messages(conversation.reload) }
  end

  private

  def set_agent
    @agent = ::Ai::Agent.find_by(id: params[:ai_agent_id], account_id: Current.account.id)
    render(json: { error: 'agente não encontrado' }, status: :not_found) if @agent.nil?
  end

  def current_test_conversation
    test_inbox.conversations.where("additional_attributes->>'ai_test_agent_id' = ?", @agent.id.to_s)
              .order(id: :desc).first
  end

  # Reset cria um CONTATO novo (não só uma conversa nova): Ai::StateManager grava "Memória do
  # cliente" por contato, cross-conversa — reusar o mesmo contato entre resets vazaria memória de
  # um teste pro próximo.
  def create_test_conversation!
    contact = Current.account.contacts.create!(name: "Teste — #{@agent.name}")
    contact_inbox = ::ContactInbox.create!(contact: contact, inbox: test_inbox, source_id: SecureRandom.uuid)
    Current.account.conversations.create!(
      inbox: test_inbox, contact: contact, contact_inbox: contact_inbox, status: 'open',
      additional_attributes: { 'ai_test_agent_id' => @agent.id }
    )
  end

  def test_inbox
    @test_inbox ||= Current.account.inboxes.find_by(name: TEST_INBOX_NAME) ||
                    Current.account.inboxes.create!(name: TEST_INBOX_NAME,
                                                     channel: ::Channel::Api.create!(account_id: Current.account.id))
  end

  def test_binding
    @test_binding ||= ::Ai::AgentInbox.find_or_create_by!(ai_agent_id: @agent.id, inbox_id: test_inbox.id) do |b|
      b.mode = 'live'
      b.active = false
    end
  end

  def serialize_messages(conversation)
    return [] if conversation.nil?

    conversation.messages.order(:created_at, :id).map do |m|
      { 'id' => m.id, 'content' => m.content, 'message_type' => m.message_type, 'private' => m.private?,
        'created_at' => m.created_at }
    end
  end
end
