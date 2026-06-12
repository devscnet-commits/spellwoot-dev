class IntegrationSettingPolicy < ApplicationPolicy
  def show?
    @account_user.administrator?
  end

  def update?
    @account_user.administrator?
  end

  def import_from_env?
    @account_user.administrator?
  end

  def test_connection?
    @account_user.administrator?
  end

  def sync_chatwoot?
    @account_user.administrator?
  end

  def sync_instances?
    @account_user.administrator?
  end
end
