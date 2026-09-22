# Conectores externos guardam credencial em `auth` e `headers`, e o index serializa o registro
# inteiro. Sem autorização, qualquer agente ativo da conta lia o bearer token do ERP do cliente —
# a Api::V1::Accounts::BaseController só resolve a conta e checa se o agente está ativo, não
# autoriza nada. As 7 rotas de IA já são administrator no front (ai.routes.js), então isto alinha o
# servidor com a intenção que o produto já declarava.
class Ai::IntegrationLinkPolicy < ApplicationPolicy
  def index?
    @account_user.administrator?
  end

  def create?
    @account_user.administrator?
  end

  def update?
    @account_user.administrator?
  end

  def destroy?
    @account_user.administrator?
  end

  def test?
    @account_user.administrator?
  end
end
