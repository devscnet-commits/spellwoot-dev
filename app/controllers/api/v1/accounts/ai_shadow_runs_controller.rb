# Read-only observation of AI Core shadow runs (validation of the F1 vertical slice).
# Returns a flat summary per run so the minimal UI is trivial. No mutations.
# Uses ::Ai::* (top-level) explicitly to avoid colliding with this controller's namespace.
class Api::V1::Accounts::AiShadowRunsController < Api::V1::Accounts::BaseController
  def index
    runs = ::Ai::Run.where(account_id: Current.account.id)
    runs = runs.where(conversation_id: params[:conversation_id]) if params[:conversation_id].present?
    runs = runs.order(created_at: :desc).limit(100)
    render json: runs.map { |run| summarize(run) }
  end

  private

  def summarize(run)
    events = ::Ai::Event.where(conversation_id: run.conversation_id)
                        .where(created_at: run.created_at..(run.updated_at + 2.seconds))
    dept = event_payload(events, 'department.resolved')
    knowledge = event_payload(events, 'knowledge.retrieved')
    tool = event_payload(events, 'tool.intended')

    {
      id: run.id,
      conversation_id: run.conversation_id,
      agent_id: run.ai_agent_id,
      department: dept&.dig('name'),
      knowledge_count: knowledge&.dig('count'),
      reply_text: run.decision['reply_text'],
      tool: tool&.dig('tool'),
      provider: run.provider,
      model: run.model,
      cost: run.cost,
      latency_ms: run.latency_ms,
      status: run.status,
      mode: run.mode,
      created_at: run.created_at
    }
  end

  def event_payload(events, type)
    events.find { |event| event.event_type == type }&.payload
  end
end
