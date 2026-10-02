# Stage automations and AI follow-up cadences of a pipeline (closing flow).
class Api::V1::Accounts::OperationalFlows::PipelineAutomationsController < Api::V1::Accounts::BaseController
  include PlanFeatureEnforceable

  before_action -> { enforce_plan_feature('crm_automations', I18n.t('errors.pipelines.automations_plan_feature')) }
  before_action :check_authorization
  before_action :fetch_flow
  before_action :fetch_automation, only: [:update, :destroy]

  def index
    @automations = @flow.pipeline_automations.order(:resolution_state_id, :sort_order, :id)
  end

  def create
    @automation = @flow.pipeline_automations.create!(automation_params.merge(account_id: Current.account.id))
    render :show
  end

  def update
    @automation.update!(automation_params)
    render :show
  end

  def destroy
    @automation.destroy!
    head :ok
  end

  # "Simular regra": which cards now in the stage would pass the conditions — nothing runs.
  def simulate
    stage = @flow.resolution_states.find(automation_params[:resolution_state_id])
    cards = Current.account.conversations.where(pipeline_stage_id: stage.id).includes(:contact).order(last_activity_at: :desc).limit(500).to_a
    matched = cards.select { |conversation| simulated_match?(conversation) }
    render json: { total: cards.size, matched: matched.size,
                   samples: matched.first(10).map { |conversation| { id: conversation.display_id, name: conversation.contact.name } } }
  end

  private

  def check_authorization
    authorize(PipelineAutomation)
  end

  def fetch_flow
    @flow = Current.account.operational_flows.find(params[:operational_flow_id])
  end

  def fetch_automation
    @automation = @flow.pipeline_automations.find(params[:id])
  end

  def simulated_match?(conversation)
    Pipelines::ConditionEvaluator.new(conversation, automation_params[:conditions], match_type: automation_params[:match_type]).match?
  end

  def automation_params
    params.require(:pipeline_automation).permit(
      :resolution_state_id, :name, :active, :kind, :trigger_type, :delay_minutes, :inactivity_sender, :match_type, :sort_order,
      conditions: [:attribute, :attribute_key, :operator, :value, { value: [] }],
      actions: [:action_name, { action_params: {} }]
    )
  end
end
