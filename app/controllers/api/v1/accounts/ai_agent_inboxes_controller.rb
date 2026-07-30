# Caixas tab (inside the agent "Sobre" section): lists the account's inboxes with the agent's
# binding mode (live/shadow/none) and syncs them. A `live` binding is what puts the AI on the air.
class Api::V1::Accounts::AiAgentInboxesController < Api::V1::Accounts::BaseController
  before_action :set_agent

  def show
    bindings = @agent.agent_inboxes.index_by(&:inbox_id)
    inboxes = Current.account.inboxes.order(:name)
    render json: inboxes.map { |inbox|
      binding = bindings[inbox.id]
      { 'inbox_id' => inbox.id, 'name' => inbox.name, 'channel_type' => inbox.channel_type,
        'mode' => binding&.active ? binding.mode : 'none' }
    }
  end

  # Body: { bindings: [{ inbox_id:, mode: 'live'|'shadow'|'none' }, ...] } — replaces the set.
  # priority NÃO é responsabilidade desta tela (é decisão POR CAIXA entre agentes — ver
  # AiInboxAgentPrioritiesController). sync_binding PRESERVA a priority existente para não zerar o que a
  # tela da caixa gravou.
  def update
    Array(params[:bindings]).each do |raw|
      sync_binding(raw[:inbox_id].to_i, raw[:mode].to_s)
    end
    head :ok
  end

  private

  def set_agent
    @agent = ::Ai::Agent.find_by(id: params[:ai_agent_id], account_id: Current.account.id)
    render(json: { error: 'agente não encontrado' }, status: :not_found) if @agent.nil?
  end

  def sync_binding(inbox_id, mode)
    return unless Current.account.inboxes.exists?(id: inbox_id)

    binding = @agent.agent_inboxes.find_or_initialize_by(inbox_id: inbox_id)
    if ::Ai::AgentInbox::MODES.include?(mode)
      # NÃO toca priority: binding existente mantém o valor gravado pela tela da caixa; binding novo herda
      # o default 1 da coluna (NOT NULL default 1).
      binding.mode = mode
      binding.active = true
      binding.save!
    else
      binding.destroy! if binding.persisted?
    end
  end
end
