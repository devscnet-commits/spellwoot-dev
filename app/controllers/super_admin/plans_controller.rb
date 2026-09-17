class SuperAdmin::PlansController < SuperAdmin::ApplicationController
  # Sem :slug — evita alguém trocar o slug e desalinhar de PLAN_FEATURE_TO_ACCOUNT_FLAG/plans:seed,
  # que localizam o plano por slug. Sem :new/:create — planos novos entram via `rails plans:seed`
  # (garante features/limites populados junto); esta tela edita os planos já existentes.
  def resource_params
    params.require(:plan).permit(
      :name, :description, :active, :visible_to_new_subscribers, :courtesy,
      :monthly_price_cents, :annual_price_cents, :setup_fee_cents,
      :promo_price_cents, :promo_months_count,
      :ai_credits_included, :ai_credit_overage_price_cents
    )
  end
end
