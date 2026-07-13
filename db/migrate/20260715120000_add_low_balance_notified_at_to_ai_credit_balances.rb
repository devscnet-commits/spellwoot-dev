# Marca quando a SCNET já foi avisada que o saldo de créditos de IA da conta chegou a <=10% do teto
# do plano (billing Fase 2 — aviso proativo de 90% usado). nil = ainda não avisada neste ciclo;
# resetada para nil na renovação (Ai::CreditsRenewalJob) junto do reset de plan_credits. Aditiva.
class AddLowBalanceNotifiedAtToAiCreditBalances < ActiveRecord::Migration[7.1]
  def change
    add_column :ai_credit_balances, :low_balance_notified_at, :datetime
  end
end
