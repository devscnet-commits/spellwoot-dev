class TeamInboxPolicy < ApplicationPolicy
  def index?
    true
  end

  def update?
    @account_user.administrator?
  end
end
