class IntegrationSettingPolicy < ApplicationPolicy
  # Covers ProviderInstancesController#index, which authorizes against this policy.
  def index?
    @account_user.administrator?
  end

  def show?
    @account_user.administrator?
  end

  def update?
    @account_user.administrator?
  end

  # Grava a config GLOBAL (account_id nil), que vale para todas as contas: não é do admin de um cliente.
  def import_from_env?
    @user.is_a?(SuperAdmin)
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

  def destroy?
    @account_user.administrator?
  end
end
