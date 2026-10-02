# Quick actions on a kanban card (:id is the conversation display_id): lead temperature and the
# manual "Follow-up IA".
class Api::V1::Accounts::PipelineCardsController < Api::V1::Accounts::BaseController
  include PlanFeatureEnforceable

  before_action -> { enforce_plan_feature('crm_kanban', I18n.t('errors.pipelines.plan_feature')) }
  before_action :fetch_conversation

  def update
    @conversation.update!(temperature: params[:temperature].presence)
    head :ok
  end

  # Uses the agent/prompt given, else the first AI follow-up step of the card's stage, else the AI
  # agent attending the inbox live. Generation runs in the background.
  def ai_followup
    agent, prompt = followup_agent_and_prompt
    return render json: { error: I18n.t('errors.pipelines.no_ai_agent') }, status: :unprocessable_entity if agent.nil?

    Pipelines::AiFollowupJob.perform_later(@conversation.id, agent.id, prompt, Current.user.id)
    head :accepted
  end

  private

  def fetch_conversation
    @conversation = Current.account.conversations.find_by!(display_id: params[:id])
    authorize @conversation, :show?
  end

  def followup_agent_and_prompt
    return [account_agents.find_by(id: params[:ai_agent_id]), params[:prompt]] if params[:ai_agent_id].present?

    action = stage_followup_action
    return [account_agents.find_by(id: action.dig('action_params', 'ai_agent_id')), action.dig('action_params', 'prompt')] if action

    [inbox_agent, nil]
  end

  def stage_followup_action
    step = PipelineAutomation.active.where(resolution_state_id: @conversation.pipeline_stage_id, kind: 'ai_followup')
                             .order(:sort_order, :id).first
    step && Array(step.actions).find { |item| item['action_name'] == 'ai_followup' }
  end

  def inbox_agent
    Ai::AgentInbox.live.includes(:agent).where(inbox_id: @conversation.inbox_id).min_by { |item| [item.priority.to_i, item.id] }&.agent
  end

  def account_agents
    Ai::Agent.where(account_id: Current.account.id, status: 'active')
  end
end
