# Troca a Subscription ativa de uma conta para outro plano comercial (upgrade self-service pelo
# cliente, ou upgrade/downgrade feito pelo suporte via Super Admin). Cria a assinatura nova ANTES de
# cancelar a antiga — sync_account_features (Subscription#after_save) roda pro plano novo primeiro,
# evitando um instante sem nenhuma feature ligada. AiCreditBalance#plan_credits é resetado para o
# valor do plano novo via Subscription#initialize_credit_balance (extra_credits nunca é tocado).
class Plan::ChangeSubscriptionService
  Error = Class.new(StandardError)

  def initialize(account:, new_plan:)
    @account = account
    @new_plan = new_plan
  end

  # Self-service (cliente): só permite subir de plano. Downgrade não passa por aqui — decisão de
  # produto é que reduzir plano é feito pelo suporte (switch!), nunca pelo próprio cliente.
  def upgrade!
    current = current_plan
    raise Error, 'Plano atual não permite troca automática' if current.present? && current.commercial_rank.nil?
    raise Error, 'Plano de destino inválido' if @new_plan.commercial_rank.nil?
    if current.present? && @new_plan.commercial_rank <= current.commercial_rank
      raise Error, 'Só é possível fazer upgrade por aqui — para reduzir o plano, fale com o suporte'
    end

    switch!
  end

  # Usado pelo suporte (Super Admin): troca para qualquer plano comercial, upgrade ou downgrade.
  def switch!
    ActiveRecord::Base.transaction do
      previous = @account.subscriptions.current
      new_subscription = @account.subscriptions.create!(plan: @new_plan, status: :active, started_at: Time.current)
      previous.where.not(id: new_subscription.id).update_all(status: Subscription.statuses[:canceled]) # rubocop:disable Rails/SkipsModelValidations
      new_subscription
    end
  end

  private

  def current_plan
    @account.subscriptions.current.first&.plan
  end
end
