# Prioridade de eleição das IAs NESTA caixa — a decisão é DA CAIXA, entre agentes (não da tela de um
# agente). Quando >1 IA atende a mesma caixa, o Gateway elege UMA por [priority ASC, id ASC]
# (Ai::GatewayRunJob). Aqui todos os concorrentes daquela caixa aparecem lado a lado e a ordem é editável
# de uma vez — e o empate (>=2 no menor priority) fica visível. priority é por (agente, caixa).
class Api::V1::Accounts::AiInboxAgentPrioritiesController < Api::V1::Accounts::BaseController
  before_action :set_inbox

  # Lista os agentes que atendem esta caixa (binding ativo), com priority + mode + nome. Ordena por
  # [priority ASC, id ASC] — a MESMA ordem da eleição, para a leitura bater com o comportamento.
  def show
    render json: attending_bindings.map { |b| serialize(b) }
  end

  # Body: { priorities: [{ agent_id:, priority: }, ...] } — grava o priority de cada binding DESTA caixa.
  # Só toca priority (não mexe em mode/active). Ignora agent_id que não tem binding aqui.
  def update
    by_agent = attending_bindings.index_by(&:ai_agent_id)
    Array(params[:priorities]).each do |raw|
      binding = by_agent[raw[:agent_id].to_i]
      binding&.update!(priority: sanitize_priority(raw[:priority]))
    end
    head :ok
  end

  private

  def set_inbox
    @inbox = Current.account.inboxes.find_by(id: params[:inbox_id])
    render(json: { error: 'caixa não encontrada' }, status: :not_found) if @inbox.nil?
  end

  # Bindings ativos desta caixa cujo agente é da conta. Ordenados como a eleição ([priority, id]).
  def attending_bindings
    ::Ai::AgentInbox.where(inbox_id: @inbox.id, active: true)
                    .includes(:agent)
                    .select { |b| b.agent && b.agent.account_id == Current.account.id }
                    .sort_by { |b| [b.priority.to_i, b.id] }
  end

  def serialize(binding)
    { 'agent_id' => binding.ai_agent_id,
      'agent_name' => binding.agent.assistant_name.presence || binding.agent.name,
      'mode' => binding.mode,
      'priority' => binding.priority }
  end

  # priority é inteiro >= 1 (default 1). Blank/lixo/menor que 1 cai no default (coluna NOT NULL default 1).
  def sanitize_priority(priority)
    [priority.to_i, 1].max
  end
end
