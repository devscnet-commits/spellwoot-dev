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
    render json: { conversation_id: conversation&.id, messages: serialize_messages(conversation),
                  usage_total: serialize_usage_total(conversation) }
  end

  def reset
    conversation = create_test_conversation!
    render json: { conversation_id: conversation.id, messages: [], usage_total: serialize_usage_total(conversation) }
  end

  # Custo/tokens reais (achado ao vivo, 21/08): o Teste roda o Ai::Gateway REAL — cada turno já cria
  # um Ai::Run de verdade (mesmo tokens_in/tokens_out/cost que "Custos de IA" lê), só não aparecia na
  # tela. Marca o maior id ANTES de rodar e busca o(s) Ai::Run criado(s) DEPOIS dele para este
  # conversation_id — evita precisar de uma coluna nova (message_id) em ai_runs só pra linkar; o Teste
  # não manda anexo (sem UI de upload aqui), então skip_vision:true no Gateway garante 0 Ai::Run extra
  # de visão por turno — sempre exatamente 1 run por mensagem enviada.
  def create_message
    content = params[:content].to_s.strip
    return render(json: { error: 'mensagem vazia' }, status: :unprocessable_entity) if content.blank?

    conversation = current_test_conversation || create_test_conversation!
    message = conversation.messages.create!(account: Current.account, inbox: conversation.inbox,
                                            message_type: :incoming, content: content)
    last_run_id = ::Ai::Run.maximum(:id) || 0
    ::Ai::Gateway.new(message: message, agent_inbox: test_binding, mode: 'live').run
    turn_run = ::Ai::Run.where(conversation_id: conversation.id).where('id > ?', last_run_id).order(:id).first

    render json: {
      conversation_id: conversation.id,
      messages: serialize_messages(conversation.reload),
      usage: serialize_usage(turn_run),
      usage_total: serialize_usage_total(conversation)
    }
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

  def serialize_usage(run)
    return nil if run.nil?

    { 'tokens_in' => run.tokens_in, 'tokens_out' => run.tokens_out, 'cost' => run.cost.to_f.round(6) }
  end

  # Total acumulado da SESSÃO de teste atual (soma de todos os Ai::Run desta conversation_id) — cada
  # "Reiniciar teste" cria uma conversa nova (#create_test_conversation!), então o total sempre
  # reflete só a sessão em aberto, nunca acumula com testes anteriores já reiniciados. Mesmo
  # arredondamento de Api::V1::Accounts::AiCostsController (6 casas).
  def serialize_usage_total(conversation)
    return { 'tokens_in' => 0, 'tokens_out' => 0, 'cost' => 0.0 } if conversation.nil?

    runs = ::Ai::Run.where(conversation_id: conversation.id)
    { 'tokens_in' => runs.sum(:tokens_in), 'tokens_out' => runs.sum(:tokens_out), 'cost' => runs.sum(:cost).to_f.round(6) }
  end
end
