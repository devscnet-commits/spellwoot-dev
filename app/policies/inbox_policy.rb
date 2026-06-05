class InboxPolicy < ApplicationPolicy
  class Scope
    attr_reader :user_context, :user, :scope, :account, :account_user

    def initialize(user_context, scope)
      @user_context = user_context
      @user = user_context[:user]
      @account = user_context[:account]
      @account_user = user_context[:account_user]
      @scope = scope
    end

    def resolve
      user.assigned_inboxes
    end
  end

  def index?
    true
  end

  def show?
    # FIXME: for agent bots, lets bring this validation to policies as well in future
    return true if @user.is_a?(AgentBot)
    return true if Current.user&.administrator?

  def migrate?
      Current.user&.administrator?
    end  

    Current.user.assigned_inboxes.include? record
  end

  def assignable_agents?
    true
  end

  def agent_bot?
    true
  end

  def campaigns?
    admin?
  end

  def create?
    admin?
  end

  def update?
    admin?
  end

  def destroy?
    admin?
  end

  def set_agent_bot?
    admin?
  end

  def avatar?
    admin?
  end

  def sync_templates?
    admin?
  end

  def health?
    admin?
  end

  def uazapi_status?
    admin?
  end

  def uazapi_connect?
    admin?
  end

  def uazapi_disconnect?
    admin?
  end

  def uazapi_reconfigure?
    admin?
  end

  def replicate_business_hours?
    admin?
  end

  private

  def admin?
    Current.user&.administrator? || @account_user&.administrator?
  end
end
