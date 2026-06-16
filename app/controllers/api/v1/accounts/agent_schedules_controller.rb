class Api::V1::Accounts::AgentSchedulesController < Api::V1::Accounts::BaseController
  before_action :check_authorization
  before_action :fetch_agent

  def show
    render json: {
      agent_id: @agent.id,
      uses_default: @agent.default_schedule?,
      schedule: @agent.weekly_agent_schedule
    }
  end

  def update
    @agent.update_agent_schedule(schedule_params)
    render json: {
      agent_id: @agent.id,
      uses_default: @agent.default_schedule?,
      schedule: @agent.weekly_agent_schedule
    }
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def destroy
    @agent.agent_schedules.destroy_all
    head :ok
  end

  private

  def fetch_agent
    @agent = Current.account.users.find(params[:agent_id])
  end

  def schedule_params
    params.require(:schedule).map do |slot|
      slot.permit(*AgentSchedule::SCHEDULE_ATTRS)
    end
  end
end
