class SuperAdmin::PlansController < SuperAdmin::ApplicationController
  # Sem :slug — evita alguém trocar o slug e desalinhar de PLAN_FEATURE_TO_ACCOUNT_FLAG/plans:seed,
  # que localizam o plano por slug. Sem :new/:create — planos novos entram via `rails plans:seed`
  # (garante features/limites populados junto); esta tela edita os planos já existentes.
  #
  # feature_grid/limit_grid NÃO entram aqui: as partials as enviam como campos de topo
  # (plan_feature_keys[] / plan_limits[...]), fora do namespace `plan[...]`, e quem grava é #update
  # abaixo. Assim o Administrate nunca tenta atribuí-las ao model.
  def resource_params
    params.require(:plan).permit(
      :name, :description, :active, :visible_to_new_subscribers, :courtesy,
      :monthly_price_cents, :annual_price_cents, :setup_fee_cents,
      :promo_price_cents, :promo_months_count,
      :ai_credits_included, :ai_credit_overage_price_cents
    )
  end

  # O super do Administrate salva o plano e redireciona (ou re-renderiza o form com erros). As grades
  # só são gravadas quando o plano em si salvou — senão uma validação reprovada deixaria features
  # novas gravadas junto de um plano que o usuário ainda vai corrigir.
  def update
    super
    return if requested_resource.errors.any? || params[:plan_grid_submitted].blank?

    apply_grids
    flash[:notice] = "Plano atualizado. #{sync_active_accounts} conta(s) ativa(s) sincronizada(s)."
  end

  private

  def apply_grids
    requested_resource.apply_feature_grid!(params[:plan_feature_keys])
    requested_resource.apply_limit_grid!(params.fetch(:plan_limits, {}).permit!.to_h)
  end

  # A regra de negócio já lê o plano ao vivo (FeatureGate), então isto é para a UI: o bitmask da conta
  # é o que gateia sidebar e rotas, e só era reescrito no after_save da Subscription — sem isto, mudar
  # o plano aqui não mudaria nada na tela do cliente até a próxima renovação.
  # Falha de uma conta não derruba as outras nem o salvamento do plano.
  def sync_active_accounts
    synced = 0
    Subscription.where(plan_id: requested_resource.id).where.not(status: :canceled)
                .includes(:account).find_each do |subscription|
      next if subscription.account.blank?

      requested_resource.sync_features_to!(subscription.account)
      synced += 1
    rescue StandardError => e
      Rails.logger.error "[SuperAdmin::PlansController] sync conta=#{subscription.account_id}: #{e.class}: #{e.message}"
    end
    synced
  end
end
