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
        'mode' => binding&.active ? binding.mode : 'none',
        # priority sempre presente (default 1 quando não há binding): a eleição usa [priority ASC, id ASC];
        # sem devolver o valor ele nunca é editável e a eleição cai no desempate por id.
        'priority' => binding&.priority || 1 }
    }
  end

  # Body: { bindings: [{ inbox_id:, mode: 'live'|'shadow'|'none', priority: 1 }, ...] } — replaces the set.
  def update
    Array(params[:bindings]).each do |raw|
      sync_binding(raw[:inbox_id].to_i, raw[:mode].to_s, raw[:priority])
    end
    head :ok
  end

  private

  def set_agent
    @agent = ::Ai::Agent.find_by(id: params[:ai_agent_id], account_id: Current.account.id)
    render(json: { error: 'agente não encontrado' }, status: :not_found) if @agent.nil?
  end

  def sync_binding(inbox_id, mode, priority = nil)
    return unless Current.account.inboxes.exists?(id: inbox_id)

    binding = @agent.agent_inboxes.find_or_initialize_by(inbox_id: inbox_id)
    if ::Ai::AgentInbox::MODES.include?(mode)
      binding.update!(mode: mode, active: true, priority: sanitize_priority(priority))
    else
      binding.destroy! if binding.persisted?
    end
  end

  # priority é inteiro >= 1 (default 1). Blank/lixo/menor que 1 cai no default — a coluna é NOT NULL default 1.
  def sanitize_priority(priority)
    [priority.to_i, 1].max
  end
end
