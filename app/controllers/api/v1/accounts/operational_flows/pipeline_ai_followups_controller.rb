# The AI follow-up cadence of each stage of a pipeline (closing flow): one record per stage.
class Api::V1::Accounts::OperationalFlows::PipelineAiFollowupsController < Api::V1::Accounts::BaseController
  include PlanFeatureEnforceable

  before_action -> { enforce_plan_feature('crm_automations', I18n.t('errors.pipelines.automations_plan_feature')) }
  before_action :check_authorization
  before_action :fetch_flow
  before_action :fetch_cadence, only: [:update, :destroy]

  def index
    @cadences = @flow.ai_followups.order(:resolution_state_id)
  end

  def create
    @cadence = @flow.ai_followups.create!(cadence_params.merge(account_id: Current.account.id))
    render :show
  end

  def update
    @cadence.update!(cadence_params)
    render :show
  end

  def destroy
    @cadence.destroy!
    head :ok
  end

  private

  def check_authorization
    authorize(PipelineAutomation)
  end

  def fetch_flow
    @flow = Current.account.operational_flows.find(params[:operational_flow_id])
  end

  def fetch_cadence
    @cadence = @flow.ai_followups.find(params[:id])
  end

  def cadence_params
    params.require(:pipeline_ai_followup).permit(
      :resolution_state_id, :active, :inactivity_minutes, :close_message,
      behaviors: [:context, :no_response_action, :no_response_stage_id,
                  { windows: [:start, :end], attempts: [:name, :active, :delay_minutes, :inactivity_sender, :ai_agent_id, :prompt] }]
    )
  end
end
