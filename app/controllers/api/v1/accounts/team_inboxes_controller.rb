class Api::V1::Accounts::TeamInboxesController < Api::V1::Accounts::BaseController
  before_action :fetch_team
  before_action :check_authorization

  def index
    @inboxes = @team.inboxes
  end

  # Replaces the full set of inboxes linked to the team.
  def update
    requested_ids = Array(params[:inbox_ids]).map(&:to_i)
    valid_ids = Current.account.inboxes.where(id: requested_ids).pluck(:id)
    @team.inbox_ids = valid_ids
    @inboxes = @team.inboxes.reload
    render :index
  end

  private

  def fetch_team
    @team = Current.account.teams.find(params[:team_id])
  end
end
