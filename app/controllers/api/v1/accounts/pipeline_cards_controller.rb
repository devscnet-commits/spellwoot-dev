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

  # Uses the agent/prompt given, else the first attempt of the stage's AI follow-up cadence, else the
  # AI agent attending the inbox live. Generation runs in the background.
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

    attempt = PipelineAiFollowup.active.find_by(resolution_state_id: @conversation.pipeline_stage_id)&.first_attempt
    return [account_agents.find_by(id: attempt[:ai_agent_id]), attempt[:prompt]] if attempt

    [inbox_agent, nil]
  end

  def inbox_agent
    Ai::AgentInbox.live.includes(:agent).where(inbox_id: @conversation.inbox_id).min_by { |item| [item.priority.to_i, item.id] }&.agent
  end

  def account_agents
    Ai::Agent.where(account_id: Current.account.id, status: 'active')
  end
end
