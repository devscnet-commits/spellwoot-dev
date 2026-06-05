class Api::V1::Accounts::TeamMembersController < Api::V1::Accounts::BaseController
  before_action :fetch_team
  before_action :check_authorization
  before_action :validate_member_id_params, only: [:create, :update, :destroy]

  def index
    @team_members = @team.team_members.includes(:user)
  end

  def create
    added_ids = members_to_be_added_ids
    ActiveRecord::Base.transaction do
      @team.add_members(added_ids)
    end
    @team_members = @team.team_members.includes(:user).where(user_id: added_ids)
    render action: 'index'
  end

  def update
    ActiveRecord::Base.transaction do
      if params[:members].present?
        @team.sync_members_with_roles(parsed_members_with_roles)
      else
        @team.add_members(members_to_be_added_ids)
        @team.remove_members(members_to_be_removed_ids)
      end
    end
    @team_members = @team.team_members.includes(:user)
    render action: 'index'
  end

  def update_member_role
    user_id = params[:user_id].to_i
    role    = params[:role].to_s

    unless TeamMember.roles.key?(role)
      return render json: { error: 'Invalid role' }, status: :unprocessable_entity
    end

    tm = @team.team_members.find_by(user_id: user_id)
    return render json: { error: 'Member not found' }, status: :not_found unless tm

    tm.update!(role: role)
    render json: { user_id: user_id, team_role: role }, status: :ok
  end

  def destroy
    ActiveRecord::Base.transaction do
      @team.remove_members(params[:user_ids])
    end
    head :ok
  end

  private

  def members_to_be_added_ids
    params[:user_ids].map(&:to_i) - current_members_ids
  end

  def members_to_be_removed_ids
    current_members_ids - params[:user_ids].map(&:to_i)
  end

  def current_members_ids
    @current_members_ids ||= @team.members.pluck(:id)
  end

  def parsed_members_with_roles
    params[:members].map do |m|
      { user_id: m[:user_id].to_i, role: m[:role].to_s.presence || 'member' }
    end
  end

  def fetch_team
    @team = Current.account.teams.find(params[:team_id])
  end

  def validate_member_id_params
    ids = if params[:members].present?
            params[:members].map { |m| m[:user_id].to_i }
          else
            params[:user_ids].to_a.map(&:to_i)
          end

    invalid_ids = ids - @team.account.user_ids
    render json: { error: 'Invalid User IDs' }, status: :unauthorized if invalid_ids.present?
  end
end
