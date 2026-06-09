class Api::V1::Accounts::InboxMembersController < Api::V1::Accounts::BaseController
  before_action :fetch_inbox
  before_action :current_agents_ids, only: [:create, :update]

  def show
    authorize @inbox, :show?
    fetch_updated_members
  end

  def create
    authorize @inbox, :create?
    ActiveRecord::Base.transaction do
      @inbox.add_members(agents_to_be_added_ids)
    end
    fetch_updated_members
  end

  def update
    authorize @inbox, :update?
    if params[:members].present?
      update_members_with_eligibility
    else
      update_agents_list
    end
    fetch_updated_members
  end

  def destroy
    authorize @inbox, :destroy?
    ActiveRecord::Base.transaction do
      @inbox.remove_members(params[:user_ids])
    end
    head :ok
  end

  private

  def fetch_updated_members
    @inbox_members = @inbox.inbox_members.includes(:user).order(:created_at)
  end

  def update_agents_list
    ActiveRecord::Base.transaction do
      @inbox.add_members(agents_to_be_added_ids)
      @inbox.remove_members(agents_to_be_removed_ids)
    end
  end

  def update_members_with_eligibility
    member_data = permitted_member_params
    new_user_ids = member_data.map { |m| m[:user_id].to_i }
    current_ids = @inbox.inbox_members.pluck(:user_id)

    ActiveRecord::Base.transaction do
      ids_to_remove = current_ids - new_user_ids
      @inbox.remove_members(ids_to_remove) if ids_to_remove.any?

      ids_to_add = new_user_ids - current_ids
      ids_to_add.each do |uid|
        config = member_data.find { |m| m[:user_id].to_i == uid }
        eligible = config[:eligible_for_assignment] != false
        @inbox.inbox_members.create!(user_id: uid, eligible_for_assignment: eligible)
      end

      (new_user_ids & current_ids).each do |uid|
        config = member_data.find { |m| m[:user_id].to_i == uid }
        eligible = config[:eligible_for_assignment] != false
        @inbox.inbox_members.find_by(user_id: uid)&.update!(eligible_for_assignment: eligible)
      end

      @inbox.update_account_cache
    end
  end

  def permitted_member_params
    params.require(:members).map { |m| m.permit(:user_id, :eligible_for_assignment) }
  end

  def agents_to_be_added_ids
    params[:user_ids] - @current_agents_ids
  end

  def agents_to_be_removed_ids
    @current_agents_ids - params[:user_ids]
  end

  def current_agents_ids
    @current_agents_ids = @inbox.members.pluck(:id)
  end

  def fetch_inbox
    @inbox = Current.account.inboxes.find(params[:inbox_id])
  end
end
